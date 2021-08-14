pragma solidity >=0.5.0;

import './IUniswapV2Router02.sol';

interface IBaseUbeswapAdapter {
    function MAX_SLIPPAGE_PERCENT() external returns (uint);

    /**
    * @dev Given an input asset address, returns the price of the asset in cUSD
    * @param currencyKey Address of the asset
    * @return uint Price of the asset
    */
    function getPrice(address currencyKey) external view returns (uint);

    /**
    * @dev Given an input asset amount, returns the maximum output amount of the other asset
    * @param numberOfTokens Number of tokens
    * @param currencyKeyIn Address of the asset to be swap from
    * @param currencyKeyOut Address of the asset to be swap to
    * @return uint Amount out of the asset
    */
    function getAmountsOut(uint numberOfTokens, address currencyKeyIn, address currencyKeyOut) external view returns (uint);

    /**
    * @dev Given the target output asset amount, returns the amount of input asset needed
    * @param numberOfTokens Target amount of output asset
    * @param currencyKeyIn Address of the asset to be swap from
    * @param currencyKeyOut Address of the asset to be swap to
    * @return uint Amount out input asset needed
    */
    function getAmountsIn(uint numberOfTokens, address currencyKeyIn, address currencyKeyOut) external view returns (uint);

    /**
    * @dev Swaps an exact `amountToSwap` of an asset to another; meant to be called from a user pool
    * @param assetToSwapFrom Origin asset
    * @param assetToSwapTo Destination asset
    * @param amountToSwap Exact amount of `assetToSwapFrom` to be swapped
    * @param minAmountOut the min amount of `assetToSwapTo` to be received from the swap
    * @return uint The number of tokens received
    */
    function swapFromPool(address assetToSwapFrom, address assetToSwapTo, uint amountToSwap, uint minAmountOut) external returns (uint);

    /**
    * @dev Swaps an exact `amountToSwap` of an asset to another; meant to be called from a trading bot
    * @param assetToSwapFrom Origin asset
    * @param assetToSwapTo Destination asset
    * @param amountToSwap Exact amount of `assetToSwapFrom` to be swapped
    * @param minAmountOut the min amount of `assetToSwapTo` to be received from the swap
    * @return uint The number of tokens received
    */
    function swapFromBot(address assetToSwapFrom, address assetToSwapTo, uint amountToSwap, uint minAmountOut) external returns (uint);

    /**
    * @dev Swaps an exact `amountToSwap` of an asset to another; meant to be called from stable coin staking pool
    * @param assetToSwapFrom Origin asset
    * @param assetToSwapTo Destination asset
    * @param amountToSwap Exact amount of `assetToSwapFrom` to be swapped
    * @param minAmountOut the min amount of `assetToSwapTo` to be received from the swap
    * @return uint The number of tokens received
    */
    function swapFromStableCoinPool(address assetToSwapFrom, address assetToSwapTo, uint amountToSwap, uint minAmountOut) external returns (uint);

    /**
    * @dev Adds liquidity for the two given tokens; meant to be called from a pool
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param amountA Amount of first token
    * @param amountB Amount of second token
    * @return uint The number of tokens LP tokens minted
    */
    function addLiquidity(address tokenA, address tokenB, uint amountA, uint amountB) external returns (uint);

    /**
    * @dev Removes liquidity for the two given tokens; meant to be called from a pool
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param numberOfLPTokens Number of LP tokens for the given pair
    * @return (uint, uint) Amount of tokenA and tokenB withdrawn
    */
    function removeLiquidity(address tokenA, address tokenB, uint numberOfLPTokens) external returns (uint, uint);

    /**
    * @dev Returns the farm address and liquidity pool address for each available farm on Ubeswap
    * @return address[] memory The farm address for each available farm
    */
    function getAvailableUbeswapFarms() external view returns (address[] memory);

    /**
    * @dev Given the address of a farm on Ubeswap, returns the farm's staking token address
    * @param farmAddress Address of the farm to check
    * @return address The farm's staking token address
    */
    function checkIfFarmExists(address farmAddress) external view returns (address);

    /**
    * @dev Returns the address of a token pair
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @return address The pair's address
    */
    function getPair(address tokenA, address tokenB) external view returns (address);

    /**
    * @dev Returns the amount of UBE rewards available for the pool in the given farm
    * @param poolAddress Address of the pool
    * @param farmAddress Address of the farm on Ubeswap
    * @return uint Amount of UBE available
    */
    function getAvailableRewards(address poolAddress, address farmAddress) external view returns (uint);

    /**
    * @dev Calculates the amount of tokens in a pair
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param numberOfLPTokens Number of LP tokens for the given pair
    * @return (uint, uint) The number of tokens for tokenA and tokenB
    */
    function getTokenAmountsFromPair(address tokenA, address tokenB, uint numberOfLPTokens) external view returns (uint, uint);
}