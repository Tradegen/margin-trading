pragma solidity >=0.5.0;

//Adapters
import './interfaces/IBaseUbeswapAdapter.sol';

//Interfaces
import './interfaces/IERC20.sol';
import './interfaces/IPool.sol';
import './interfaces/ISettings.sol';
import './interfaces/IAddressResolver.sol';
import './interfaces/IFeePool.sol';
import './interfaces/IStakingRewards.sol';
import './interfaces/ILeveragedLiquidityPositionManager.sol';
import './interfaces/ILeveragedAssetPositionManager.sol';

//Libraries
import './libraries/SafeMath.sol';

contract Pool is IPool, IERC20 {
    using SafeMath for uint;

    IAddressResolver public ADDRESS_RESOLVER;

    struct LiquidityPair {
        address tokenA;
        address tokenB;
        address farmAddress;
        uint numberOfLPTokens;
    }
   
    string public _name;
    uint public _totalSupply;
    address public _manager;
    uint public _performanceFee; //expressed as %
    address public _farmAddress;
    uint public _totalDeposits;

    mapping (address => uint) public _balanceOf;
    mapping (address => uint) public _deposits;
    mapping (address => mapping(address => uint)) public override allowance;

    //Asset positions
    mapping (uint => address) public _positionKeys;
    uint public numberOfPositions;
    mapping (address => uint) public positionToIndex; //maps to (index + 1), with index 0 representing position not found

    //Liquidity positions
    mapping (uint => LiquidityPair) public liquidityPositions;
    uint public numberOfLiquidityPositions;
    mapping (address => mapping(address => uint)) public liquidityPairToIndex; //maps to (index + 1), with index 0 representing position not found

    uint public totalNumberOfPositions;

    constructor(string memory name, uint performanceFee, address manager, IAddressResolver addressResolver) public {
        _name = name;
        _manager = manager;
        _performanceFee = performanceFee;
        ADDRESS_RESOLVER = addressResolver;
    }

    /* ========== VIEWS ========== */

    /**
    * @dev Returns the name of the pool
    * @return string The name of the pool
    */
    function name() public view override(IPool, IERC20) returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return "";
    }

    function decimals() public view override returns (uint8) {
        return 18;
    }

    /**
    * @dev Returns the address of the pool's farm
    * @return address Address of the pool's farm
    */
    function getFarmAddress() public view override returns (address) {
        return _farmAddress;
    }

    /**
    * @dev Return the pool manager's address
    * @return address Address of the pool's manager
    */
    function getManagerAddress() public view override returns (address) {
        return _manager;
    }

    /**
    * @dev Returns the currency address and balance of each position the pool has, as well as the cumulative value
    * @return (address[], uint[], uint) Currency address and balance of each position the pool has, and the cumulative value of positions
    */
    function getPositionsAndTotal() public view override returns (address[] memory, uint[] memory, uint) {
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        address leveragedAssetPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager");
        address[] memory addresses = new address[](numberOfPositions);
        uint[] memory balances = new uint[](numberOfPositions);
        uint sum;

        //Calculate USD value of each asset position
        for (uint i = 0; i < numberOfPositions; i++)
        {
            balances[i] = IERC20(_positionKeys[i]).balanceOf(address(this));
            addresses[i] = _positionKeys[i];

            uint numberOfDecimals = IERC20(_positionKeys[i]).decimals();
            uint USDperToken = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(_positionKeys[i]);
            uint positionBalanceInUSD = balances[i].mul(USDperToken).div(10 ** numberOfDecimals);
            sum = sum.add(positionBalanceInUSD);
        }

        //Calculate USD value of each liquidity position
        for (uint i = 0; i < numberOfLiquidityPositions; i++)
        {
            LiquidityPair memory pair = liquidityPositions[i];
            sum = sum.add(_calculateValueOfLPTokens(pair.tokenA, pair.tokenB, pair.numberOfLPTokens));
        }

        //Calculate USD value of each leveraged asset position
        uint[] memory leveragedAssetPositions = ILeveragedAssetPositionManager(leveragedAssetPositionManagerAddress).getUserPositions(address(this));
        for (uint i = 0; i < leveragedAssetPositions.length; i++)
        {
            sum = sum.add(ILeveragedAssetPositionManager(leveragedAssetPositionManagerAddress).getPositionValue(leveragedAssetPositions[i]));
        }

        //Calculate USD value of each leveraged liquidity position
        uint[] memory leveragedLiquidityPositions = ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).getUserPositions(address(this));
        for (uint i = 0; i < leveragedLiquidityPositions.length; i++)
        {
            sum = sum.add(ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).getPositionValue(leveragedLiquidityPositions[i]));
        }

        return (addresses, balances, sum);
    }

    /**
    * @dev Returns the amount of cUSD the pool has to invest
    * @return uint Amount of cUSD the pool has available
    */
    function getAvailableFunds() public view override returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        return IERC20(stableCoinAddress).balanceOf(address(this));
    }

    /**
    * @dev Returns the value of the pool in USD
    * @return uint Value of the pool in USD
    */
    function getPoolBalance() public view override returns (uint) {
        (,, uint positionBalance) = getPositionsAndTotal();
        
        return positionBalance;
    }

    /**
    * @dev Returns the balance of the user in USD
    * @return uint Balance of the user in USD
    */
    function getUSDBalance(address user) public view override returns (uint) {
        require(user != address(0), "Invalid address");

        uint poolBalance = getPoolBalance();

        return poolBalance.mul(_balanceOf[user]).div(_totalSupply);
    }

    /**
    * @dev Returns the number of LP tokens the user has
    * @param user Address of the user
    * @return uint Number of LP tokens the user has
    */
    function balanceOf(address user) public view override(IPool, IERC20) returns (uint) {
        require(user != address(0), "Invalid user address");

        return _balanceOf[user];
    }

    /**
    * @dev Returns the total supply of LP tokens in the pool
    * @return uint Total supply of LP tokens
    */
    function totalSupply() public view override returns (uint) {
        return _totalSupply;
    }

    /**
    * @dev Returns the pool's performance fee
    * @return uint The pool's performance fee
    */
    function getPerformanceFee() public view override returns (uint) {
        return _performanceFee;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function approve(address spender, uint value) public override returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint value) public override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) public override returns (bool) {
        if (allowance[from][msg.sender] > 0) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
    * @dev Deposits the given USD amount into the pool
    * @notice Call cUSD.approve() before calling this function
    * @param amount Amount of USD to deposit into the pool
    */
    function deposit(uint amount) public override {
        require(amount > 0, "Pool: Deposit must be greater than 0");

        uint poolBalance = getPoolBalance();
        uint numberOfLPTokens = (_totalSupply > 0) ? _totalSupply.mul(amount).div(poolBalance) : amount;
        _deposits[msg.sender] = _deposits[msg.sender].add(amount);
        _totalDeposits = _totalDeposits.add(amount);
        _balanceOf[msg.sender] = _balanceOf[msg.sender].add(numberOfLPTokens);
        _totalSupply = _totalSupply.add(numberOfLPTokens);

        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        IERC20(stableCoinAddress).transferFrom(msg.sender, address(this), amount);

        //Add cUSD to position keys if it's not there already
        _addPositionKey(stableCoinAddress);

        emit Deposit(address(this), msg.sender, amount, block.timestamp);
    }

    /**
    * @dev Withdraws the given USD amount on behalf of the user
    * @notice The withdrawal is done using pool's assets at time of withdrawal. This avoids the exchange fees and slippage from exchanging pool's assets back to cUSD or TGEN.
    * @param amount Amount of USD to withdraw from the pool
    */
    function withdraw(uint amount) public override {
        require(amount > 0, "Pool: Withdrawal must be greater than 0");

        uint poolBalance = getPoolBalance();
        uint USDBalance = poolBalance.mul(_balanceOf[msg.sender]).div(_totalSupply);

        require(USDBalance >= amount, "Pool: Not enough funds to withdraw");

        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        address leveragedAssetPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager");

        //Transfer leveraged positions
        ILeveragedAssetPositionManager(leveragedAssetPositionManagerAddress).bulkTransferTokens(msg.sender, amount, poolBalance);
        ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).bulkTransferTokens(msg.sender, amount, poolBalance);

        //Reduce liquidity positions
        for (uint i = 0; i < numberOfLiquidityPositions; i++)
        {
            LiquidityPair memory liquidityPosition = liquidityPositions[i];

            removeLiquidity(liquidityPosition.tokenA, liquidityPosition.tokenB, liquidityPosition.farmAddress, liquidityPosition.numberOfLPTokens.mul(amount).div(poolBalance));
        }

        uint profit = (USDBalance > _deposits[msg.sender]) ? USDBalance.sub(_deposits[msg.sender]) : 0;
        uint fee = profit.mul(amount).div(USDBalance); //Multiply by ratio of withdrawal amount to user's USD balance
        fee = fee.mul(_performanceFee).div(100);

        //Update state variables
        uint depositAmount = _deposits[msg.sender].mul(amount).div(USDBalance);
        uint numberOfLPTokens = _balanceOf[msg.sender].mul(amount).div(USDBalance);
        _balanceOf[msg.sender] = _balanceOf[msg.sender].sub(numberOfLPTokens);
        _totalSupply = _totalSupply.sub(numberOfLPTokens);
        _deposits[msg.sender] = _deposits[msg.sender].sub(depositAmount);
        _totalDeposits = _totalDeposits.sub(depositAmount);

        //Withdraw user's portion of pool's assets
        for (uint i = 0; i < numberOfPositions; i++)
        {
            uint positionBalance = IERC20(_positionKeys[i]).balanceOf(address(this)); //Number of asset's tokens
            uint amountToTransferToUser = positionBalance.mul(amount.sub(fee)).div(poolBalance); //Multiply by ratio of withdrawal amount after fee to pool's USD balance
            uint amountToTransferToManager = positionBalance.mul(fee).div(poolBalance);

            IERC20(_positionKeys[i]).transfer(msg.sender, amountToTransferToUser);
            IERC20(_positionKeys[i]).transfer(_manager, amountToTransferToManager);

            //Remove position keys if pool is liquidated
            if (_totalSupply == 0)
            {
                _removePositionKey(_positionKeys[i]);
            }
        }

        //Set numberOfPositions to 0 if pool is liquidated
        if (_totalSupply == 0)
        {
            numberOfPositions = 0;
        }

        emit Withdraw(address(this), msg.sender, amount, block.timestamp);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
    * @dev Places an order to buy/sell the given currency
    * @param currencyKey Address of currency to trade
    * @param buyOrSell Whether the user is buying or selling
    * @param numberOfTokens Number of tokens of the given currency
    */
    function placeOrder(address currencyKey, bool buyOrSell, uint numberOfTokens) public override onlyPoolManager {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        require(numberOfTokens > 0, "Pool: Number of tokens must be greater than 0");
        require(currencyKey != address(0), "Pool: Invalid currency key");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(currencyKey), "Pool: Currency key is not available");

        uint numberOfDecimals = IERC20(currencyKey).decimals();
        uint tokenToUSD = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(currencyKey);
        uint numberOfTokensReceived;
        uint amountInUSD = numberOfTokens.mul(tokenToUSD).div(10 ** numberOfDecimals);

        //buying
        if (buyOrSell)
        {
            require(getAvailableFunds() >= amountInUSD, "Pool: Not enough funds");

            //Add to position keys if no position yet
            _addPositionKey(currencyKey);

            require(totalNumberOfPositions <= ISettings(settingsAddress).getParameterValue("MaximumNumberOfPositionsInPool"), "Pool: cannot exceed maximum number of positions");

            IERC20(stableCoinAddress).transfer(baseUbeswapAdapterAddress, amountInUSD);
            numberOfTokensReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromPool(stableCoinAddress, currencyKey, amountInUSD, numberOfTokens);
        }
        //selling
        else
        {
            uint positionIndex = positionToIndex[currencyKey];

            require(positionIndex > 0, "Pool: Don't have a position in this currency");
            require(IERC20(currencyKey).balanceOf(address(this)) >= numberOfTokens, "Pool: Not enough tokens in this currency");

            IERC20(currencyKey).transfer(baseUbeswapAdapterAddress, numberOfTokens);
            numberOfTokensReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromPool(currencyKey, stableCoinAddress, numberOfTokens, amountInUSD);

            //remove position key if no funds left in currency
            _removePositionKey(currencyKey);
        }

        emit PlacedOrder(address(this), currencyKey, buyOrSell, numberOfTokens, block.timestamp);
    }

    /**
    * @dev Adds liquidity for the two given tokens
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param amountA Amount of first token
    * @param amountB Amount of second token
    * @param farmAddress The token pair's farm address
    */
    function addLiquidity(address tokenA, address tokenB, uint amountA, uint amountB, address farmAddress) public override onlyPoolManager {
        require(tokenA != address(0), "Pool: invalid address for tokenA");
        require(tokenB != address(0), "Pool: invalid address for tokenB");
        require(amountA > 0, "Pool: amountA must be greater than 0");
        require(amountB > 0, "Pool: amountB must be greater than 0");
        require(IERC20(tokenA).balanceOf(address(this)) >= amountA, "Pool: not enough tokens invested in tokenA");
        require(IERC20(tokenB).balanceOf(address(this)) >= amountB, "Pool: not enough tokens invested in tokenB");

        //Check if farm exists for the token pair
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stakingTokenAddress = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress);
        address pairAddress = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPair(tokenA, tokenB);

        require(stakingTokenAddress == pairAddress, "Pool: stakingTokenAddress does not match pairAddress");

        //Add liquidity to Ubeswap pool and stake LP tokens into associated farm
        uint numberOfLPTokens = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).addLiquidity(tokenA, tokenB, amountA, amountB);
        IStakingRewards(stakingTokenAddress).stake(numberOfLPTokens);

        //Update liquidity positions
        (address token0, address token1) = (tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        if (liquidityPairToIndex[token0][token1] == 0)
        {
            liquidityPositions[numberOfLiquidityPositions] = LiquidityPair(token0, token1, farmAddress, numberOfLPTokens);
            liquidityPairToIndex[token0][token1] = numberOfLiquidityPositions;
            numberOfLiquidityPositions = numberOfLiquidityPositions.add(1);
        }
        else
        {
            uint index = liquidityPairToIndex[token0][token1];
            liquidityPositions[index].numberOfLPTokens = liquidityPositions[index].numberOfLPTokens.add(numberOfLPTokens);
        }

        //Update position keys
        _removePositionKey(tokenA);
        _removePositionKey(tokenB);

        emit AddedLiquidity(address(this), tokenA, tokenB, amountA, amountB, numberOfLPTokens, block.timestamp);
    }

    /**
    * @dev Removes liquidity for the two given tokens
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param farmAddress The token pair's farm address
    * @param numberOfLPTokens Number of LP tokens to remove from the farm
    */
    function removeLiquidity(address tokenA, address tokenB, address farmAddress, uint numberOfLPTokens) public override onlyPoolManager {
        require(tokenA != address(0), "Pool: invalid address for tokenA");
        require(tokenB != address(0), "Pool: invalid address for tokenB");

        //Check if pool has enough LP tokens in the farm
        (address token0, address token1) = (tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        uint index = liquidityPairToIndex[token0][token1];
        require(liquidityPositions[index].numberOfLPTokens >= numberOfLPTokens, "Pool: not enough LP tokens to unstake");

        //Check if farmAddress is valid
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        require(IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress) != address(0), "Invalid farm address");

        //Withdraw all LP tokens from the farm and claim available UBE rewards
        //Need to restake remaining LP tokens later
        IStakingRewards(farmAddress).exit();

        //Check for UBE balance and update position keys if UBE not currently in postion keys
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address UBE = ISettings(settingsAddress).getCurrencyKeyFromSymbol("UBE");
        _addPositionKey(UBE);

        //Remove liquidity from Ubeswap liquidity pool
        (uint amountA, uint amountB) = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).removeLiquidity(tokenA, tokenB, numberOfLPTokens);

        //Update position keys
        _addPositionKey(tokenA);
        _addPositionKey(tokenB);

        require(totalNumberOfPositions <= ISettings(settingsAddress).getParameterValue("MaximumNumberOfPositionsInPool"), "Pool: cannot exceed maximum number of positions");

        //Update liquidity positions
        liquidityPositions[index].numberOfLPTokens = liquidityPositions[index].numberOfLPTokens.sub(numberOfLPTokens);

        //Restake remaining LP tokens
        IStakingRewards(farmAddress).stake(liquidityPositions[index].numberOfLPTokens);

        emit RemovedLiquidity(address(this), tokenA, tokenB, numberOfLPTokens, amountA, amountB, block.timestamp);
    }

    /**
    * @dev Collects available UBE rewards for the given Ubeswap farm
    * @param farmAddress The token pair's farm address
    */
    function claimUbeswapRewards(address farmAddress) public override onlyPoolManager {
        //Check if farmAddress is valid
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        require(IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress) != address(0), "Invalid farm address");

        //Check if pool has tokens staked in farm
        require(IStakingRewards(farmAddress).balanceOf(address(this)) > 0, "Pool: no tokens staked in farm");

        //Claim available UBE rewards
        IStakingRewards(farmAddress).getReward();

        //Check for UBE balance and update position keys if UBE not currently in postion keys
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address UBE = ISettings(settingsAddress).getCurrencyKeyFromSymbol("UBE");
        _addPositionKey(UBE);

        require(totalNumberOfPositions <= ISettings(settingsAddress).getParameterValue("MaximumNumberOfPositionsInPool"), "Pool: cannot exceed maximum number of positions");

        emit ClaimedUbeswapRewards(address(this), farmAddress, block.timestamp);
    }

    /**
    * @dev Opens a new leveraged asset position; swaps cUSD for specified asset
    * @notice LeveragedAssetPositionManager checks if currency is supported
    * @param underlyingAsset Address of the leveraged asset
    * @param collateral Amount of cUSD to use as collateral
    * @param amountToBorrow Amount of cUSD to borrow
    */
    function openLeveragedAssetPosition(address underlyingAsset, uint collateral, uint amountToBorrow) public override onlyPoolManager {
        require(getAvailableFunds() >= collateral, "Pool: not enough funds");
        require(underlyingAsset != address(0), "Pool: invalid asset address");

        address leveragedAssetPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager");
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        IERC20(stableCoinAddress).approve(stableCoinStakingRewardsAddress, collateral);
        ILeveragedAssetPositionManager(leveragedAssetPositionManagerAddress).openPosition(underlyingAsset, collateral, amountToBorrow);

        totalNumberOfPositions = totalNumberOfPositions.add(1);
        require(totalNumberOfPositions <= ISettings(settingsAddress).getParameterValue("MaximumNumberOfPositionsInPool"), "Pool: cannot exceed maximum number of positions");

        emit OpenedLeveragedAssetPosition(address(this), underlyingAsset, collateral, amountToBorrow, block.timestamp);
    }

    /**
    * @dev Reduces the size of a leveraged asset position
    * @notice LeveragedAssetPositionManager checks if pool is owner of position at given index
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of tokens to sell
    */
    function reduceLeveragedAssetPosition(uint positionIndex, uint numberOfTokens) public override onlyPoolManager {
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");
        require(numberOfTokens > 0, "Pool: numberOfTokens must be greater than 0");

        address leveragedAssetPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager");
        ILeveragedAssetPositionManager(leveragedAssetPositionManagerAddress).reducePosition(positionIndex, numberOfTokens);

        emit ReducedLeveragedAssetPosition(address(this), positionIndex, numberOfTokens, block.timestamp);
    }

    /**
    * @dev Closes a leveraged asset position
    * @notice LeveragedAssetPositionManager checks if pool is owner of position at given index
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function closeLeveragedAssetPosition(uint positionIndex) public override onlyPoolManager {
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");

        address leveragedAssetPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager");
        ILeveragedAssetPositionManager(leveragedAssetPositionManagerAddress).closePosition(positionIndex);

        totalNumberOfPositions = totalNumberOfPositions.sub(1);

        emit ClosedLeveragedAssetPosition(address(this), positionIndex, block.timestamp);
    }

    /**
    * @dev Adds collateral to the leveraged asset position
    * @notice LeveragedAssetPositionManager checks if pool is owner of position at given index
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param amountOfUSD Amount of cUSD to add as collateral
    */
    function addCollateralToLeveragedAssetPosition(uint positionIndex, uint amountOfUSD) public override onlyPoolManager {
        require(getAvailableFunds() >= amountOfUSD, "Pool: not enough funds");
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");

        address leveragedAssetPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager");
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        IERC20(stableCoinAddress).approve(stableCoinStakingRewardsAddress, amountOfUSD);
        ILeveragedAssetPositionManager(leveragedAssetPositionManagerAddress).addCollateral(positionIndex, amountOfUSD);

        emit AddedCollateralToLeveragedAssetPosition(address(this), positionIndex, amountOfUSD, block.timestamp);
    }

    /**
    * @dev Removes collateral from the leveraged asset position
    * @notice LeveragedAssetPositionManager checks if pool is owner of position at given index
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateralFromLeveragedAssetPosition(uint positionIndex, uint numberOfTokens) public override onlyPoolManager {
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");
        require(numberOfTokens > 0, "Pool: numberOfTokens must be greater than 0");

        address leveragedAssetPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager");
        ILeveragedAssetPositionManager(leveragedAssetPositionManagerAddress).removeCollateral(positionIndex, numberOfTokens);

        emit RemovedCollateralFromLeveragedAssetPosition(address(this), positionIndex, numberOfTokens, block.timestamp);
    }

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
    function openLeveragedLiquidityPosition(address tokenA, address tokenB, uint collateral, uint amountToBorrow, address farmAddress) public override onlyPoolManager {
        require(getAvailableFunds() >= collateral, "Pool: not enough funds");
        require(tokenA != address(0), "Pool: invalid tokenA address");
        require(tokenB != address(0), "Pool: invalid tokenB address");
        require(farmAddress != address(0), "Pool: invalid farm address");

        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        IERC20(stableCoinAddress).approve(stableCoinStakingRewardsAddress, collateral);
        ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).openPosition(tokenA, tokenB, collateral, amountToBorrow, farmAddress);

        totalNumberOfPositions = totalNumberOfPositions.add(1);
        require(totalNumberOfPositions <= ISettings(settingsAddress).getParameterValue("MaximumNumberOfPositionsInPool"), "Pool: cannot exceed maximum number of positions");

        emit OpenedLeveragedLiquidityPosition(address(this), tokenA, tokenB, collateral, amountToBorrow, farmAddress, block.timestamp);
    }

    /**
    * @dev Reduces the size of a leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of tokens to sell
    */
    function reduceLeveragedLiquidityPosition(uint positionIndex, uint numberOfTokens) public override onlyPoolManager {
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");
        require(numberOfTokens > 0, "Pool: numberOfTokens must be greater than 0");

        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).reducePosition(positionIndex, numberOfTokens);

        emit ReducedLeveragedLiquidityPosition(address(this), positionIndex, numberOfTokens, block.timestamp);
    }

    /**
    * @dev Closes a leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function closeLeveragedLiquidityPosition(uint positionIndex) public override onlyPoolManager {
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");

        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).closePosition(positionIndex);

        totalNumberOfPositions = totalNumberOfPositions.sub(1);

        emit ClosedLeveragedLiquidityPosition(address(this), positionIndex, block.timestamp);
    }

    /**
    * @dev Adds collateral to the leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param amountOfUSD Amount of cUSD to add as collateral
    */
    function addCollateralToLeveragedLiquidityPosition(uint positionIndex, uint amountOfUSD) public override onlyPoolManager {
        require(getAvailableFunds() >= amountOfUSD, "Pool: not enough funds");
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");

        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        address stableCoinStakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        IERC20(stableCoinAddress).approve(stableCoinStakingRewardsAddress, amountOfUSD);
        ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).addCollateral(positionIndex, amountOfUSD);

        emit AddedCollateralToLeveragedLiquidityPosition(address(this), positionIndex, amountOfUSD, block.timestamp);
    }

    /**
    * @dev Removes collateral from the leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    * @param numberOfTokens Number of asset tokens to remove as collateral
    */
    function removeCollateralFromLeveragedLiquidityPosition(uint positionIndex, uint numberOfTokens) public override onlyPoolManager {
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");
        require(numberOfTokens > 0, "Pool: numberOfTokens must be greater than 0");

        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).removeCollateral(positionIndex, numberOfTokens);

        emit RemovedCollateralFromLeveragedLiquidityPosition(address(this), positionIndex, numberOfTokens, block.timestamp);
    }

    /**
    * @dev Claims available UBE rewards for the leveraged liquidity position
    * @param positionIndex Index of the leveraged position in array of leveraged positions
    */
    function getReward(uint positionIndex) public override onlyPoolManager {
        require(positionIndex > 0, "Pool: positionIndex must be greater than 0");

        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        ILeveragedLiquidityPositionManager(leveragedLiquidityPositionManagerAddress).getReward(positionIndex);

        //Check for UBE balance and update position keys if UBE not currently in postion keys
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address UBE = ISettings(settingsAddress).getCurrencyKeyFromSymbol("UBE");
        _addPositionKey(UBE);

        require(totalNumberOfPositions <= ISettings(settingsAddress).getParameterValue("MaximumNumberOfPositionsInPool"), "Pool: cannot exceed maximum number of positions");

        emit RewardPaid(address(this), positionIndex, block.timestamp);
    }

    /**
    * @dev Updates the pool's farm address
    * @param farmAddress Address of the pool's farm
    */
    function setFarmAddress(address farmAddress) public override onlyPoolFactory {
        require(farmAddress != address(0), "Invalid farm address");

        _farmAddress = farmAddress;
    }

    /**
    * @dev Decrement's the totalNumberOfPositions
    * @notice Called from liquidate() in LeveragedAssetPositionManager or LeveragedLiquidityPositionManager
    */
    function decrementTotalPositionCount() public override onlyLeveragedPositionManager {
        totalNumberOfPositions = totalNumberOfPositions.sub(1);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
    * @dev Calculates the USD value of a token pair
    * @param tokenA First token in the pair
    * @param tokenB Second token in the pair
    * @param numberOfLPTokens Number of LP tokens in the pair
    */
    function _calculateValueOfLPTokens(address tokenA, address tokenB, uint numberOfLPTokens) internal view returns (uint) {
        require(tokenA != address(0), "Pool: invalid address for tokenA");
        require(tokenB != address(0), "Pool: invalid address for tokenB");
        
        if (numberOfLPTokens == 0)
        {
            return 0;
        }

        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        (uint amountA, uint amountB) = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getTokenAmountsFromPair(tokenA, tokenB, numberOfLPTokens);

        uint numberOfDecimalsA = IERC20(tokenA).decimals();
        uint USDperTokenA = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(tokenA);
        uint USDBalanceA = amountA.mul(USDperTokenA).div(10 ** numberOfDecimalsA);

        uint numberOfDecimalsB = IERC20(tokenB).decimals();
        uint USDperTokenB = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(tokenB);
        uint USDBalanceB = amountB.mul(USDperTokenB).div(10 ** numberOfDecimalsB);

        return USDBalanceA.add(USDBalanceB);
    }

    /**
    * @dev Adds the given currency to position keys
    * @param currency Address of token to add
    */
    function _addPositionKey(address currency) internal {
        require(currency != address(0), "Pool: invalid asset address");

        //Add token to positionKeys if balance > 0 and not currently in positionKeys
        if (IERC20(currency).balanceOf(address(this)) > 0 && positionToIndex[currency] == 0)
        {
            positionToIndex[currency] = numberOfPositions;
            _positionKeys[numberOfPositions] = currency;
            numberOfPositions = numberOfPositions.add(1);
            totalNumberOfPositions = totalNumberOfPositions.add(1);
        }
    }

    /**
    * @dev Removes the given currency to position keys
    * @param currency Address of token to remove
    */
    function _removePositionKey(address currency) internal {
        require(currency != address(0), "Pool: invalid asset address");

        //Remove currency from positionKeys if no balance left
        if (IERC20(currency).balanceOf(address(this)) == 0)
        {
            _positionKeys[positionToIndex[currency]] = _positionKeys[numberOfPositions - 1];
            positionToIndex[_positionKeys[numberOfPositions - 1]] = positionToIndex[currency];
            delete _positionKeys[numberOfPositions - 1];
            delete positionToIndex[currency];
            numberOfPositions = numberOfPositions.sub(1);
            totalNumberOfPositions = totalNumberOfPositions.sub(1);
        }
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        _balanceOf[from] = _balanceOf[from].sub(value);
        _balanceOf[to] = _balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyPoolFactory() {
        address poolFactoryAddress = ADDRESS_RESOLVER.getContractAddress("PoolFactory");

        require(msg.sender == poolFactoryAddress, "Pool: Only PoolFactory contract can call this function");
        _;
    }

    modifier onlyPoolManager() {
        require(msg.sender == _manager, "Pool: Only pool's manager can call this function");
        _;
    }

    modifier onlyLeveragedPositionManager() {
        address leveragedLiquidityPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager");
        address leveragedAssetPositionManagerAddress = ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager");

        require(msg.sender == leveragedLiquidityPositionManagerAddress || msg.sender == leveragedAssetPositionManagerAddress, "Pool: Only a leverage position manager contract can call this function");
        _;
    }

    /* ========== EVENTS ========== */

    event Deposit(address indexed poolAddress, address indexed userAddress, uint amount, uint timestamp);
    event Withdraw(address indexed poolAddress, address indexed userAddress, uint amount, uint timestamp);
    event PlacedOrder(address indexed poolAddress, address indexed currencyKey, bool buyOrSell, uint amount, uint timestamp);
    event AddedLiquidity(address indexed poolAddress, address tokenA, address tokenB, uint amountA, uint amountB, uint numberOfLPTokensReceived, uint timestamp);
    event RemovedLiquidity(address indexed poolAddress, address tokenA, address tokenB, uint numberOfLPTokens, uint amountAReceived, uint amountBReceived, uint timestamp);
    event ClaimedUbeswapRewards(address indexed poolAddress, address farmAddress, uint timestamp);
    //Leveraged asset positions
    event OpenedLeveragedAssetPosition(address indexed poolAddress, address indexed underlyingAsset, uint collateral, uint numberOfTokensBorrowed, uint timestamp);
    event ReducedLeveragedAssetPosition(address indexed poolAddress, uint indexed positionIndex, uint numberOfTokens, uint timestamp);
    event ClosedLeveragedAssetPosition(address indexed poolAddress, uint indexed positionIndex, uint timestamp);
    event AddedCollateralToLeveragedAssetPosition(address indexed poolAddress, uint indexed positionIndex, uint collateralAdded, uint timestamp);
    event RemovedCollateralFromLeveragedAssetPosition(address indexed poolAddress, uint indexed positionIndex, uint collateralRemoved, uint timestamp);
    //Leveraged liquidity positions
    event OpenedLeveragedLiquidityPosition(address indexed poolAddress, address tokenA, address tokenB, uint collateral, uint numberOfTokensBorrowed, address farmAddress, uint timestamp);
    event ReducedLeveragedLiquidityPosition(address indexed poolAddress, uint indexed positionIndex, uint numberOfTokens, uint timestamp);
    event ClosedLeveragedLiquidityPosition(address indexed poolAddress, uint indexed positionIndex, uint timestamp);
    event AddedCollateralToLeveragedLiquidityPosition(address indexed poolAddress, uint indexed positionIndex, uint collateralAdded, uint timestamp);
    event RemovedCollateralFromLeveragedLiquidityPosition(address indexed poolAddress, uint indexed positionIndex, uint collateralRemoved, uint timestamp);
    event RewardPaid(address indexed poolAddress, uint positionIndex, uint timestamp);
}