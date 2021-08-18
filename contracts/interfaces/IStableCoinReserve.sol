pragma solidity >=0.5.0;

interface IStableCoinReserve {
    /**
     * @notice Swaps cUSD for specified asset; meant to be called from an LToken contract
     * @param asset Asset to swap to
     * @param collateral Amount of cUSD to transfer from user
     * @param borrowedAmount Amount of cUSD borrowed
     * @param user Address of the user
     * @return uint Number of asset tokens received
     */
    function swapToAsset(address asset, uint collateral, uint borrowedAmount, address user) external returns (uint);

    /**
     * @notice Swaps specified asset for cUSD; meant to be called from an LToken contract
     * @param asset Asset to swap from
     * @param userShare User's ratio of received tokens
     * @param poolShare Pool's ratio of received tokens
     * @param numberOfAssetTokens Number of asset tokens to swap
     * @param user Address of the user
     * @return uint Amount of cUSD user received
     */
    function swapFromAsset(address asset, uint userShare, uint poolShare, uint numberOfAssetTokens, address user) external returns (uint);

    /**
     * @notice Liquidates a leveraged asset; meant to be called from an LToken contract
     * @param asset Asset to swap from
     * @param userShare User's ratio of received tokens
     * @param liquidatorShare Liquidator's ratio of received tokens
     * @param poolShare Pool's ration of received tokens
     * @param numberOfAssetTokens Number of asset tokens to swap
     * @param user Address of the user
     * @param liquidator Address of the liquidator
     * @return uint Amount of cUSD user received
     */
    function liquidateLeveragedAsset(address asset, uint userShare, uint liquidatorShare, uint poolShare, uint numberOfAssetTokens, address user, address liquidator) external returns (uint);

    /**
     * @notice Pays interest in the given asset; meant to be called from an LToken contract
     * @param asset Asset to swap from
     * @param numberOfAssetTokens Number of asset tokens to swap
     */
    function payInterest(address asset, uint numberOfAssetTokens) external;

    /**
     * @notice Claims farm's UBE rewards for leveraged yield farming
     * @notice Sends a small percentage of claimed UBE to user as a reward
     * @param user Address of the user
     * @param farmAddress Address of the farm
     * @return (uint, uint) Amount of UBE claimed and keeper's share
     */
    function claimFarmUBE(address user, address farmAddress) external returns (uint, uint);

    /**
     * @notice Claims user's UBE rewards for leveraged yield farming
     * @param user Address of the user
     * @param amountOfUBE Amount of UBE to transfer to user
     */
    function claimUserUBE(address user, uint amountOfUBE) external;

    /**
    * @dev Adds liquidity for the two given tokens
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param amountA Amount of first token
    * @param amountB Amount of second token
    * @param farmAddress The token pair's farm address on Ubeswap
    * @return uint Number of LP tokens received
    */
    function addLiquidity(address tokenA, address tokenB, uint amountA, uint amountB, address farmAddress) external returns (uint);

    /**
    * @dev Removes liquidity for the two given tokens
    * @param pair Address of liquidity pair
    * @param farmAddress The token pair's farm address on Ubeswap
    * @param numberOfLPTokens Number of LP tokens to remove
    * @return (uint, uint) Amount of pair's token0 and token1 received
    */
    function removeLiquidity(address pair, address farmAddress, uint numberOfLPTokens) external returns (uint, uint);
}