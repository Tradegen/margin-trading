pragma solidity >=0.5.0;

interface ISettings {
    /**
    * @dev Given the index in the array of available currencies, returns the currency key at that index
    * @param index Index in the array of available currencies
    * @return address Currency key at given index
    */
    function getCurrencyKeyFromIndex(uint index) external view returns (address);

    /**
    * @dev Given the symbol of a currency, returns the address of the currency
    * @param symbol The symbol of the currency
    * @return address Currency key for given symbol
    */
    function getCurrencyKeyFromSymbol(string memory symbol) external view returns (address);

    /**
    * @dev Given the name of a parameter, returns the value of the parameter
    * @param parameter The name of the parameter to get value for
    * @return uint The value of the given parameter
    */
    function getParameterValue(string memory parameter) external view returns (uint);

    /**
    * @dev Returns the addresses of supported currencies for trading
    * @return address[] An array of addresses of supported currencies
    */
    function getAvailableCurrencies() external view returns (address[] memory);

    /**
    * @dev Given the address of a currency, returns the currency's symbol
    * @param currencyKey The address of the currency
    * @return string The currency symbol
    */
    function getCurrencySymbol(address currencyKey) external view returns (string memory);

    /**
    * @dev Returns the address of the stable coin
    * @return address The stable coin address
    */
    function getStableCoinAddress() external view returns (address);

    /**
    * @dev Returns the addresses and names of supported oracle APIs
    * @return OracleData[] An array of oracle API addresses and names
    */
    function getOracleAPIs() external view returns (address[] memory);

    /**
    * @dev Given the address of an oracle API, returns the name of the oracle API
    * @param oracleAddress The address of the oracle API
    * @return string The oracle API name
    */
    function getOracleAPIName(address oracleAddress) external view returns (string memory);

    /**
    * @dev Given the address of a currency, returns whether the currency is supported on the platform
    * @param currencyKey The address of the currency
    * @return bool Whether the currency is supported on the platform
    */
    function checkIfCurrencyIsAvailable(address currencyKey) external view returns (bool);

    /**
    * @dev Updates the address for the given contract; meant to be called by Settings contract owner
    * @param parameter The name of the parameter to change
    * @param newValue The new value of the given parameter
    */
    function setParameterValue(string memory parameter, uint newValue) external;

    /**
    * @dev Sets the address of the stable coin
    * @param stableCoinAddress The address of the stable coin
    */
    function setStableCoinAddress(address stableCoinAddress) external;

    /**
    * @dev Updates the address of the given currency
    * @param currencySymbol The currency symbol
    * @param newCurrencyKey The new address for the given currency
    */
    function updateCurrencyKey(string memory currencySymbol, address newCurrencyKey) external;

    /**
    * @dev Adds a new tradable currency to the platform
    * @param currencySymbol The symbol of the currency to add
    * @param currencyKey The address of the currency to add
    */
    function addCurrencyKey(string memory currencySymbol, address currencyKey) external;

    /**
    * @dev Updates the address of a given oracle API
    * @param oldOracleAddress The address of the oracle API to update
    * @param newOracleAddress The new address of the given oracle API
    */
    function updateOracleAPIAddress(address oldOracleAddress, address newOracleAddress) external;

    /**
    * @dev Adds a new oracle API to the platform
    * @param name The name of the oracle API
    * @param oracleAddress The address of the oracle API
    */
    function addOracleAPIAddress(string memory name, address oracleAddress) external;
}