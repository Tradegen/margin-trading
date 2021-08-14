pragma solidity >=0.5.0;

//Interfaces
import './interfaces/IAddressResolver.sol';
import './interfaces/ISettings.sol';
import './interfaces/IERC20.sol';
import './interfaces/IBaseUbeswapAdapter.sol';
import "./interfaces/IStableCoinStakingRewards.sol";
import './interfaces/IUniswapV2Pair.sol';
import './interfaces/IStakingRewards.sol';
import './interfaces/IPool.sol';

//Inheritance
import './interfaces/ILeveragedLiquidityPositionManager.sol';
import './LeveragedFarmingRewards.sol';

//Libraries
import './libraries/SafeMath.sol';

contract LeveragedLiquidityPositionManager is ILeveragedLiquidityPositionManager, LeveragedFarmingRewards {
    using SafeMath for uint;

    uint public numberOfLeveragedPositions;
    mapping (address => uint[]) public userPositions;
    mapping (uint => LeveragedLiquidityPosition) public leveragedPositions;
    mapping (address => mapping (address => uint)) public positionIndexes; //maps to (index + 1), with index 0 representing position not found

    constructor(IAddressResolver addressResolver) public LeveragedFarmingRewards(addressResolver) {
    }

    /* ========== VIEWS ========== */

    /**
    * @dev Returns the index of each leveraged position the user has
    * @param user Address of the user
    * @return uint[] Index of each position
    */
    function getUserPositions(address user) public view override returns (uint[] memory) {
        require(user != address(0), "LeveragedLiquidityPositionManager: invalid user address");

        return userPositions[user];
    }

    /**
    * @dev Given the index of a leveraged position, return the position info
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return (address, address, address, uint, uint, uint, uint) Leveraged position's owner, address of liquidity pair, address of liquidity pair's Ubeswap farm, entry timestamp, number of tokens collateral, number of tokens borrowed, and entry price
    */
    function getPositionInfo(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (address, address, address, uint, uint, uint, uint) {
        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        return (position.owner, position.pair, position.farm, position.entryTimestamp, position.collateral, position.numberOfTokensBorrowed, position.entryPrice);
    }

    /**
    * @dev Given the index of a leveraged position, returns the position value in USD
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Value of the position in USD
    */
    function getPositionValue(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (uint) {
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        uint interestAccrued = calculateInterestAccrued(positionIndex);

        address token0 = IUniswapV2Pair(position.pair).token0();
        address token1 = IUniswapV2Pair(position.pair).token1();
        (uint amount0, uint amount1) = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getTokenAmountsFromPair(token0, token1, position.collateral.add(position.numberOfTokensBorrowed));

        //Get price of token0
        uint numberOfDecimals0 = IERC20(token0).decimals();
        uint USDperToken0 = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(token0);
        uint USDBalance0 = amount0.mul(USDperToken0).div(10 ** numberOfDecimals0);

        //Get price of token1
        uint numberOfDecimals1 = IERC20(token1).decimals();
        uint USDperToken1 = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(token1);
        uint USDBalance1 = amount1.mul(USDperToken1).div(10 ** numberOfDecimals1);

        //Calculate current price of LP token
        uint priceOfLPToken = (USDBalance0.add(USDBalance1)).div(position.collateral.add(position.numberOfTokensBorrowed));

        uint collateralValue = (position.collateral.add(position.numberOfTokensBorrowed)).mul(priceOfLPToken).div(10 ** 18);
        uint loanValue = (priceOfLPToken > position.entryPrice) ? (priceOfLPToken.sub(position.entryPrice)).mul(position.numberOfTokensBorrowed).div(10 ** 18) : (position.entryPrice.sub(priceOfLPToken)).mul(position.numberOfTokensBorrowed).div(10 ** 18);

        return (priceOfLPToken > position.entryPrice) ? collateralValue.add(loanValue).sub(interestAccrued) : collateralValue.sub(loanValue).sub(interestAccrued);
    }

    /**
    * @dev Given the index of a position, returns whether the position can be liquidated
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return bool Whether the position can be liquidated
    */
    function checkIfPositionCanBeLiquidated(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (bool) {
        return (_getPriceOfLPToken(positionIndex) < calculateLiquidationPrice(positionIndex));
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
    * @dev Calculates the amount of interest accrued (in LP tokens) on a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Amount of interest accrued in asset tokens
    */
    function calculateInterestAccrued(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        uint interestRate = ISettings(settingsAddress).getParameterValue("InterestRateOnLeveragedLiquidityPositions");
        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        return position.numberOfTokensBorrowed.mul(block.timestamp.sub(position.entryTimestamp)).mul(interestRate).div(365 days);
    }

    /**
    * @dev Calculates the price at which a position can be liquidated
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Liquidation price
    */
    function calculateLiquidationPrice(uint positionIndex) public view override positionIndexInRange(positionIndex) returns (uint) {
        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];
        uint leverageFactor = calculateLeverageFactor(positionIndex);
        uint numerator = position.entryPrice.mul(8);
        uint denominator = leverageFactor.mul(10);

        return position.entryPrice.sub(numerator.div(denominator));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
    * @dev Opens a new leveraged position; swaps cUSD for specified asset
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param tokenA Address of first token in pair
    * @param tokenB Address of second token in pair
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    * @param farmAddress Address of token pair's Ubeswap farm
    */
    function openPosition(address tokenA, address tokenB, uint collateral, uint amountToBorrow, address farmAddress) public override {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");

        require(tokenA != address(0), "LeveragedLiquidityPositionManager: invalid address for tokenA");
        require(tokenB != address(0), "LeveragedLiquidityPositionManager: invalid address for tokenB");
        require(collateral > 0, "LeveragedLiquidityPositionManager: collateral must be greater than 0");
        require(amountToBorrow > 0, "LeveragedLiquidityPositionManager: amount to borrow must be greater than 0");
        require(amountToBorrow <= collateral.mul(9), "LeveragedLiquidityPositionManager: leverage cannot be higher than 10x");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(tokenA), "LeveragedLiquidityPositionManager: tokenA not available");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(tokenB), "LeveragedLiquidityPositionManager: tokenB not available");
        require(userPositions[msg.sender].length < ISettings(settingsAddress).getParameterValue("MaximumNumberOfLeveragedPositions"), "LeveragedLiquidityPositionManager: cannot exceed maximum number of leveraged positions");
        
        //Check if user has existing leveraged position with this pair
        address pair = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPair(tokenA, tokenB);
        //Add to position
        if (positionIndexes[msg.sender][pair] > 0)
        {
            _combinePositions(positionIndexes[msg.sender][pair].sub(1), collateral, amountToBorrow);
        }
        //Open a new position
        else
        {
            _openPosition(tokenA, tokenB, collateral, amountToBorrow, farmAddress);
            positionIndexes[msg.sender][pair] = numberOfLeveragedPositions;
        } 
    }

    /**
    * @dev Reduces the size of a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of tokens to sell
    */
    function reducePosition(uint positionIndex, uint numberOfTokens) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        require(numberOfTokens > 0, "LeveragedLiquidityPositionManager: number of tokens must be greater than 0");

        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        //Pay interest
        uint interestPaid = _payInterest(positionIndex);

        //Update state variables in rewards contract and claim available UBE
        getReward(positionIndex);
        _unstake(msg.sender, position.farm, numberOfTokens);

        require(numberOfTokens < position.collateral.add(position.numberOfTokensBorrowed), "LeveragedLiquidityPositionManager: number of tokens must be less than position size");

        //Calculate user and pool cUSD share
        uint userShare = _calculateUserUSDShare(positionIndex, numberOfTokens);
        uint poolShare = getPositionValue(positionIndex).sub(userShare).mul(numberOfTokens).div(position.collateral.add(position.numberOfTokensBorrowed));
       
        //Maintain leverage factor
        uint collateralToRemove = numberOfTokens.mul(position.collateral).div(position.collateral.add(position.numberOfTokensBorrowed));
        uint numberOfBorrowedTokensToRemove = numberOfTokens.mul(position.numberOfTokensBorrowed).div(position.collateral.add(position.numberOfTokensBorrowed));

        //Update state variables
        leveragedPositions[positionIndex].collateral = position.collateral.sub(collateralToRemove);
        leveragedPositions[positionIndex].numberOfTokensBorrowed = position.numberOfTokensBorrowed.sub(numberOfBorrowedTokensToRemove);

        //Remove liquidity
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        (uint amount0, uint amount1) = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).removeLiquidity(position.pair, position.farm, numberOfTokens);
        
        //Swap from token0 to cUSD
        uint cUSDReceived0 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(IUniswapV2Pair(position.pair).token0(), userShare, poolShare, amount0, msg.sender);

        //Swap from token1 to cUSD
        uint cUSDReceived1 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(IUniswapV2Pair(position.pair).token1(), userShare, poolShare, amount1, msg.sender);

        emit ReducedPosition(msg.sender, positionIndex, cUSDReceived0.add(cUSDReceived1), interestPaid, block.timestamp);
    }

    /**
    * @dev Closes a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function closePosition(uint positionIndex) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        //Pay interest
        uint interestAccrued = _payInterest(positionIndex);

        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        //Update state variables in rewards contract and claim available UBE
        _unstake(msg.sender, position.farm, position.collateral.add(position.numberOfTokensBorrowed).add(interestAccrued));
        getReward(positionIndex);

        //Get updated position size
        uint positionSize = position.collateral.add(position.numberOfTokensBorrowed);

        //Calculate user and pool cUSD share
        uint userShare = _calculateUserUSDShare(positionIndex, positionSize);
        uint poolShare = getPositionValue(positionIndex).sub(userShare);
        
        //Update state variables
        _removePosition(positionIndex);

        //Remove liquidity
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        (uint amount0, uint amount1) = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).removeLiquidity(position.pair, position.farm, positionSize);
        
        //Swap from token0 to cUSD
        uint cUSDReceived0 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(IUniswapV2Pair(position.pair).token0(), userShare, poolShare, amount0, msg.sender);

        //Swap from token1 to cUSD
        uint cUSDReceived1 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(IUniswapV2Pair(position.pair).token1(), userShare, poolShare, amount1, msg.sender);

        emit ClosedPosition(msg.sender, positionIndex, interestAccrued, cUSDReceived0.add(cUSDReceived1), block.timestamp);
    }

    /**
    * @dev Adds collateral to the leveraged position
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param amountOfUSD Amount of cUSD to add as collateral
    */
    function addCollateral(uint positionIndex, uint amountOfUSD) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        require(amountOfUSD > 0, "LeveragedAssetPositionManager: amount of USD must be greater than 0");

        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");

        address pair = position.pair;

        //Swap cUSD for token0
        uint numberOfTokensReceived0 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(IUniswapV2Pair(pair).token0(), amountOfUSD.div(2), 0, msg.sender);

        //Swap cUSD for token1
        uint numberOfTokensReceived1 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(IUniswapV2Pair(pair).token1(), amountOfUSD.div(2), 0, msg.sender);
        
        //Get current price of token0
        uint USDperToken0 = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(IUniswapV2Pair(pair).token0());

        //Get current price of token1
        uint USDperToken1 = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(IUniswapV2Pair(pair).token1());

        //Add liquidity
        uint numberOfLPTokens = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).addLiquidity(IUniswapV2Pair(pair).token0(), IUniswapV2Pair(pair).token1(), numberOfTokensReceived0, numberOfTokensReceived1, position.farm);

        //Claim available UBE and update state variables in rewards contract
        getReward(positionIndex);
        _stake(msg.sender, position.farm, numberOfLPTokens);

        //Calculate new entry price
        uint initialPositionValue = position.entryPrice.mul(position.collateral.add(position.numberOfTokensBorrowed));
        uint addedAmount = (USDperToken0.mul(numberOfTokensReceived0)).add(USDperToken1.mul(numberOfTokensReceived1));
        uint newEntryPrice = (initialPositionValue.add(addedAmount)).div(numberOfLPTokens.add(position.collateral).add(position.numberOfTokensBorrowed));
        
        //Update state variables
        leveragedPositions[positionIndex].collateral = position.collateral.add(numberOfLPTokens);
        leveragedPositions[positionIndex].entryPrice = newEntryPrice;

        emit AddedCollateral(msg.sender, positionIndex, numberOfLPTokens, block.timestamp);
    }

    /**
    * @dev Removes collateral from the leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateral(uint positionIndex, uint numberOfTokens) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        require(numberOfTokens > 0, "LeveragedLiquidityPositionManager: number of tokens must be greater than 0");
        require(numberOfTokens < leveragedPositions[positionIndex].collateral, "LeveragedLiquidityPositionManager: number of tokens must be less than collateral");

        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        //Claim available UBE and update state variables in rewards contract
        getReward(positionIndex);
        _unstake(msg.sender, position.farm, numberOfTokens);

        leveragedPositions[positionIndex].collateral = position.collateral.sub(numberOfTokens);

        require(calculateLeverageFactor(positionIndex) <= 10, "LeveragedLiquidityPositionManager: cannot exceed 10x leverage");

        //Remove liquidity
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        (uint amount0, uint amount1) = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).removeLiquidity(position.pair, position.farm, numberOfTokens);

        //Swap from token0 to cUSD
        uint cUSDReceived0 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(IUniswapV2Pair(position.pair).token0(), 100, 0, amount0, msg.sender);

        //Swap from token1 to cUSD
        uint cUSDReceived1 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapFromAsset(IUniswapV2Pair(position.pair).token1(), 100, 0, amount1, msg.sender);
    
        emit RemovedCollateral(msg.sender, positionIndex, numberOfTokens, cUSDReceived0.add(cUSDReceived1), block.timestamp);
    }

    /**
    * @dev Transfers leveraged position to another contract
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param newOwner Address of contract to transfer ownership to
    */
    function transferOwnership(uint positionIndex, address newOwner) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        require(newOwner != address(0), "LeveragedLiquidityPositionManager: invalid address for new owner");
        require(newOwner != msg.sender, "LeveragedLiquidityPositionManager: new owner is same as current owner");

        //Update state variable in rewards contract and send available UBE to user
        _transferOwnership(newOwner, positionIndex);

        //Check if new owner can add a new leveraged position
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        require(userPositions[newOwner].length < ISettings(settingsAddress).getParameterValue("MaximumNumberOfLeveragedPositions"), "LeveragedLiquidityPositionManager: new owner has too many leveraged positions");
    
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
    * @dev Claims available UBE rewards for the farm
    * @notice Sends a small percentage of claimed UBE to the function's caller as a reward for maintaining the protocol
    * @param farmAddress Address of the farm
    */
    function claimFarmUBE(address farmAddress) public override {
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        
        require (IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress) != address(0), "LeveragedLiquidityPositionManager: invalid farm address");

        (uint claimedUBE, uint keeperShare) = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).claimFarmUBE(msg.sender, farmAddress);

        _updateAvailableUBE(farmAddress, claimedUBE);

        emit ClaimedFarmUBE(msg.sender, farmAddress, claimedUBE, keeperShare, block.timestamp);
    }

    /**
    * @dev Liquidates part of the leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function liquidate(uint positionIndex) public override {
        require(checkIfPositionCanBeLiquidated(positionIndex), "LeveragedLiquidityPositionManager: current price is above liquidation price");

        //Pay interest
        _payInterest(positionIndex);

        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];
        address owner = leveragedPositions[positionIndex].owner;

        //Get updated position size
        uint positionSize = position.collateral.add(position.numberOfTokensBorrowed);

        //Get liquidation fee
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        uint liquidationFee = ISettings(settingsAddress).getParameterValue("LiquidationFee");

        //Calculate user and pool cUSD share
        uint userShare = _calculateUserUSDShare(positionIndex, positionSize);
        uint liquidatorShare = userShare.mul(liquidationFee).div(100);
        uint poolShare = getPositionValue(positionIndex).sub(userShare).sub(liquidatorShare);

        //Remove liquidity
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        (uint amount0, uint amount1) = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).removeLiquidity(position.pair, position.farm, positionSize);

        //Swap from token0 to cUSD
        uint cUSDReceived0 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).liquidateLeveragedAsset(IUniswapV2Pair(position.pair).token0(), userShare, liquidatorShare, poolShare, amount0, owner, msg.sender);

        //Swap from token1 to cUSD
        uint cUSDReceived1 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).liquidateLeveragedAsset(IUniswapV2Pair(position.pair).token1(), userShare, liquidatorShare, poolShare, amount1, owner, msg.sender);

        //Update state variables in rewards contract
        _unstake(position.owner, position.farm, positionSize);

        //Claim available UBE
        getReward(positionIndex);
        
        _removePosition(positionIndex);

        _decrementPositionCountIfAddressIsPool(owner);

        emit Liquidated(owner, msg.sender, positionIndex, cUSDReceived0.add(cUSDReceived1), liquidatorShare, block.timestamp);
    }

    /**
    * @dev Claims available UBE rewards for the position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function getReward(uint positionIndex) public override positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        //Claim available UBE for farm
        claimFarmUBE(leveragedPositions[positionIndex].farm);

        uint reward = _getReward(leveragedPositions[positionIndex].farm);

        _updateAvailableUBE(leveragedPositions[positionIndex].farm, reward);

        //Claim user's share of available UBE
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        IStableCoinStakingRewards(stableCoinStakingRewardsAddress).claimUserUBE(msg.sender, reward);

        emit RewardPaid(msg.sender, reward, leveragedPositions[positionIndex].farm, block.timestamp);
    }

    /**
    * @dev Transfers part of each position the caller has to the recipient; meant to be called from a Pool
    * @param recipient Address of user receiving the tokens
    * @param numerator Numerator used for calculating ratio of tokens
    * @param denominator Denominator used for calculating ratio of tokens
    */
    function bulkTransferTokens(address recipient, uint numerator, uint denominator) public override onlyPool {
        require(recipient != address(0), "LeveragedLiquidityPositionManager: invalid recipient address");
        require(numerator > 0, "LeveragedLiquidityPositionManager: numerator must be greater than 0");
        require(denominator > 0, "LeveragedLiquidityPositionManager: denominator must be greater than 0");

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

        delete positionIndexes[msg.sender][leveragedPositions[positionIndex].pair];

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

        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        //Remove interest accrued from LP token balance in rewards contract
        _unstake(position.owner, position.farm, interestAccrued);

        //Remove collateral and borrowed tokens to maintain leverage factor
        leveragedPositions[positionIndex].collateral = position.collateral.sub(interestAccrued);
        leveragedPositions[positionIndex].numberOfTokensBorrowed = position.numberOfTokensBorrowed.sub(interestAccrued.mul(calculateLeverageFactor(positionIndex)));
        leveragedPositions[positionIndex].entryTimestamp = block.timestamp;

        //Pay interest
        //Split payment evenly between the two tokens
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        if (interestAccrued > 0)
        {
            IStableCoinStakingRewards(stableCoinStakingRewardsAddress).payInterest(IUniswapV2Pair(position.pair).token0(), interestAccrued.div(2));
            IStableCoinStakingRewards(stableCoinStakingRewardsAddress).payInterest(IUniswapV2Pair(position.pair).token1(), interestAccrued.div(2));
        } 

        return interestAccrued;
    }

    /**
    * @dev Given the index of a position, returns the amount of USD received for the given number of LP tokens
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of LP tokens in the position's liquidity pair
    * @return uint Amount of USD received
    */
    function _calculateUserUSDShare(uint positionIndex, uint numberOfTokens) internal view positionIndexInRange(positionIndex) returns (uint) {
        require(numberOfTokens > 0, "LeveragedLiquidityPositionManager: number of tokens must be greater than 0");
        require(numberOfTokens <= leveragedPositions[positionIndex].collateral.add(leveragedPositions[positionIndex].numberOfTokensBorrowed), "LeveragedLiquidityPositionManager: number of tokens must be less than position size");

        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        uint collateralInUSD = position.entryPrice.mul(position.collateral);
        uint USDperToken = _getPriceOfLPToken(positionIndex);
        uint delta = (USDperToken > position.entryPrice) ?
                     (USDperToken.sub(position.entryPrice)).mul(position.collateral.add(position.numberOfTokensBorrowed)) :
                     (position.entryPrice.sub(USDperToken)).mul(position.collateral.add(position.numberOfTokensBorrowed));

        return (USDperToken > position.entryPrice) ?
               (collateralInUSD.add(delta)).mul(numberOfTokens).div(position.collateral.add(position.numberOfTokensBorrowed)) :
               (collateralInUSD.sub(delta)).mul(numberOfTokens).div(position.collateral.add(position.numberOfTokensBorrowed));
    }

    /**
    * @dev Given the index of a position, returns the price of the position's pair's LP tokens
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Price of LP token
    */
    function _getPriceOfLPToken(uint positionIndex) internal view positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) returns (uint) {
        uint positionValue = getPositionValue(positionIndex);
        uint positionSize = leveragedPositions[positionIndex].collateral.add(leveragedPositions[positionIndex].numberOfTokensBorrowed);
        return positionValue.div(positionSize);
    }

    /**
    * @dev Adds collateral and loan to existing position, and recalculates entry price
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function _combinePositions(uint positionIndex, uint collateral, uint amountToBorrow) internal positionIndexInRange(positionIndex) onlyPositionOwner(positionIndex) {
        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        address pair = position.pair;

        _payInterest(positionIndex);

        //Swap cUSD for token0
        uint numberOfTokensReceived0 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(IUniswapV2Pair(pair).token0(), (collateral.add(amountToBorrow)).div(2), 0, msg.sender);

        //Swap cUSD for token1
        uint numberOfTokensReceived1 = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(IUniswapV2Pair(pair).token1(), (collateral.add(amountToBorrow)).div(2), 0, msg.sender);

        //Add liquidity
        uint numberOfLPTokens = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).addLiquidity(IUniswapV2Pair(pair).token0(), IUniswapV2Pair(pair).token1(), numberOfTokensReceived0, numberOfTokensReceived1, position.farm);

        //Calculate new entry price
        uint initialPositionValue = position.entryPrice.mul(position.collateral.add(position.numberOfTokensBorrowed));
        uint addedAmount = collateral.add(amountToBorrow);
        uint newEntryPrice = (initialPositionValue.add(addedAmount)).div(numberOfLPTokens.add(position.collateral).add(position.numberOfTokensBorrowed));
        
        //Update state variables
        leveragedPositions[positionIndex].collateral = position.collateral.add(numberOfLPTokens.mul(collateral).div(addedAmount));
        leveragedPositions[positionIndex].numberOfTokensBorrowed = position.numberOfTokensBorrowed.add(numberOfLPTokens.mul(amountToBorrow).div(addedAmount));
        leveragedPositions[positionIndex].entryPrice = newEntryPrice;

        //Update state variables in rewards contract
        _stake(msg.sender, position.farm, numberOfLPTokens);

        emit CombinedPosition(msg.sender, positionIndex, collateral, amountToBorrow, block.timestamp);
    }

    /**
    * @dev Opens a new leveraged position; swaps cUSD for specified asset
    * @param tokenA Address of first token in pair
    * @param tokenB Address of second token in pair
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    * @param farmAddress Address of token pair's Ubeswap farm
    */
    function _openPosition(address tokenA, address tokenB, uint collateral, uint amountToBorrow, address farmAddress) internal {
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        
        //Check if farm exists for the token pair
        address stakingTokenAddress = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress);
        address pairAddress = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPair(tokenA, tokenB);
        require(stakingTokenAddress == pairAddress, "Pool: stakingTokenAddress does not match pairAddress");

        //Swap cUSD for tokenA
        uint amountA = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(tokenA, collateral.div(2), amountToBorrow.div(2), msg.sender);

        //Swap cUSD for tokenB
        uint amountB = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).swapToAsset(tokenB, collateral.div(2), amountToBorrow.div(2), msg.sender);

        //Add liquidity
        uint numberOfLPTokens = IStableCoinStakingRewards(stableCoinStakingRewardsAddress).addLiquidity(tokenA, tokenB, amountA, amountB, farmAddress);
        
        //Adjust collateral and amountToBorrow to asset tokens
        uint adjustedCollateral = numberOfLPTokens.mul(collateral).div(collateral.add(amountToBorrow));
        uint adjustedAmountToBorrow = numberOfLPTokens.mul(amountToBorrow).div(collateral.add(amountToBorrow));

        //Get entry price; used for calculating liquidation price
        uint USDperToken = (collateral.add(amountToBorrow)).div(numberOfLPTokens);

        leveragedPositions[numberOfLeveragedPositions] = LeveragedLiquidityPosition(msg.sender, pairAddress, farmAddress, block.timestamp, adjustedCollateral, adjustedAmountToBorrow, USDperToken, userPositions[msg.sender].length);
        userPositions[msg.sender].push(numberOfLeveragedPositions);
        numberOfLeveragedPositions = numberOfLeveragedPositions.add(1);

        //Update state variables in rewards contract
        _stake(msg.sender, farmAddress, numberOfLPTokens);

        emit OpenedPosition(msg.sender, pairAddress, adjustedCollateral, adjustedAmountToBorrow, USDperToken, numberOfLeveragedPositions.sub(1), block.timestamp);
    }

    /**
    * @dev Updates state variables in rewards contract and sends old owner their share of UBE rewards
    * @param newOwner New owner of the position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function _transferOwnership(address newOwner, uint positionIndex) internal {
        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        _unstake(msg.sender, position.farm, position.collateral.add(position.numberOfTokensBorrowed));

        getReward(positionIndex);

        _stake(newOwner, position.farm, position.collateral.add(position.numberOfTokensBorrowed));
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
    * @dev Transfers part of a position to another user; meant to be called from a Pool
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param recipient Address of user receiving the tokens
    * @param numerator Numerator used for calculating ratio of tokens
    * @param denominator Denominator used for calculating ratio of tokens
    */
    function _transferTokens(uint positionIndex, address recipient, uint numerator, uint denominator) internal positionIndexInRange(positionIndex) {
        LeveragedLiquidityPosition memory position = leveragedPositions[positionIndex];

        uint numberOfTokens = (position.collateral.add(position.numberOfTokensBorrowed)).mul(numerator).div(denominator);
        
        if (numberOfTokens == position.collateral.add(position.numberOfTokensBorrowed))
        {
            transferOwnership(positionIndex, recipient);
        }
        else
        {
            //Check if recipient can add a new leveraged position
            address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
            require(userPositions[recipient].length < ISettings(settingsAddress).getParameterValue("MaximumNumberOfLeveragedPositions"), "LeveragedLiquidityPositionManager: recipient has too many leveraged positions");
        
            _unstake(msg.sender, position.farm, numberOfTokens);
            _stake(recipient, position.farm, numberOfTokens);

            //Combine positions if recipient already has a position in this farm
            uint recipientPositionIndex = positionIndexes[recipient][position.pair];
            //Combine positions
            if (recipientPositionIndex > 0)
            {
                LeveragedLiquidityPosition memory recipientPosition = leveragedPositions[recipientPositionIndex.sub(1)];
                
                //Update state variables
                leveragedPositions[recipientPositionIndex.sub(1)].collateral = recipientPosition.collateral.add(numberOfTokens.mul(recipientPosition.collateral).div(recipientPosition.collateral.add(recipientPosition.numberOfTokensBorrowed)));
                leveragedPositions[recipientPositionIndex.sub(1)].numberOfTokensBorrowed = recipientPosition.numberOfTokensBorrowed.add(numberOfTokens.mul(recipientPosition.collateral).div(recipientPosition.collateral.add(recipientPosition.numberOfTokensBorrowed)));
            }
            //Open a new position
            else
            {
                uint collateral = numberOfTokens.div(calculateLeverageFactor(positionIndex));
                leveragedPositions[numberOfLeveragedPositions] = LeveragedLiquidityPosition(msg.sender, position.pair, position.farm, block.timestamp, collateral, numberOfTokens.sub(collateral), position.entryPrice, userPositions[msg.sender].length);
                userPositions[recipient].push(numberOfLeveragedPositions);
                numberOfLeveragedPositions = numberOfLeveragedPositions.add(1);
                positionIndexes[recipient][position.pair] = numberOfLeveragedPositions;
            }
        }
    }

    /* ========== MODIFIERS ========== */

    modifier onlyPool() {
        require(ADDRESS_RESOLVER.checkIfPoolAddressIsValid(msg.sender), "LeveragedLiquidityPositionManager: only a Pool can call this function");
        _;
    }

    modifier onlyPositionOwner(uint positionIndex) {
        require(leveragedPositions[positionIndex].owner == msg.sender, "LeveragedLiquidityPositionManager: only position owner can call this function");
        _;
    }

    modifier positionIndexInRange(uint positionIndex) {
        require(positionIndex > 0, "LeveragedLiquidityPositionManager: position index must be greater than 0");
        require(positionIndex < numberOfLeveragedPositions, "LeveragedLiquidityPositionManager: position index out of range");
        _;
    }

    modifier validFarmAddress(uint positionIndex, address farmAddress) {
        address pair = leveragedPositions[positionIndex].pair;
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");

        require(farmAddress != address(0), "LeveragedLiquidityPositionManager: invalid farm address");
        require(pair == IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress), "LeveragedLiquidityPositionManager: farm staking token does not match pair address");
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
    event ClaimedFarmUBE(address indexed user, address indexed farm, uint claimedUBE, uint keeperShare, uint timestamp);
    event RewardPaid(address indexed user, uint amount, address farmAddress, uint timestamp);
}