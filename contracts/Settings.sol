pragma solidity >=0.5.0;

//Interfaces
import './interfaces/ISettings.sol';

//Libraries
import './libraries/SafeMath.sol';

//Inheritance
import './Ownable.sol';

contract Settings is ISettings, Ownable {
    using SafeMath for uint;

    mapping (string => uint) public parameters;

    //currencies
    address public cUSDAddress;
    address[] public availableCurrencies;
    mapping (address => uint) public currencyKeyToIndex; //maps to (index + 1); index 0 represents currency key not found
    mapping (string => address) public currencySymbolToAddress;
    mapping (address => string) public currencyKeyToSymbol;

    //oracles
    address[] public oracleAPIAddresses;
    mapping (address => uint) public isValidOracleAPIAddress; // maps to (index + 1) in oracleAPIAddresses array; index 0 represents invalid API address
    mapping (address => string) public oracleAddressToName;

    /**
    * @notice Initial parameters and values:
    *         WeeklyStakingFarmRewards - 500,000 TGEN; 
    *         WeeklyStableCoinStakingRewards - 500,000 TGEN;
    *         WeeklyStakingRewards - 500,000 TGEN; 
    *         TransactionFee - 0.3%;
    *         VoteLimit - 10;
    *         VotingReward - 3 TGEN;
    *         StrategyApprovalThreshold - 80%;
    *         MaximumNumberOfEntryRules - 7;
    *         MaximumNumberOfExitRules - 7;
    *         MaximumNumberOfPoolsPerUser - 2;
    *         MaximumPerformanceFee - 30%;
    *         MaximumNumberOfPositionsInPool - 6;
    *         MaximumNumberOfLeveragedPositions - 10;
    *         InterestRateOnLeveragedAssets - 4%;
    *         InterestRateOnLeveragedLiquidityPositions - 3%;
    *         LiquidationFee - 5%;
    *         TargetInsuranceFundAllocation - 50,000,000 TGEN;
    *         UBEKeeperReward - 0.1%;
    */
    constructor() public Ownable() {}

    /* ========== VIEWS ========== */

    /**
    * @dev Given the index in the array of available currencies, returns the currency key at that index
    * @param index Index in the array of available currencies
    * @return address Currency key at given index
    */
    function getCurrencyKeyFromIndex(uint index) public view override returns (address) {
        return (index > 0 && index <= availableCurrencies.length) ? availableCurrencies[index - 1] : address(0);
    }

    /**
    * @dev Given the symbol of a currency, returns the address of the currency
    * @param symbol The symbol of the currency
    * @return address Currency key for given symbol
    */
    function getCurrencyKeyFromSymbol(string memory symbol) public view override returns (address) {
        return currencySymbolToAddress[symbol];
    }

    /**
    * @dev Given the name of a parameter, returns the value of the parameter
    * @param parameter The name of the parameter to get value for
    * @return uint The value of the given parameter
    */
    function getParameterValue(string memory parameter) public view override returns(uint) {
        return parameters[parameter];
    }

    /**
    * @dev Returns the addresses of supported currencies for trading
    * @return address[] An array of addresses of supported currencies
    */
    function getAvailableCurrencies() external view override returns (address[] memory) {
        return availableCurrencies;
    }

    /**
    * @dev Given the address of a currency, returns the currency's symbol
    * @param currencyKey The address of the currency
    * @return string The currency symbol
    */
    function getCurrencySymbol(address currencyKey) external view override isValidAddress(currencyKey) returns(string memory) {
        require(currencyKeyToIndex[currencyKey] > 0, "Currency not supported");

        return currencyKeyToSymbol[currencyKey];
    }

    /**
    * @dev Returns the address of the stable coin
    * @return address The stable coin address
    */
    function getStableCoinAddress() public view override returns(address) {
        return cUSDAddress;
    }

    /**
    * @dev Returns the addresses and names of supported oracle APIs
    * @return OracleData[] An array of oracle API addresses and names
    */
    function getOracleAPIs() public view override returns (address[] memory) {
        return oracleAPIAddresses;
    }

    /**
    * @dev Given the address of an oracle API, returns the name of the oracle API
    * @param oracleAddress The address of the oracle API
    * @return string The oracle API name
    */
    function getOracleAPIName(address oracleAddress) external view override isValidAddress(oracleAddress) returns(string memory) {
        require(isValidOracleAPIAddress[oracleAddress] > 0, "Oracle API supported");

        return oracleAddressToName[oracleAddress];
    }

    /**
    * @dev Given the address of a currency, returns whether the currency is supported on the platform
    * @param currencyKey The address of the currency
    * @return bool Whether the currency is supported on the platform
    */
    function checkIfCurrencyIsAvailable(address currencyKey) external view override isValidAddress(currencyKey) returns (bool) {
        return (currencyKeyToIndex[currencyKey] > 0);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
    * @dev Updates the address for the given contract; meant to be called by Settings contract owner
    * @param parameter The name of the parameter to change
    * @param newValue The new value of the given parameter
    */
    function setParameterValue(string memory parameter, uint newValue) external override onlyOwner {
        require(newValue > 0, "Value cannot be negative");

        uint oldValue = parameters[parameter];
        parameters[parameter] = newValue;

        emit SetParameterValue(parameter, oldValue, newValue, block.timestamp);
    }

    /**
    * @dev Sets the address of the stable coin
    * @param stableCoinAddress The address of the stable coin
    */
    function setStableCoinAddress(address stableCoinAddress) external override onlyOwner isValidAddress(stableCoinAddress) {
        address oldAddress = cUSDAddress;
        cUSDAddress = stableCoinAddress;

        emit UpdatedStableCoinAddress(oldAddress, stableCoinAddress, block.timestamp);
    }

    /**
    * @dev Updates the address of the given currency
    * @param currencySymbol The currency symbol
    * @param newCurrencyKey The new address for the given currency
    */
    function updateCurrencyKey(string memory currencySymbol, address newCurrencyKey) external override onlyOwner isValidAddress(newCurrencyKey) {
        require(newCurrencyKey != cUSDAddress, "New currency key cannot equal stable token address");
        require(currencyKeyToIndex[newCurrencyKey] == 0, "New currency key already exists");
        require(currencySymbolToAddress[currencySymbol] != address(0), "Currency symbol not found");

        address oldCurrencyKey = currencySymbolToAddress[currencySymbol];
        uint oldCurrencyKeyIndex = currencyKeyToIndex[oldCurrencyKey];

        availableCurrencies[oldCurrencyKeyIndex - 1] = newCurrencyKey;
        currencyKeyToIndex[newCurrencyKey] = oldCurrencyKeyIndex;
        currencySymbolToAddress[currencySymbol] = newCurrencyKey;
        currencyKeyToSymbol[newCurrencyKey] = currencySymbol;

        delete currencyKeyToIndex[oldCurrencyKey];
        delete currencyKeyToSymbol[oldCurrencyKey];

        emit UpdatedCurrencyKey(currencySymbol, oldCurrencyKey, newCurrencyKey, block.timestamp);
    }

    /**
    * @dev Adds a new tradable currency to the platform
    * @param currencySymbol The symbol of the currency to add
    * @param currencyKey The address of the currency to add
    */
    function addCurrencyKey(string memory currencySymbol, address currencyKey) external override onlyOwner isValidAddress(currencyKey) {
        require(currencyKey != cUSDAddress, "Cannot equal stable token address");
        require(currencyKeyToIndex[currencyKey] == 0, "Currency key already exists");
        require(currencySymbolToAddress[currencySymbol] == address(0), "Currency symbol already exists");

        availableCurrencies.push(currencyKey);
        currencyKeyToIndex[currencyKey] = availableCurrencies.length;
        currencySymbolToAddress[currencySymbol] = currencyKey;
        currencyKeyToSymbol[currencyKey] = currencySymbol;

        emit AddedCurrencyKey(currencyKey, block.timestamp);
    }

    /**
    * @dev Updates the address of a given oracle API
    * @param oldOracleAddress The address of the oracle API to update
    * @param newOracleAddress The new address of the given oracle API
    */
    function updateOracleAPIAddress(address oldOracleAddress, address newOracleAddress) external override onlyOwner isValidAddress(oldOracleAddress) isValidAddress(newOracleAddress) {
        require(isValidOracleAPIAddress[oldOracleAddress] > 0, "Old oracle address doesn't exist");
        require(isValidOracleAPIAddress[newOracleAddress] == 0, "New oracle address already exists");

        uint oldOracleAddressIndex = isValidOracleAPIAddress[oldOracleAddress];

        oracleAPIAddresses[oldOracleAddressIndex - 1] = newOracleAddress;
        isValidOracleAPIAddress[newOracleAddress] = oldOracleAddressIndex;
        oracleAddressToName[newOracleAddress] = oracleAddressToName[oldOracleAddress];

        delete isValidOracleAPIAddress[oldOracleAddress];
        delete oracleAddressToName[oldOracleAddress];

        emit UpdatedOracleAPIAddress(oracleAddressToName[newOracleAddress], oldOracleAddress, newOracleAddress, block.timestamp);
    }

    /**
    * @dev Adds a new oracle API to the platform
    * @param name The name of the oracle API
    * @param oracleAddress The address of the oracle API
    */
    function addOracleAPIAddress(string memory name, address oracleAddress) external override onlyOwner isValidAddress(oracleAddress) {
        require(isValidOracleAPIAddress[oracleAddress] == 0, "Oracle address already exists");

        oracleAPIAddresses.push(oracleAddress);
        isValidOracleAPIAddress[oracleAddress] = oracleAPIAddresses.length;
        oracleAddressToName[oracleAddress] = name;

        emit AddedOracleAPIAddress(oracleAddress, block.timestamp);
    }

    /* ========== MODIFIERS ========== */

    modifier isValidAddress(address addressToCheck) {
        require(addressToCheck != address(0), "Address is not valid");
        _;
    }

    /* ========== EVENTS ========== */

    event AddedCurrencyKey(address currencyKey, uint timestamp);
    event AddedOracleAPIAddress(address oracleAddress, uint timestamp);
    event SetParameterValue(string parameter,uint oldValue, uint newValue, uint timestamp);
    event UpdatedStableCoinAddress(address oldAddress, address stableCurrencyAddress, uint timestamp);
    event UpdatedCurrencyKey(string currencySymbol, address oldCurrencyKey, address newCurrencyKey, uint timestamp); 
    event UpdatedOracleAPIAddress(string oracleName, address oldOracleAddress, address newOracleAddress, uint timestamp);
}