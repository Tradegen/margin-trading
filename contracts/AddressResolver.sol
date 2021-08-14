pragma solidity >=0.5.0;

//Interfaces
import './interfaces/IAddressResolver.sol';

//Inheritance
import './Ownable.sol';

contract AddressResolver is IAddressResolver, Ownable {

    mapping (address => address) public _tradingBotAddresses;
    mapping (address => address) public _strategyAddresses;
    mapping (address => address) public _poolAddresses;

    mapping (string => address) public contractAddresses;

    constructor() public Ownable() {}

    /* ========== VIEWS ========== */

    /**
    * @dev Given a contract name, returns the address of the contract
    * @param contractName The name of the contract
    * @return address The address associated with the given contract name
    */
    function getContractAddress(string memory contractName) public view override returns(address) {
        require (contractAddresses[contractName] != address(0), "AddressResolver: contract not found");
        
        return contractAddresses[contractName];
    }

    /**
    * @dev Given an address, returns whether the address belongs to a trading bot
    * @param tradingBotAddress The address to validate
    * @return bool Whether the given address is a valid trading bot address
    */
    function checkIfTradingBotAddressIsValid(address tradingBotAddress) public view override returns(bool) {
        return (tradingBotAddress != address(0)) ? (_tradingBotAddresses[tradingBotAddress] == tradingBotAddress) : false;
    }

    /**
    * @dev Given an address, returns whether the address belongs to a strategy
    * @param strategyAddress The address to validate
    * @return bool Whether the given address is a valid strategy address
    */
    function checkIfStrategyAddressIsValid(address strategyAddress) public view override returns(bool) {
        return (strategyAddress != address(0)) ? (_strategyAddresses[strategyAddress] == strategyAddress) : false;
    }

    /**
    * @dev Given an address, returns whether the address belongs to a user pool
    * @param poolAddress The address to validate
    * @return bool Whether the given address is a valid user pool address
    */
    function checkIfPoolAddressIsValid(address poolAddress) public view override returns(bool) {
        return (poolAddress != address(0)) ? (_poolAddresses[poolAddress] == poolAddress) : false;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
    * @dev Updates the address for the given contract; meant to be called by AddressResolver owner
    * @param contractName The name of the contract
    * @param newAddress The new address for the given contract
    */
    function setContractAddress(string memory contractName, address newAddress) external override onlyOwner isValidAddress(newAddress) {
        address oldAddress = contractAddresses[contractName];
        contractAddresses[contractName] = newAddress;

        emit UpdatedContractAddress(contractName, oldAddress, newAddress, block.timestamp);
    }

    /**
    * @dev Adds a new trading bot address; meant to be called by the Strategy contract that owns the trading bot
    * @param tradingBotAddress The address of the trading bot
    */
    function addTradingBotAddress(address tradingBotAddress) external override onlyStrategy isValidAddress(tradingBotAddress) {
        require(_tradingBotAddresses[tradingBotAddress] != tradingBotAddress, "Trading bot already exists");

        _tradingBotAddresses[tradingBotAddress] = tradingBotAddress;
    }

    /**
    * @dev Adds a new strategy address; meant to be called by the StrategyManager contract
    * @param strategyAddress The address of the strategy
    */
    function addStrategyAddress(address strategyAddress) external override onlyStrategyManager isValidAddress(strategyAddress) {
        require(_strategyAddresses[strategyAddress] != strategyAddress, "Strategy already exists");

        _strategyAddresses[strategyAddress] = strategyAddress;
    }

    /**
    * @dev Adds a new user pool address; meant to be called by the PoolManager contract
    * @param poolAddress The address of the user pool
    */
    function addPoolAddress(address poolAddress) external override onlyPoolFactory isValidAddress(poolAddress) {
        require(_poolAddresses[poolAddress] != poolAddress, "Pool already exists");

        _poolAddresses[poolAddress] = poolAddress;
    }

    /* ========== MODIFIERS ========== */

    modifier isValidAddress(address addressToCheck) {
        require(addressToCheck != address(0), "Address is not valid");
        _;
    }

    modifier validAddressForTransfer(address addressToCheck) {
        require(addressToCheck == contractAddresses["StakingRewards"] || addressToCheck == contractAddresses["StrategyProxy"] || addressToCheck == contractAddresses["StrategyApproval"] || addressToCheck == contractAddresses["Components"], "Address is not valid");
        _;
    }

    modifier onlyStrategy() {
        require(msg.sender == _strategyAddresses[msg.sender], "AddressResolver: Only the Strategy contract can call this function");
        _;
    }

    modifier onlyStrategyManager() {
        require(msg.sender == contractAddresses["StrategyManager"], "AddressResolver: Only the StrategyManager contract can call this function");
        _;
    }

    modifier onlyPoolFactory() {
        require(msg.sender == contractAddresses["PoolFactory"], "AddressResolver: Only the PoolFactory contract can call this function");
        _;
    }

    /* ========== EVENTS ========== */

    event UpdatedContractAddress(string contractName, address oldAddress, address newAddress, uint timestamp);
    event AddedTradingBotAddress(address tradingBotAddress, uint timestamp);
    event AddedStrategyAddress(address strategyAddress, uint timestamp);
    event AddedPoolAddress(address poolAddress, uint timestamp);
}