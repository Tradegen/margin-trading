pragma solidity >=0.5.0;

//Inheritance
import './interfaces/ILToken.sol';

//Libraries
import './libraries/SafeMath.sol';

//Interfaces
import './interfaces/IAddressResolver.sol';
import './interfaces/ISettings.sol';
import './interfaces/IBaseUbeswapAdapter.sol';
import './interfaces/IERC20.sol';
import './interfaces/IStableCoinReserve.sol';

contract AssetLToken is ILToken {
    using SafeMath for uint;

    IAddressResolver public immutable ADDRESS_RESOLVER;

    address public underlyingAsset;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    mapping (address => uint) public collateral;
    mapping (address => uint) public loan;
    mapping (address => uint) public entryPrice;
    mapping (address => uint) public entryTimestamp;
    mapping (address => uint) public expirationTimestamp;

    constructor(IAddressResolver addressResolver, address _underlyingAsset, string memory _name, string memory _symbol) public {
        ADDRESS_RESOLVER = addressResolver;
        underlyingAsset = _underlyingAsset;
        name = _name;
        symbol = _symbol;
    }

    /* ========== VIEWS ========== */

    /**
    * @dev Given the address of a user, returns the user's position info
    * @param user Address of the user
    * @return (address, uint, uint, uint, uint, uint) Underlying asset, entry price, entry timestamp, number of tokens collateral, number of tokens borrowed, and expiration time
    */
    function getPositionInfo(address user) public view override isValidAddress(user) returns (address, uint, uint, uint, uint, uint) {
        return (underlyingAsset, entryPrice[user], entryTimestamp[user], collateral[user], loan[user], expirationTimestamp[user]);
    }

    /**
    * @dev Given the address of a user, returns the user's position value in USD
    * @param user Address of the user
    * @return uint Value of the position in USD
    */
    function getPositionValue(address user) public view override isValidAddress(user) returns (uint) {
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");

        //Calculate interest accrued
        uint interestAccrued = calculateInterestAccrued(user);
        
        //Get current price
        uint numberOfDecimals = IERC20(underlyingAsset).decimals();
        uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(underlyingAsset);

        uint collateralValue = (collateral[user].add(loan[user])).mul(USDperToken).div(10 ** numberOfDecimals);
        uint loanValue = (USDperToken > entryPrice[user]) ? (USDperToken.sub(entryPrice[user])).mul(loan[user]).div(10 ** numberOfDecimals) : (entryPrice[user].sub(USDperToken)).mul(loan[user]).div(10 ** numberOfDecimals);

        return (USDperToken > entryPrice[user]) ? collateralValue.add(loanValue).sub(interestAccrued) : collateralValue.sub(loanValue).sub(interestAccrued);
    }

    /**
    * @dev Returns whether the user's position can be liquidated
    * @param user Address of the user
    * @return bool Whether the user's position can be liquidated
    */
    function checkIfPositionCanBeLiquidated(address user) public view override isValidAddress(user) returns (bool) {
        //Get current price of position's underlying asset
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(underlyingAsset);

        return (USDperToken < calculateLiquidationPrice(user) || block.timestamp > expirationTimestamp[user]);
    }

    /**
    * @dev Given the address of a user, returns the user's position's leverage factor; (number of tokens borrowed + interest accrued) / collateral
    * @param user Address of the user
    * @return uint Leverage factor
    */
    function calculateLeverageFactor(address user) public view override isValidAddress(user) returns (uint) {
        uint interestAccrued = calculateInterestAccrued(user);

        return (loan[user].add(collateral[user]).add(interestAccrued)).div(collateral[user]);
    }

    /**
    * @dev Calculates the amount of interest accrued (in asset tokens) on a leveraged position
    * @param user Address of the user
    * @return uint Amount of interest accrued in asset tokens
    */
    function calculateInterestAccrued(address user) public view override isValidAddress(user) returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        uint interestRate = ISettings(settingsAddress).getParameterValue("InterestRateOnLeveragedAssets");

        return loan[user].mul(block.timestamp.sub(entryTimestamp[user])).mul(interestRate).div(365 days);
    }

    /**
    * @dev Calculates the price at which a position can be liquidated
    * @param user Address of the user
    * @return uint Liquidation price
    */
    function calculateLiquidationPrice(address user) public view override isValidAddress(user) returns (uint) {
        uint leverageFactor = calculateLeverageFactor(user);
        uint numerator = entryPrice[user].mul(8);
        uint denominator = leverageFactor.mul(10);

        return entryPrice[user].sub(numerator.div(denominator));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
    * @dev Opens a new leveraged position; swaps cUSD for specified asset
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param amountOfCollateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function openPosition(uint amountOfCollateral, uint amountToBorrow) external override {
        require(amountOfCollateral > 0, "AssetLToken: collateral must be greater than 0");
        require(amountToBorrow > 0, "AssetLToken: amount to borrow must be greater than 0");
        require(amountToBorrow <= amountOfCollateral.mul(9), "AssetLToken: leverage cannot be higher than 10x");
        
        _openPosition(amountOfCollateral, amountToBorrow);
    }

    /**
    * @dev Reduces the size of a leveraged position while maintaining leverage factor
    * @param numberOfTokens Number of asset tokens to sell
    */
    function reducePosition(uint numberOfTokens) external override {
        require(numberOfTokens > 0, "AssetLToken: number of tokens must be greater than 0");

        //Pay interest
        uint interestPaid = _payInterest(msg.sender);

        require(numberOfTokens < collateral[msg.sender].add(loan[msg.sender]), "AssetLToken: number of tokens must be less than position size");
       
        //Maintain leverage factor
        uint collateralToRemove = numberOfTokens.mul(collateral[msg.sender]).div(collateral[msg.sender].add(loan[msg.sender]));
        uint numberOfBorrowedTokensToRemove = numberOfTokens.mul(loan[msg.sender]).div(collateral[msg.sender].add(loan[msg.sender]));

        //Update state variables
        collateral[msg.sender] = collateral[msg.sender].sub(collateralToRemove);
        loan[msg.sender] = loan[msg.sender].sub(numberOfBorrowedTokensToRemove);

        //Swap from asset to cUSD
        address stableCoinReserveAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinReserve");
        uint cUSDReceived = IStableCoinReserve(stableCoinReserveAddress).swapFromAsset(underlyingAsset, collateral[msg.sender], loan[msg.sender], numberOfTokens, msg.sender);

        emit ReducedPosition(msg.sender, underlyingAsset, cUSDReceived, interestPaid, block.timestamp);
    }

    /**
    * @dev Closes a leveraged position
    */
    function closePosition() external override {
        //Pay interest
        uint interestAccrued = _payInterest(msg.sender);

        uint amountOfCollateral = collateral[msg.sender];
        uint amountOfLoan = loan[msg.sender];
        
        //Update state variables
        collateral[msg.sender] = 0;
        loan[msg.sender] = 0;
        entryPrice[msg.sender] = 0;
        entryTimestamp[msg.sender] = 0;
        expirationTimestamp[msg.sender] = 0;
        
        //Swap from asset to cUSD
        address stableCoinReserveAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinReserve");
        uint cUSDReceived = IStableCoinReserve(stableCoinReserveAddress).swapFromAsset(underlyingAsset, amountOfCollateral, amountOfLoan, amountOfCollateral.add(amountOfLoan), msg.sender);

        emit ClosedPosition(msg.sender, underlyingAsset, interestAccrued, cUSDReceived, block.timestamp);
    }

    /**
    * @dev Adds collateral to the leveraged position
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param amountOfUSD Amount of cUSD to add as collateral; cUSD is swapped for asset tokens
    */
    function addCollateral(uint amountOfUSD) external override {
        require(amountOfUSD > 0, "AssetLToken: amount of USD must be greater than 0");

        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinReserveAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinReserve");

        //Swap cUSD for asset
        uint numberOfTokensReceived = IStableCoinReserve(stableCoinReserveAddress).swapToAsset(underlyingAsset, amountOfUSD, 0, msg.sender);
        
        //Get current price of asset
        uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(underlyingAsset);

        //Calculate new entry price
        uint initialPositionValue = entryPrice[msg.sender].mul(collateral[msg.sender].add(loan[msg.sender]));
        uint addedAmount = USDperToken.mul(numberOfTokensReceived);
        
        //Update state variables
        collateral[msg.sender] = collateral[msg.sender].add(numberOfTokensReceived);
        entryPrice[msg.sender] = initialPositionValue.add(addedAmount).div(numberOfTokensReceived.add(collateral[msg.sender]).add(loan[msg.sender]));

        emit AddedCollateral(msg.sender, underlyingAsset, numberOfTokensReceived, block.timestamp);
    }

    /**
    * @dev Removes collateral from the leveraged position
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateral(uint numberOfTokens) external override {
        require(numberOfTokens > 0, "AssetLToken: number of tokens must be greater than 0");
        require(numberOfTokens < collateral[msg.sender], "AssetLToken: number of tokens must be less than collateral");

        collateral[msg.sender] = collateral[msg.sender].sub(numberOfTokens);

        require(calculateLeverageFactor(msg.sender) <= 10, "AssetLToken: cannot exceed 10x leverage");

        //Swap from asset to cUSD
        address stableCoinReserveAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinReserve");
        uint cUSDReceived = IStableCoinReserve(stableCoinReserveAddress).swapFromAsset(underlyingAsset, 1, 0, numberOfTokens, msg.sender);
    
        emit RemovedCollateral(msg.sender, underlyingAsset, numberOfTokens, cUSDReceived, block.timestamp);
    }

    /**
    * @dev Liquidates part of the leveraged position
    * @param user Address of the user
    */
    function liquidate(address user) external override isValidAddress(user) {
        require(checkIfPositionCanBeLiquidated(user), "AssetLToken: current price is above liquidation price");

        //Pay interest
        _payInterest(user);

        //Get updated position size
        uint positionSize = collateral[user].add(loan[user]);

        //Get liquidation fee
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        uint liquidationFee = ISettings(settingsAddress).getParameterValue("LiquidationFee");

        //Calculate user and pool cUSD share
        uint userShare = _calculateUSDValueOfUserTokens(user, positionSize);
        uint liquidatorShare = userShare.mul(liquidationFee).div(100);
        uint poolShare = getPositionValue(user).sub(userShare).sub(liquidatorShare);

        //Update state variables
        collateral[user] = 0;
        loan[user] = 0;
        entryPrice[user] = 0;
        entryTimestamp[user] = 0;
        expirationTimestamp[user] = 0;

        //Swap from asset to cUSD
        address stableCoinReserveAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinReserve");
        uint cUSDReceived = IStableCoinReserve(stableCoinReserveAddress).liquidateLeveragedAsset(underlyingAsset, userShare, liquidatorShare, poolShare, positionSize, user, msg.sender);

        emit Liquidated(user, msg.sender, underlyingAsset, cUSDReceived, liquidatorShare, block.timestamp);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
    * @dev Returns the amount of USD received for the given number of tokens
    * @param user Address of the user
    * @param numberOfTokens Number of tokens in the position's underlying asset
    * @return uint Amount of USD received
    */
    function _calculateUSDValueOfUserTokens(address user, uint numberOfTokens) internal view isValidAddress(user) returns (uint) {
        require(numberOfTokens > 0, "AssetLToken: number of tokens must be greater than 0");

        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");

        uint collateralInUSD = entryPrice[user].mul(collateral[user]);
        uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(underlyingAsset);
        uint delta = (USDperToken > entryPrice[user]) ?
                     (USDperToken.sub(entryPrice[user])).mul(collateral[user].add(loan[user])) :
                     (entryPrice[user].sub(USDperToken)).mul(collateral[user].add(loan[user]));

        return (USDperToken > entryPrice[user]) ?
               (collateralInUSD.add(delta)).mul(numberOfTokens).div(collateral[user].add(loan[user])) :
               (collateralInUSD.sub(delta)).mul(numberOfTokens).div(collateral[user].add(loan[user]));
    }

    /**
    * @dev Given the address of a user, calculates and pays the accrued interest on the user's position
    * @param user Address of the user
    * @return uint Amount of interest paid
    */
    function _payInterest(address user) internal isValidAddress(user) returns (uint) {
        uint interestAccrued = calculateInterestAccrued(user);
        uint leverageFactor = calculateLeverageFactor(user);

        //Remove collateral and borrowed tokens to maintain leverage factor
        collateral[user] = collateral[user].sub(interestAccrued);
        loan[user] = loan[user].sub(interestAccrued.mul(leverageFactor));
        entryTimestamp[user] = block.timestamp;

        //Pay interest
        address stableCoinReserveAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinReserve");
        if (interestAccrued > 0)
        {
            IStableCoinReserve(stableCoinReserveAddress).payInterest(underlyingAsset, interestAccrued);
        } 

        return interestAccrued;
    }

    /**
    * @dev Opens a new leveraged position; swaps cUSD for specified asset
    * @param amountOfCollateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function _openPosition(uint amountOfCollateral, uint amountToBorrow) internal {
        address stableCoinReserveAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinReserve");

        //Swap cUSD for asset
        uint numberOfTokensReceived = IStableCoinReserve(stableCoinReserveAddress).swapToAsset(underlyingAsset, amountOfCollateral, amountToBorrow, msg.sender);
        
        //Adjust collateral and amountToBorrow to asset tokens
        uint adjustedCollateral = numberOfTokensReceived.mul(amountOfCollateral).div(amountOfCollateral.add(amountToBorrow));
        uint adjustedAmountToBorrow = numberOfTokensReceived.mul(amountToBorrow).div(amountOfCollateral.add(amountToBorrow));

        //Get entry price; used for calculating liquidation price
        uint USDperToken = (amountOfCollateral.add(amountToBorrow)).div(numberOfTokensReceived);

        //Update state variables
        collateral[msg.sender] = adjustedCollateral;
        loan[msg.sender] = adjustedAmountToBorrow;
        entryPrice[msg.sender] = USDperToken;
        entryTimestamp[msg.sender] = block.timestamp;
        expirationTimestamp[msg.sender] = block.timestamp.add(30 days);

        emit OpenedPosition(msg.sender, underlyingAsset, adjustedCollateral, adjustedAmountToBorrow, USDperToken, block.timestamp);
    }

    /* ========== MODIFIERS ========== */

    modifier isValidAddress(address addressToCheck) {
        require(addressToCheck != address(0), "AssetLToken: invalid address");
        _;
    }

    /* ========== EVENTS ========== */

    event OpenedPosition(address indexed owner, address indexed underlyingAsset, uint collateral, uint numberOfTokensBorrowed, uint entryPrice, uint timestamp);
    event ReducedPosition(address indexed owner, address indexed underlyingAsset, uint cUSDReceived, uint interestPaid, uint timestamp);
    event ClosedPosition(address indexed owner, address indexed underlyingAsset, uint interestAccrued, uint cUSDReceived, uint timestamp);
    event AddedCollateral(address indexed owner, address indexed underlyingAsset, uint collateralAdded, uint timestamp);
    event RemovedCollateral(address indexed owner, address indexed underlyingAsset, uint collateralRemoved, uint cUSDReceived, uint timestamp);
    event Liquidated(address indexed owner, address indexed liquidator, address indexed underlyingAsset, uint collateralReturned, uint liquidatorShare, uint timestamp);
}