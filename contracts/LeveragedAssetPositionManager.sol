pragma solidity >=0.5.0;

//Interfaces
import './interfaces/IAddressResolver.sol';
import './interfaces/ISettings.sol';
import './interfaces/IERC20.sol';
import './interfaces/IBaseUbeswapAdapter.sol';
import "./interfaces/IStableCoinStakingRewards.sol";
import './interfaces/IPool.sol';

//Inheritance
import './interfaces/ILeveragedAssetPositionManager.sol';

//Libraries
import './libraries/SafeMath.sol';

contract LeveragedAssetPositionManager is ILeveragedAssetPositionManager {
    using SafeMath for uint;

    IAddressResolver public immutable ADDRESS_RESOLVER;

    uint public numberOfLeveragedPositions;
    mapping (address => uint[]) public userPositions;
    mapping (uint => LeveragedAssetPosition) public leveragedPositions;
    mapping (address => mapping (address => uint)) public positionIndexes; //maps to (index + 1), with index 0 representing position not found

    constructor(IAddressResolver addressResolver) public {
        ADDRESS_RESOLVER = addressResolver;
    }

    /* ========== VIEWS ========== */

    /**
    * @dev Returns the index of each leveraged position the user has
    * @param user Address of the user
    * @return uint[] Index of each position
    */
    function getUserPositions(address user) public view override returns (uint[] memory) {
        require(user != address(0), "LeveragedAssetPositionManager: invalid user address");

        return userPositions[user];
    }

    /**
    * @dev Given the index of a leveraged position, return the position info
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return (address, address, uint, uint, uint, uint) Leveraged position's owner, underlying asset, entry timestamp, number of tokens collateral, number of tokens borrowed, and entry price
    */
    function getPositionInfo(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (address, address, uint, uint, uint, uint) {
        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];

        return (position.owner, position.underlyingAsset, position.entryTimestamp, position.collateral, position.numberOfTokensBorrowed, position.entryPrice);
    }

    /**
    * @dev Given the index of a leveraged position, returns the position value in USD
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Value of the position in USD
    */
    function getPositionValue(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (uint) {
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];

        //Calculate interest accrued
        uint interestAccrued = calculateInterestAccrued(positionIndex);
        
        //Get current price
        uint numberOfDecimals = IERC20(position.underlyingAsset).decimals();
        uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(position.underlyingAsset);

        uint collateralValue = (position.collateral.add(position.numberOfTokensBorrowed)).mul(USDperToken).div(10 ** numberOfDecimals);
        uint loanValue = (USDperToken > position.entryPrice) ? (USDperToken.sub(position.entryPrice)).mul(position.numberOfTokensBorrowed).div(10 ** numberOfDecimals) : (position.entryPrice.sub(USDperToken)).mul(position.numberOfTokensBorrowed).div(10 ** numberOfDecimals);

        return (USDperToken > position.entryPrice) ? collateralValue.add(loanValue).sub(interestAccrued) : collateralValue.sub(loanValue).sub(interestAccrued);
    }

    /**
    * @dev Given the index of a position, returns whether the position can be liquidated
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return bool Whether the position can be liquidated
    */
    function checkIfPositionCanBeLiquidated(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (bool) {
        //Get current price of position's underyling asset
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(leveragedPositions[positionIndex].underlyingAsset);

        return (USDperToken < calculateLiquidationPrice(positionIndex));
    }

    /**
    * @dev Given the index of a position, returns the position's leverage factor; (number of tokens borrowed + interest accrued) / collateral
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Leverage factor
    */
    function calculateLeverageFactor(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (uint) {
        uint interestAccrued = calculateInterestAccrued(positionIndex);

        return (leveragedPositions[positionIndex].numberOfTokensBorrowed.add(interestAccrued)).div(leveragedPositions[positionIndex].collateral);
    }

    /**
    * @dev Calculates the amount of interest accrued (in asset tokens) on a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Amount of interest accrued in asset tokens
    */
    function calculateInterestAccrued(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        uint interestRate = ISettings(settingsAddress).getParameterValue("InterestRateOnLeveragedAssets");
        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];

        return position.numberOfTokensBorrowed.mul(block.timestamp.sub(position.entryTimestamp)).mul(interestRate).div(365 days);
    }

    /**
    * @dev Calculates the price at which a position can be liquidated
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Liquidation price
    */
    function calculateLiquidationPrice(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (uint) {
        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];
        uint leverageFactor = calculateLeverageFactor(positionIndex);
        uint numerator = position.entryPrice.mul(8);
        uint denominator = leverageFactor.mul(10);

        return position.entryPrice.sub(numerator.div(denominator));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
    * @dev Opens a new leveraged position; swaps cUSD for specified asset
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param underlyingAsset Address of the leveraged asset
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function openPosition(address underlyingAsset, uint collateral, uint amountToBorrow) public override {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");

        require(underlyingAsset != address(0), "LeveragedAssetPositionManager: invalid address for underlying asset");
        require(collateral > 0, "LeveragedAssetPositionManager: collateral must be greater than 0");
        require(amountToBorrow > 0, "LeveragedAssetPositionManager: amount to borrow must be greater than 0");
        require(amountToBorrow <= collateral.mul(9), "LeveragedAssetPositionManager: leverage cannot be higher than 10x");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(underlyingAsset), "LeveragedAssetPositionManager: currency not available");
        require(userPositions[msg.sender].length < ISettings(settingsAddress).getParameterValue("MaximumNumberOfLeveragedPositions"), "LeveragedAssetPositionManager: cannot exceed maximum number of leveraged positions");
        
        //Check if user has existing leveraged position with this asset
        //Add to position
        if (positionIndexes[msg.sender][underlyingAsset] > 0)
        {
            _combinePositions(positionIndexes[msg.sender][underlyingAsset].sub(1), collateral, amountToBorrow);
        }
        //Open a new position
        else
        {
            _openPosition(underlyingAsset, collateral, amountToBorrow);
            positionIndexes[msg.sender][underlyingAsset] = numberOfLeveragedPositions;
        }
    }

    /**
    * @dev Reduces the size of a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of tokens to sell
    */
    function reducePosition(uint positionIndex, uint numberOfTokens) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        require(numberOfTokens > 0, "LeveragedAssetPositionManager: number of tokens must be greater than 0");

        //Pay interest
        uint interestPaid = _payInterest(positionIndex);

        require(numberOfTokens < leveragedPositions[positionIndex].collateral.add(leveragedPositions[positionIndex].numberOfTokensBorrowed), "LeveragedAssetPositionManager: number of tokens must be less than position size");

        //Calculate user and pool cUSD share
        uint userShare = _calculateUserUSDShare(positionIndex, numberOfTokens);
        uint poolShare = getPositionValue(positionIndex).sub(userShare).mul(numberOfTokens).div(leveragedPositions[positionIndex].collateral.add(leveragedPositions[positionIndex].numberOfTokensBorrowed));
       
        //Maintain leverage factor
        uint collateralToRemove = numberOfTokens.mul(leveragedPositions[positionIndex].collateral).div(leveragedPositions[positionIndex].collateral.add(leveragedPositions[positionIndex].numberOfTokensBorrowed));
        uint numberOfBorrowedTokensToRemove = numberOfTokens.mul(leveragedPositions[positionIndex].numberOfTokensBorrowed).div(leveragedPositions[positionIndex].collateral.add(leveragedPositions[positionIndex].numberOfTokensBorrowed));

        //Update state variables
        leveragedPositions[positionIndex].collateral = leveragedPositions[positionIndex].collateral.sub(collateralToRemove);
        leveragedPositions[positionIndex].numberOfTokensBorrowed = leveragedPositions[positionIndex].numberOfTokensBorrowed.sub(numberOfBorrowedTokensToRemove);

        //Swap from asset to cUSD
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        uint cUSDReceived = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(leveragedPositions[positionIndex].underlyingAsset, userShare, poolShare, numberOfTokens, msg.sender);

        emit ReducedPosition(msg.sender, positionIndex, cUSDReceived, interestPaid, block.timestamp);
    }

    /**
    * @dev Closes a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function closePosition(uint positionIndex) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];

        //Pay interest
        uint interestAccrued = _payInterest(positionIndex);

        //Get updated position size
        uint positionSize = position.collateral.add(position.numberOfTokensBorrowed);

        //Calculate user and pool cUSD share
        uint userShare = _calculateUserUSDShare(positionIndex, positionSize);
        uint poolShare = getPositionValue(positionIndex).sub(userShare);
        
        //Update state variables
        _removePosition(positionIndex);
        
        //Swap from asset to cUSD
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        uint cUSDReceived = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(leveragedPositions[positionIndex].underlyingAsset, userShare, poolShare, positionSize, msg.sender);

        emit ClosedPosition(msg.sender, positionIndex, interestAccrued, cUSDReceived, block.timestamp);
    }

    /**
    * @dev Adds collateral to the leveraged position
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param amountOfUSD Amount of cUSD to add as collateral
    */
    function addCollateral(uint positionIndex, uint amountOfUSD) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        require(amountOfUSD > 0, "LeveragedAssetPositionManager: amount of USD must be greater than 0");

        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");

        //Swap cUSD for asset
        uint numberOfTokensReceived = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(leveragedPositions[positionIndex].underlyingAsset, amountOfUSD, 0, msg.sender);
        
        //Get current price of asset
        uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(leveragedPositions[positionIndex].underlyingAsset);

        //Calculate new entry price
        uint initialPositionValue = leveragedPositions[positionIndex].entryPrice.mul(leveragedPositions[positionIndex].collateral.add(leveragedPositions[positionIndex].numberOfTokensBorrowed));
        uint addedAmount = USDperToken.mul(numberOfTokensReceived);
        uint newEntryPrice = initialPositionValue.add(addedAmount).div(numberOfTokensReceived.add(leveragedPositions[positionIndex].collateral).add(leveragedPositions[positionIndex].numberOfTokensBorrowed));
        
        //Update state variables
        leveragedPositions[positionIndex].collateral = leveragedPositions[positionIndex].collateral.add(numberOfTokensReceived);
        leveragedPositions[positionIndex].entryPrice = newEntryPrice;

        emit AddedCollateral(msg.sender, positionIndex, numberOfTokensReceived, block.timestamp);
    }

    /**
    * @dev Removes collateral from the leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateral(uint positionIndex, uint numberOfTokens) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        require(numberOfTokens > 0, "LeveragedAssetPositionManager: number of tokens must be greater than 0");
        require(numberOfTokens < leveragedPositions[positionIndex].collateral, "LeveragedAssetPositionManager: number of tokens must be less than collateral");

        leveragedPositions[positionIndex].collateral = leveragedPositions[positionIndex].collateral.sub(numberOfTokens);

        require(calculateLeverageFactor(positionIndex) <= 10, "LeveragedAssetPositionManager: cannot exceed 10x leverage");

        uint userShare = _calculateUserUSDShare(positionIndex, numberOfTokens);

        //Swap from asset to cUSD
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        uint cUSDReceived = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(leveragedPositions[positionIndex].underlyingAsset, userShare, 0, numberOfTokens, msg.sender);
    
        emit RemovedCollateral(msg.sender, positionIndex, numberOfTokens, cUSDReceived, block.timestamp);
    }

    /**
    * @dev Transfers leveraged position to another contract
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param newOwner Address of contract to transfer ownership to
    */
    function transferOwnership(uint positionIndex, address newOwner) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        require(newOwner != address(0), "LeveragedAssetPositionManager: invalid address for new owner");
        require(newOwner != msg.sender, "LeveragedAssetPositionManager: new owner is same as current owner");

        //Check if new owner can add a new leveraged position
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        require(userPositions[newOwner].length < ISettings(settingsAddress).getParameterValue("MaximumNumberOfLeveragedPositions"), "LeveragedAssetPositionManager: new owner has too many leveraged positions");
    
        //Update owner of leveraged position
        leveragedPositions[positionIndex].owner = newOwner;

        //Get index of leveraged position in old owner's position array
        uint indexInOldOwnerArray = leveragedPositions[positionIndex].indexInOwnerPositionArray;

        //Remove position from old owner's array of leveraged positions
        userPositions[msg.sender][indexInOldOwnerArray] = userPositions[msg.sender][userPositions[msg.sender].length - 1];
        userPositions[msg.sender].pop();

        //Update index of position in old owner position array
        leveragedPositions[userPositions[msg.sender][indexInOldOwnerArray]].indexInOwnerPositionArray = indexInOldOwnerArray;

        //Add position to new owner's array of leveraged positions
        userPositions[newOwner].push(positionIndex);
        
        //Update index of position in new owner position array
        leveragedPositions[positionIndex].indexInOwnerPositionArray = userPositions[newOwner].length.sub(1);

        emit TransferredOwnership(msg.sender, newOwner, positionIndex, block.timestamp);
    }

    /**
    * @dev Liquidates part of the leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function liquidate(uint positionIndex) public override {
        require(checkIfPositionCanBeLiquidated(positionIndex), "LeveragedAssetPositionManager: current price is above liquidation price");

        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];
        address owner = leveragedPositions[positionIndex].owner;

        //Pay interest
        _payInterest(positionIndex);

        //Get updated position size
        uint positionSize = position.collateral.add(position.numberOfTokensBorrowed);

        //Get liquidation fee
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        uint liquidationFee = ISettings(settingsAddress).getParameterValue("LiquidationFee");

        //Calculate user and pool cUSD share
        uint userShare = _calculateUserUSDShare(positionIndex, positionSize);
        uint liquidatorShare = userShare.mul(liquidationFee).div(100);
        uint poolShare = getPositionValue(positionIndex).sub(userShare).sub(liquidatorShare);

        //Swap from asset to cUSD
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        uint cUSDReceived = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).liquidateLeveragedAsset(leveragedPositions[positionIndex].underlyingAsset, userShare, liquidatorShare, poolShare, positionSize, owner, msg.sender);

        _removePosition(positionIndex);

        _decrementPositionCountIfAddressIsPool(owner);

        emit Liquidated(owner, msg.sender, positionIndex, cUSDReceived, liquidatorShare, block.timestamp);
    }

     /**
    * @dev Transfers part of each position the caller has to the recipient; meant to be called from a Pool
    * @param recipient Address of user receiving the tokens
    * @param numerator Numerator used for calculating ratio of tokens
    * @param denominator Denominator used for calculating ratio of tokens
    */
    function bulkTransferTokens(address recipient, uint numerator, uint denominator) public override onlyPool {
        require(recipient != address(0), "LeveragedAssetPositionManager: invalid recipient address");
        require(numerator > 0, "LeveragedAssetPositionManager: numerator must be greater than 0");
        require(denominator > 0, "LeveragedAssetPositionManager: denominator must be greater than 0");

        for (uint i = 0; i < userPositions[msg.sender].length; i++)
        {
            _transferTokens(userPositions[msg.sender][i], recipient, numerator, denominator);
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
    * @dev Removes the given position from user's position array and updates state variables accordingly
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function _removePosition(uint positionIndex) internal positionIndexInRange(positionIndex) {
        uint indexInUserPositionArray = leveragedPositions[positionIndex].indexInOwnerPositionArray;
        address lastUser = leveragedPositions[numberOfLeveragedPositions - 1].owner;
        uint indexInLastUserPositionArray = leveragedPositions[numberOfLeveragedPositions - 1].indexInOwnerPositionArray;

        //Swap with last element in user position array and remove last element
        userPositions[msg.sender][indexInUserPositionArray] = userPositions[msg.sender][userPositions[msg.sender].length];
        userPositions[msg.sender].pop();

        //Update index of swapped element in main position array
        leveragedPositions[userPositions[msg.sender][indexInUserPositionArray]].indexInOwnerPositionArray = indexInUserPositionArray;

        //Swap with last element in main position array and remove last element
        leveragedPositions[positionIndex] = leveragedPositions[numberOfLeveragedPositions - 1];

        //Update index in last user position array
        userPositions[lastUser][indexInLastUserPositionArray] = positionIndex;
    }

    /**
    * @dev Given the index of a position, calculates and pays the accrued interest
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Amount of interest paid
    */
    function _payInterest(uint positionIndex) internal positionIndexInRange(positionIndex) returns (uint) {
        uint interestAccrued = calculateInterestAccrued(positionIndex);
        uint leverageFactor = calculateLeverageFactor(positionIndex);

        //Remove collateral and borrowed tokens to maintain leverage factor
        leveragedPositions[positionIndex].collateral = leveragedPositions[positionIndex].collateral.sub(interestAccrued);
        leveragedPositions[positionIndex].numberOfTokensBorrowed = leveragedPositions[positionIndex].numberOfTokensBorrowed.sub(interestAccrued.mul(leverageFactor));
        leveragedPositions[positionIndex].entryTimestamp = block.timestamp;

        //Pay interest
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        if (interestAccrued > 0)
        {
            IStableCoinStakingRewards(stableCoinStakingRewardsAddress).payInterest(leveragedPositions[positionIndex].underlyingAsset, interestAccrued);
        } 

        return interestAccrued;
    }

    /**
    * @dev Given the index of a position, returns the amount of USD received for the given number of tokens
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of tokens in the position's underlying asset
    * @return uint Amount of USD received
    */
    function _calculateUserUSDShare(uint positionIndex, uint numberOfTokens) internal view positionIndexInRange(positionIndex) returns (uint) {
        require(numberOfTokens > 0, "LeveragedAssetPositionManager: number of tokens must be greater than 0");
        require(numberOfTokens <= leveragedPositions[positionIndex].collateral.add(leveragedPositions[positionIndex].numberOfTokensBorrowed), "LeveragedAssetPositionManager: number of tokens must be less than position size");

        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];

        uint collateralInUSD = position.entryPrice.mul(position.collateral);
        uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(position.underlyingAsset);
        uint delta = (USDperToken > position.entryPrice) ?
                     (USDperToken.sub(position.entryPrice)).mul(position.collateral.add(position.numberOfTokensBorrowed)) :
                     (position.entryPrice.sub(USDperToken)).mul(position.collateral.add(position.numberOfTokensBorrowed));

        return (USDperToken > position.entryPrice) ?
               (collateralInUSD.add(delta)).mul(numberOfTokens).div(position.collateral.add(position.numberOfTokensBorrowed)) :
               (collateralInUSD.sub(delta)).mul(numberOfTokens).div(position.collateral.add(position.numberOfTokensBorrowed));
    }

    /**
    * @dev Decrements the pool's total position count if the supplied address is a valid pool address
    */
    function _decrementPositionCountIfAddressIsPool(address addressToCheck) internal {
        if (ADDRESS_RESOLVER.checkIfPoolAddressIsValid(addressToCheck))
        {
            IPool(addressToCheck).decrementTotalPositionCount();
        }
    }

    /**
    * @dev Adds collateral and loan to existing position, and recalculates entry price
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function _combinePositions(uint positionIndex, uint collateral, uint amountToBorrow) internal positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];

        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");

        _payInterest(positionIndex);

        //Swap cUSD for asset
        uint numberOfTokensReceived = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(position.underlyingAsset, collateral.add(amountToBorrow), 0, msg.sender);

        //Calculate new entry price
        uint initialPositionValue = position.entryPrice.mul(position.collateral.add(position.numberOfTokensBorrowed));
        uint addedAmount = collateral.add(amountToBorrow);
        uint newEntryPrice = (initialPositionValue.add(addedAmount)).div(numberOfTokensReceived.add(position.collateral).add(position.numberOfTokensBorrowed));
        
        //Update state variables
        leveragedPositions[positionIndex].collateral = position.collateral.add(numberOfTokensReceived.mul(collateral).div(addedAmount));
        leveragedPositions[positionIndex].numberOfTokensBorrowed = position.numberOfTokensBorrowed.add(numberOfTokensReceived.mul(amountToBorrow).div(addedAmount));
        leveragedPositions[positionIndex].entryPrice = newEntryPrice;

        emit CombinedPosition(msg.sender, positionIndex, collateral, amountToBorrow, block.timestamp);
    }

    /**
    * @dev Opens a new leveraged position; swaps cUSD for specified asset
    * @param asset Address of position's underlying asste
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function _openPosition(address asset, uint collateral, uint amountToBorrow) internal {
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");

        //Swap cUSD for asset
        uint numberOfTokensReceived = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(asset, collateral, amountToBorrow, msg.sender);
        
        //Adjust collateral and amountToBorrow to asset tokens
        uint adjustedCollateral = numberOfTokensReceived.mul(collateral).div(collateral.add(amountToBorrow));
        uint adjustedAmountToBorrow = numberOfTokensReceived.mul(amountToBorrow).div(collateral.add(amountToBorrow));

        //Get entry price; used for calculating liquidation price
        uint USDperToken = (collateral.add(amountToBorrow)).div(numberOfTokensReceived);

        leveragedPositions[numberOfLeveragedPositions] = LeveragedAssetPosition(msg.sender, asset, block.timestamp, adjustedCollateral, adjustedAmountToBorrow, USDperToken, userPositions[msg.sender].length);
        userPositions[msg.sender].push(numberOfLeveragedPositions);
        numberOfLeveragedPositions = numberOfLeveragedPositions.add(1);

        emit OpenedPosition(msg.sender, asset, adjustedCollateral, adjustedAmountToBorrow, USDperToken, numberOfLeveragedPositions.sub(1), block.timestamp);
    }

    /**
    * @dev Transfers part of a position to another user; meant to be called from a Pool
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param recipient Address of user receiving the tokens
    * @param numerator Numerator used for calculating ratio of tokens
    * @param denominator Denominator used for calculating ratio of tokens
    */
    function _transferTokens(uint positionIndex, address recipient, uint numerator, uint denominator) internal positionIndexInRange(positionIndex) {
        LeveragedAssetPosition memory position = leveragedPositions[positionIndex];

        uint numberOfTokens = (position.collateral.add(position.numberOfTokensBorrowed)).mul(numerator).div(denominator);
        
        if (numberOfTokens == position.collateral.add(position.numberOfTokensBorrowed))
        {
            transferOwnership(positionIndex, recipient);
        }
        else
        {
            //Check if recipient can add a new leveraged position
            address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
            require(userPositions[recipient].length < ISettings(settingsAddress).getParameterValue("MaximumNumberOfLeveragedPositions"), "LeveragedAssetPositionManager: recipient has too many leveraged positions");

            //Combine positions if recipient already has a position in this asset
            uint recipientPositionIndex = positionIndexes[recipient][position.underlyingAsset];
            //Combine positions
            if (recipientPositionIndex > 0)
            {
                LeveragedAssetPosition memory recipientPosition = leveragedPositions[recipientPositionIndex.sub(1)];
                
                //Update state variables
                leveragedPositions[recipientPositionIndex.sub(1)].collateral = recipientPosition.collateral.add(numberOfTokens.mul(recipientPosition.collateral).div(recipientPosition.collateral.add(recipientPosition.numberOfTokensBorrowed)));
                leveragedPositions[recipientPositionIndex.sub(1)].numberOfTokensBorrowed = recipientPosition.numberOfTokensBorrowed.add(numberOfTokens.mul(recipientPosition.collateral).div(recipientPosition.collateral.add(recipientPosition.numberOfTokensBorrowed)));
            }
            //Open a new position
            else
            {
                uint collateral = numberOfTokens.div(calculateLeverageFactor(positionIndex));
                leveragedPositions[numberOfLeveragedPositions] = LeveragedAssetPosition(msg.sender, position.underlyingAsset, block.timestamp, collateral, numberOfTokens.sub(collateral), position.entryPrice, userPositions[msg.sender].length);
                userPositions[recipient].push(numberOfLeveragedPositions);
                numberOfLeveragedPositions = numberOfLeveragedPositions.add(1);
                positionIndexes[recipient][position.underlyingAsset] = numberOfLeveragedPositions;
            }
        }
    }

    /* ========== MODIFIERS ========== */

    modifier onlyPositionOwner(uint positionIndex) {
        require(leveragedPositions[positionIndex].owner == msg.sender, "LeveragedAssetPositionManager: only position owner can call this function");
        _;
    }

    modifier positionIndexInRange(uint positionIndex) {
        require(positionIndex > 0, "LeveragedAssetPositionManager: position index must be greater than 0");
        require(positionIndex < numberOfLeveragedPositions, "LeveragedAssetPositionManager: position index out of range");
        _;
    }

    modifier onlyPool() {
        require(ADDRESS_RESOLVER.checkIfPoolAddressIsValid(msg.sender), "LeveragedLiquidityPositionManager: only a Pool can call this function");
        _;
    }

    /* ========== EVENTS ========== */

    event OpenedPosition(address indexed owner, address indexed underlyingAsset, uint collateral, uint numberOfTokensBorrowed, uint entryPrice, uint positionIndex, uint timestamp);
    event ReducedPosition(address indexed owner, uint indexed positionIndex, uint cUSDReceived, uint interestPaid, uint timestamp);
    event ClosedPosition(address indexed owner, uint indexed positionIndex, uint interestAccrued, uint cUSDReceived, uint timestamp);
    event CombinedPosition(address indexed owner, uint indexed positionIndex, uint collateral, uint numberOfTokensBorrowed, uint timestamp);
    event AddedCollateral(address indexed owner, uint indexed positionIndex, uint collateralAdded, uint timestamp);
    event RemovedCollateral(address indexed owner, uint indexed positionIndex, uint collateralRemoved, uint cUSDReceived, uint timestamp);
    event TransferredOwnership(address indexed oldOwner, address newOwner, uint indexed positionIndex, uint timestamp);
    event Liquidated(address indexed owner, address indexed liquidator, uint indexed positionIndex, uint collateralReturned, uint liquidatorShare, uint timestamp);
}