pragma solidity >=0.5.0;

interface ILeveragedAssetPositionManager {
    struct LeveragedAssetPosition {
        address owner;
        address underlyingAsset;
        uint entryTimestamp;
        uint collateral;
        uint numberOfTokensBorrowed;
        uint entryPrice;
        uint indexInOwnerPositionArray;
    }

    /**
    * @dev Returns the index of each leveraged position the user has
    * @param user Address of the user
    * @return uint[] Index of each position
    */
    function getUserPositions(address user) external view returns (uint[] memory);

    /**
    * @dev Given the index of a leveraged position, return the position info
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return (address, address, uint, uint, uint, uint) Leveraged position's owner, underlying asset, entry timestamp, number of tokens collateral, number of tokens borrowed, and entry price
    */
    function getPositionInfo(uint positionIndex) external view returns (address, address, uint, uint, uint, uint);

    /**
    * @dev Given the index of a leveraged position, returns the position value in USD
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Value of the position in USD
    */
    function getPositionValue(uint positionIndex) external view returns (uint);

    /**
    * @dev Given the index of a position, returns whether the position can be liquidated
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return bool Whether the position can be liquidated
    */
    function checkIfPositionCanBeLiquidated(uint positionIndex) external view returns (bool);

    /**
    * @dev Given the index of a position, returns the position's leverage factor; (number of tokens borrowed + interest accrued) / collateral
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Leverage factor
    */
    function calculateLeverageFactor(uint positionIndex) external view returns (uint);

    /**
    * @dev Calculates the amount of interest accrued (in asset tokens) on a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Amount of interest accrued in asset tokens
    */
    function calculateInterestAccrued(uint positionIndex) external view returns (uint);

    /**
    * @dev Calculates the price at which a position can be liquidated
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @return uint Liquidation price
    */
    function calculateLiquidationPrice(uint positionIndex) external view returns (uint);

    /**
    * @dev Opens a new leveraged position; swaps cUSD for specified asset
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param underlyingAsset Address of the leveraged asset
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function openPosition(address underlyingAsset, uint collateral, uint amountToBorrow) external;

    /**
    * @dev Reduces the size of a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of asset tokens to sell
    */
    function reducePosition(uint positionIndex, uint numberOfTokens) external;

    /**
    * @dev Closes a leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function closePosition(uint positionIndex) external;

    /**
    * @dev Adds collateral to the leveraged position
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param amountOfUSD Amount of cUSD to add as collateral
    */
    function addCollateral(uint positionIndex, uint amountOfUSD) external;

    /**
    * @dev Removes collateral from the leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateral(uint positionIndex, uint numberOfTokens) external;

    /**
    * @dev Transfers leveraged position to another contract
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param newOwner Address of contract to transfer ownership to
    */
    function transferOwnership(uint positionIndex, address newOwner) external;

    /**
    * @dev Liquidates part of the leveraged position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function liquidate(uint positionIndex) external;

    /**
    * @dev Transfers part of each position the caller has to the recipient; meant to be called from a Pool
    * @param recipient Address of user receiving the tokens
    * @param numerator Numerator used for calculating ratio of tokens
    * @param denominator Denominator used for calculating ratio of tokens
    */
    function bulkTransferTokens(address recipient, uint numerator, uint denominator) external;
}