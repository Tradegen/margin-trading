pragma solidity >=0.5.0;

interface IPool {

    struct PositionKeyAndBalance {
        address positionKey;
        uint balance;
    }

    struct InvestorAndBalance {
        address investor;
        uint balance;
    }

    /**
    * @dev Returns the name of the pool
    * @return string The name of the pool
    */
    function name() external view returns (string memory);

    /**
    * @dev Returns the address of the pool's farm
    * @return address Address of the pool's farm
    */
    function getFarmAddress() external view returns (address);

    /**
    * @dev Return the pool manager's address
    * @return address Address of the pool's manager
    */
    function getManagerAddress() external view returns (address);

    /**
    * @dev Returns the currency address and balance of each position the pool has, as well as the cumulative value
    * @return (address[], uint[], uint) Currency address and balance of each position the pool has, and the cumulative value of positions
    */
    function getPositionsAndTotal() external view returns (address[] memory, uint[] memory, uint);

    /**
    * @dev Returns the amount of stable coins the pool has to invest
    * @return uint Amount of stable coin the pool has available
    */
    function getAvailableFunds() external view returns (uint);

    /**
    * @dev Returns the value of the pool in USD
    * @return uint Value of the pool in USD
    */
    function getPoolBalance() external view returns (uint);

    /**
    * @dev Returns the balance of the user in USD
    * @return uint Balance of the user in USD
    */
    function getUSDBalance(address user) external view returns (uint);

    /**
    * @dev Returns the number of LP tokens the user has
    * @param user Address of the user
    * @return uint Number of LP tokens the user has
    */
    function balanceOf(address user) external view returns (uint);

    /**
    * @dev Deposits the given USD amount into the pool
    * @notice Call cUSD.approve() before calling this function
    * @param amount Amount of USD to deposit into the pool
    */
    function deposit(uint amount) external;

    /**
    * @dev Withdraws the given USD amount on behalf of the user
    * @param amount Amount of USD to withdraw from the pool
    */
    function withdraw(uint amount) external;

    /**
    * @dev Places an order to buy/sell the given currency
    * @param currencyKey Address of currency to trade
    * @param buyOrSell Whether the user is buying or selling
    * @param numberOfTokens Number of tokens of the given currency
    */
    function placeOrder(address currencyKey, bool buyOrSell, uint numberOfTokens) external;

    /**
    * @dev Updates the pool's farm address
    * @param farmAddress Address of the pool's farm
    */
    function setFarmAddress(address farmAddress) external;

    /**
    * @dev Returns the pool's performance fee
    * @return uint The pool's performance fee
    */
    function getPerformanceFee() external view returns (uint);

    /**
    * @dev Adds liquidity for the two given tokens
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param amountA Amount of first token
    * @param amountB Amount of second token
    * @param farmAddress The token pair's farm address
    */
    function addLiquidity(address tokenA, address tokenB, uint amountA, uint amountB, address farmAddress) external;

    /**
    * @dev Removes liquidity for the two given tokens
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param farmAddress The token pair's farm address
    * @param numberOfLPTokens Number of LP tokens to remove from the farm
    */
    function removeLiquidity(address tokenA, address tokenB, address farmAddress, uint numberOfLPTokens) external;

    /**
    * @dev Collects available UBE rewards for the given Ubeswap farm
    * @param farmAddress The token pair's farm address
    */
    function claimUbeswapRewards(address farmAddress) external;

    /**
    * @dev Opens a new leveraged asset position; swaps cUSD for specified asset
    * @notice LeveragedAssetPositionManager checks if currency is supported
    * @param underlyingAsset Address of the leveraged asset
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function openLeveragedAssetPosition(address underlyingAsset, uint collateral, uint amountToBorrow) external;

    /**
    * @dev Reduces the size of a leveraged asset position
    * @notice LeveragedAssetPositionManager checks if pool is owner of position at given index
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of tokens to sell
    */
    function reduceLeveragedAssetPosition(uint positionIndex, uint numberOfTokens) external;

    /**
    * @dev Closes a leveraged asset position
    * @notice LeveragedAssetPositionManager checks if pool is owner of position at given index
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function closeLeveragedAssetPosition(uint positionIndex) external;

    /**
    * @dev Adds collateral to the leveraged asset position
    * @notice LeveragedAssetPositionManager checks if pool is owner of position at given index
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param amountOfUSD Amount of cUSD to add as collateral
    */
    function addCollateralToLeveragedAssetPosition(uint positionIndex, uint amountOfUSD) external;

    /**
    * @dev Removes collateral from the leveraged asset position
    * @notice LeveragedAssetPositionManager checks if pool is owner of position at given index
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateralFromLeveragedAssetPosition(uint positionIndex, uint numberOfTokens) external;

    /**
    * @dev Opens a new leveraged liquidity position; swaps cUSD for specified asset
    * @notice LeveragedLiquidityPositionManager checks if tokens are supported
    * @notice LeveragedLiquidityPositionManager checks if farmAddress is supported
    * @param tokenA Address of first token in pair
    * @param tokenB Address of second token in pair
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    * @param farmAddress Address of token pair's Ubeswap farm
    */
    function openLeveragedLiquidityPosition(address tokenA, address tokenB, uint collateral, uint amountToBorrow, address farmAddress) external;

    /**
    * @dev Reduces the size of a leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of tokens to sell
    */
    function reduceLeveragedLiquidityPosition(uint positionIndex, uint numberOfTokens) external;

    /**
    * @dev Closes a leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function closeLeveragedLiquidityPosition(uint positionIndex) external;

    /**
    * @dev Adds collateral to the leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param amountOfUSD Amount of cUSD to add as collateral
    */
    function addCollateralToLeveragedLiquidityPosition(uint positionIndex, uint amountOfUSD) external;

    /**
    * @dev Removes collateral from the leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateralFromLeveragedLiquidityPosition(uint positionIndex, uint numberOfTokens) external;

    /**
    * @dev Claims available UBE rewards for the leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function getReward(uint positionIndex) external;

    /**
    * @dev Decrement's the totalNumberOfPositions
    * @notice Called from liquidate() in LeveragedAssetPositionManager or LeveragedLiquidityPositionManager
    */
    function decrementTotalPositionCount() external;
}