pragma solidity >=0.5.0;

interface IAddressResolver {
    /**
    * @dev Given a contract name, returns the address of the contract
    * @param contractName The name of the contract
    * @return address The address associated with the given contract name
    */
    function getContractAddress(string memory contractName) external view returns (address);

    /**
    * @dev Given an address, returns whether the address belongs to a trading bot
    * @param tradingBotAddress The address to validate
    * @return bool Whether the given address is a valid trading bot address
    */
    function checkIfTradingBotAddressIsValid(address tradingBotAddress) external view returns (bool);

    /**
    * @dev Given an address, returns whether the address belongs to a strategy
    * @param strategyAddress The address to validate
    * @return bool Whether the given address is a valid strategy address
    */
    function checkIfStrategyAddressIsValid(address strategyAddress) external view returns (bool);

    /**
    * @dev Given an address, returns whether the address belongs to a user pool
    * @param poolAddress The address to validate
    * @return bool Whether the given address is a valid user pool address
    */
    function checkIfPoolAddressIsValid(address poolAddress) external view returns (bool);

    /**
    * @dev Updates the address for the given contract; meant to be called by AddressResolver owner
    * @param contractName The name of the contract
    * @param newAddress The new address for the given contract
    */
    function setContractAddress(string memory contractName, address newAddress) external;

    /**
    * @dev Adds a new trading bot address; meant to be called by the Strategy contract that owns the trading bot
    * @param tradingBotAddress The address of the trading bot
    */
    function addTradingBotAddress(address tradingBotAddress) external;

    /**
    * @dev Adds a new strategy address; meant to be called by the StrategyManager contract
    * @param strategyAddress The address of the strategy
    */
    function addStrategyAddress(address strategyAddress) external;

    /**
    * @dev Adds a new user pool address; meant to be called by the PoolManager contract
    * @param poolAddress The address of the user pool
    */
    function addPoolAddress(address poolAddress) external;
}