pragma solidity >=0.5.0;

interface ILToken {
    /**
    * @dev Given the address of a user, returns the user's position info
    * @param user Address of the user
    * @return (address, uint, uint uint, uint, uint) Underlying asset, entry price, entry timestamp, number of tokens collateral, number of tokens borrowed, and expiration time
    */
    function getPositionInfo(address user) external view returns (address, uint, uint, uint, uint, uint);

    /**
    * @dev Given the address of a user, returns the user's position value in USD
    * @param user Address of the user
    * @return uint Value of the position in USD
    */
    function getPositionValue(address user) external view returns (uint);

    /**
    * @dev Returns whether the user's position can be liquidated
    * @param user Address of the user
    * @return bool Whether the user's position can be liquidated
    */
    function checkIfPositionCanBeLiquidated(address user) external view returns (bool);

    /**
    * @dev Given the address of a user, returns the user's position's leverage factor; (number of tokens borrowed + interest accrued) / collateral
    * @param user Address of the user
    * @return uint Leverage factor
    */
    function calculateLeverageFactor(address user) external view returns (uint);

    /**
    * @dev Calculates the amount of interest accrued (in asset tokens) on a leveraged position
    * @param user Address of the user
    * @return uint Amount of interest accrued in asset tokens
    */
    function calculateInterestAccrued(address user) external view returns (uint);

    /**
    * @dev Calculates the price at which a position can be liquidated
    * @param user Address of the user
    * @return uint Liquidation price
    */
    function calculateLiquidationPrice(address user) external view returns (uint);

    /**
    * @dev Opens a new leveraged position; swaps cUSD for specified asset
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param amountOfCollateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function openPosition(uint amountOfCollateral, uint amountToBorrow) external;

    /**
    * @dev Reduces the size of a leveraged position while maintaining leverage factor
    * @param numberOfTokens Number of asset tokens to sell
    */
    function reducePosition(uint numberOfTokens) external;

    /**
    * @dev Closes a leveraged position
    */
    function closePosition() external;

    /**
    * @dev Adds collateral to the leveraged position
    * @notice User needs to approve cUSD for StableCoinStakingRewards contract before calling this function
    * @param amountOfUSD Amount of cUSD to add as collateral; cUSD is swapped for asset tokens
    */
    function addCollateral(uint amountOfUSD) external;

    /**
    * @dev Removes collateral from the leveraged position
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateral(uint numberOfTokens) external;

    /**
    * @dev Liquidates part of the leveraged position
    * @param user Address of the user
    */
    function liquidate(address user) external;
}