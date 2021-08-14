pragma solidity >=0.5.0;

//Interfaces
import './interfaces/IUniswapV2Router02.sol';
import './interfaces/IERC20.sol';
import './interfaces/ISettings.sol';
import './interfaces/IAddressResolver.sol';
import './interfaces/IUbeswapPoolManager.sol';
import './interfaces/IStakingRewards.sol';
import './interfaces/IUniswapV2Factory.sol';

//Inheritance
import './interfaces/IBaseUbeswapAdapter.sol';

//Libraries
import './libraries/SafeMath.sol';

contract BaseUbeswapAdapter is IBaseUbeswapAdapter {
    using SafeMath for uint;

    struct PoolInfo {
        uint256 index;
        address stakingToken;
        address poolAddress;
        uint256 weight;
        // The next period in which the pool needs to be filled
        uint256 nextPeriod;
    }

    // Max slippage percent allowed
    uint public constant override MAX_SLIPPAGE_PERCENT = 10; //10% slippage

    IAddressResolver public immutable ADDRESS_RESOLVER;

    constructor(IAddressResolver addressResolver) public {
        ADDRESS_RESOLVER = addressResolver;
    }

    /* ========== VIEWS ========== */

    /**
    * @dev Given an input asset address, returns the price of the asset in cUSD
    * @param currencyKey Address of the asset
    * @return uint Price of the asset
    */
    function getPrice(address currencyKey) public view override returns(uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address ubeswapRouterAddress = ADDRESS_RESOLVER.getContractAddress("UbeswapRouter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        //Check if currency key is cUSD
        if (currencyKey == stableCoinAddress)
        {
            return 10 ** _getDecimals(currencyKey);
        }

        require(currencyKey != address(0), "Invalid currency key");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(currencyKey), "Currency is not available");

        address[] memory path = new address[](2);
        path[0] = currencyKey;
        path[1] = stableCoinAddress;

        uint[] memory amounts = IUniswapV2Router02(ubeswapRouterAddress).getAmountsOut(10 ** _getDecimals(currencyKey), path); // 1 token -> cUSD

        return amounts[1];
    }

    /**
    * @dev Given an input asset amount, returns the maximum output amount of the other asset
    * @notice Assumes numberOfTokens is multiplied by currency's decimals before function call
    * @param numberOfTokens Number of tokens
    * @param currencyKeyIn Address of the asset to be swap from
    * @param currencyKeyOut Address of the asset to be swap to
    * @return uint Amount out of the asset
    */
    function getAmountsOut(uint numberOfTokens, address currencyKeyIn, address currencyKeyOut) public view override returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address ubeswapRouterAddress = ADDRESS_RESOLVER.getContractAddress("UbeswapRouter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        require(currencyKeyIn != address(0), "Invalid currency key in");
        require(currencyKeyOut != address(0), "Invalid currency key out");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(currencyKeyIn) || currencyKeyIn == stableCoinAddress, "Currency is not available");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(currencyKeyOut) || currencyKeyOut == stableCoinAddress, "Currency is not available");
        require(numberOfTokens > 0, "Number of tokens must be greater than 0");

        address[] memory path = new address[](2);
        path[0] = currencyKeyIn;
        path[1] = currencyKeyOut;
        uint[] memory amounts = IUniswapV2Router02(ubeswapRouterAddress).getAmountsOut(numberOfTokens, path);

        return amounts[1];
    }

    /**
    * @dev Given the target output asset amount, returns the amount of input asset needed
    * @param numberOfTokens Target amount of output asset
    * @param currencyKeyIn Address of the asset to be swap from
    * @param currencyKeyOut Address of the asset to be swap to
    * @return uint Amount out input asset needed
    */
    function getAmountsIn(uint numberOfTokens, address currencyKeyIn, address currencyKeyOut) public view override returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address ubeswapRouterAddress = ADDRESS_RESOLVER.getContractAddress("UbeswapRouter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        require(currencyKeyIn != address(0), "Invalid currency key in");
        require(currencyKeyOut != address(0), "Invalid currency key out");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(currencyKeyIn) || currencyKeyIn == stableCoinAddress, "Currency is not available");
        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(currencyKeyOut) || currencyKeyOut == stableCoinAddress, "Currency is not available");
        require(numberOfTokens > 0, "Number of tokens must be greater than 0");

        address[] memory path = new address[](2);
        path[0] = currencyKeyIn;
        path[1] = currencyKeyOut;
        uint[] memory amounts = IUniswapV2Router02(ubeswapRouterAddress).getAmountsIn(numberOfTokens, path);

        return amounts[1];
    }

    /**
    * @dev Returns the farm address and liquidity pool address for each available farm on Ubeswap
    * @return address[] memory The farm address for each available farm
    */
    function getAvailableUbeswapFarms() public view override returns (address[] memory) {
        address ubeswapPoolManagerAddress = ADDRESS_RESOLVER.getContractAddress("UbeswapPoolManager");

        uint numberOfAvailableFarms = IUbeswapPoolManager(ubeswapPoolManagerAddress).poolsCount();
        address[] memory farmAddresses = new address[](numberOfAvailableFarms);

        for (uint i = 0; i < numberOfAvailableFarms; i++)
        {
            farmAddresses[i] = IUbeswapPoolManager(ubeswapPoolManagerAddress).poolsByIndex(i);
        }

        return farmAddresses;
    }

    /**
    * @dev Given the address of a farm on Ubeswap, returns the farm's staking token address
    * @param farmAddress Address of the farm to check
    * @return address The farm's staking token address
    */
    function checkIfFarmExists(address farmAddress) public view override returns (address) {
        require(farmAddress != address(0), "Invalid farm address");

        return IStakingRewards(farmAddress).stakingToken();
    }

    /**
    * @dev Returns the address of a token pair
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @return address The pair's address
    */
    function getPair(address tokenA, address tokenB) public view override returns (address) {
        require(tokenA != address(0), "BaseUbeswapAdapter: invalid address for tokenA");
        require(tokenB != address(0), "BaseUbeswapAdapter: invalid address for tokenB");

        address uniswapV2FactoryAddress = ADDRESS_RESOLVER.getContractAddress("UniswapV2Factory");

        return IUniswapV2Factory(uniswapV2FactoryAddress).getPair(tokenA, tokenB);
    }

    /**
    * @dev Returns the amount of UBE rewards available for the pool in the given farm
    * @param poolAddress Address of the pool
    * @param farmAddress Address of the farm on Ubeswap
    * @return uint Amount of UBE available
    */
    function getAvailableRewards(address poolAddress, address farmAddress) public view override returns (uint) {
        require(poolAddress != address(0), "BaseUbeswapAdapter: invalid pool address");
        require(checkIfFarmExists(farmAddress) != address(0), "BaseUbeswapAdapter: invalid farm address");

        return IStakingRewards(farmAddress).earned(poolAddress);
    }

    /**
    * @dev Calculates the amount of tokens in a pair
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param numberOfLPTokens Number of LP tokens for the given pair
    * @return (uint, uint) The number of tokens for tokenA and tokenB
    */
    function getTokenAmountsFromPair(address tokenA, address tokenB, uint numberOfLPTokens) public view override returns (uint, uint) {
        address pair = getPair(tokenA, tokenB);
        require(pair != address(0), "BaseUbeswapAdapter: invalid address for pair");

        uint pairBalanceTokenA = IERC20(tokenA).balanceOf(pair);
        uint pairBalanceTokenB = IERC20(tokenB).balanceOf(pair);
        uint totalSupply = IERC20(pair).totalSupply();

        uint amountA = pairBalanceTokenA.mul(numberOfLPTokens).div(totalSupply);
        uint amountB = pairBalanceTokenB.mul(numberOfLPTokens).div(totalSupply);

        return (amountA, amountB);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
    * @dev Swaps an exact `amountToSwap` of an asset to another; meant to be called from a user pool
    * @notice Pool needs to transfer assetToSwapFrom to BaseUbeswapAdapter before calling this function
    * @param assetToSwapFrom Origin asset
    * @param assetToSwapTo Destination asset
    * @param amountToSwap Exact amount of `assetToSwapFrom` to be swapped
    * @param minAmountOut the min amount of `assetToSwapTo` to be received from the swap
    * @return the number of tokens received
    */
    function swapFromPool(address assetToSwapFrom, address assetToSwapTo, uint amountToSwap, uint minAmountOut) public override returns (uint) {
        require(ADDRESS_RESOLVER.checkIfPoolAddressIsValid(msg.sender), "Only the pool can call this function");

        return _swapExactTokensForTokens(msg.sender, assetToSwapFrom, assetToSwapTo, amountToSwap, minAmountOut);
    }

    /**
    * @dev Swaps an exact `amountToSwap` of an asset to another; meant to be called from a trading bot
    * @notice Bot needs to transfer assetToSwapFrom to BaseUbeswapAdapter before calling this function
    * @param assetToSwapFrom Origin asset
    * @param assetToSwapTo Destination asset
    * @param amountToSwap Exact amount of `assetToSwapFrom` to be swapped
    * @param minAmountOut the min amount of `assetToSwapTo` to be received from the swap
    * @return the number of tokens received
    */
    function swapFromBot(address assetToSwapFrom, address assetToSwapTo, uint amountToSwap, uint minAmountOut) public override returns (uint) {
        require(ADDRESS_RESOLVER.checkIfTradingBotAddressIsValid(msg.sender), "Only the trading bot can call this function");

        return _swapExactTokensForTokens(msg.sender, assetToSwapFrom, assetToSwapTo, amountToSwap, minAmountOut);
    }

    /**
    * @dev Swaps an exact `amountToSwap` of an asset to another; meant to be called from stable coin staking pool
    * @param assetToSwapFrom Origin asset
    * @param assetToSwapTo Destination asset
    * @param amountToSwap Exact amount of `assetToSwapFrom` to be swapped
    * @param minAmountOut the min amount of `assetToSwapTo` to be received from the swap
    * @return uint The number of tokens received
    */
    function swapFromStableCoinPool(address assetToSwapFrom, address assetToSwapTo, uint amountToSwap, uint minAmountOut) public override returns (uint) {
        require(msg.sender == ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager"), "BaseUbeswapAdapter: Only LeveragedAssetPositionManager contract can call this function");

        return _swapExactTokensForTokens(msg.sender, assetToSwapFrom, assetToSwapTo, amountToSwap, minAmountOut);
    }

    /**
    * @dev Adds liquidity for the two given tokens; meant to be called from a pool
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param amountA Amount of first token
    * @param amountB Amount of second token
    * @return uint The number of tokens LP tokens minted
    */
    function addLiquidity(address tokenA, address tokenB, uint amountA, uint amountB) public override returns (uint) {
        require(ADDRESS_RESOLVER.checkIfPoolAddressIsValid(msg.sender), "Only the pool can call this function");

        return _addLiquidity(msg.sender, tokenA, tokenB, amountA, amountB);
    }

    /**
    * @dev Removes liquidity for the two given tokens; meant to be called from a pool
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param numberOfLPTokens Number of LP tokens for the given pair
    * @return (uint, uint) Amount of tokenA and tokenB withdrawn
    */
    function removeLiquidity(address tokenA, address tokenB, uint numberOfLPTokens) public override returns (uint, uint) {
        require(ADDRESS_RESOLVER.checkIfPoolAddressIsValid(msg.sender), "Only the pool can call this function");

        return _removeLiquidity(msg.sender, tokenA, tokenB, numberOfLPTokens);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
    * @dev Swaps an exact `amountToSwap` of an asset to another
    * @notice Assumes amountToSwap is multiplied by currency's decimals before function call
    * @param addressToSwapFrom the pool or bot that is making the swap
    * @param assetToSwapFrom Origin asset
    * @param assetToSwapTo Destination asset
    * @param amountToSwap Exact amount of `assetToSwapFrom` to be swapped
    * @param minAmountOut the min amount of `assetToSwapTo` to be received from the swap
    * @return the amount of tokens received
    */
    function _swapExactTokensForTokens(address addressToSwapFrom, address assetToSwapFrom, address assetToSwapTo, uint amountToSwap, uint minAmountOut) internal returns (uint) {
        uint amountOut = getAmountsOut(amountToSwap, assetToSwapFrom, assetToSwapTo);
        uint expectedMinAmountOut = amountOut.mul(100 - MAX_SLIPPAGE_PERCENT).div(100);

        require(expectedMinAmountOut < minAmountOut, 'BaseUbeswapAdapter: minAmountOut exceeds max slippage');

        address ubeswapRouterAddress = ADDRESS_RESOLVER.getContractAddress("UbeswapRouter");

        // Approves the transfer for the swap. Approves for 0 first to comply with tokens that implement the anti frontrunning approval fix.
        IERC20(assetToSwapFrom).approve(ubeswapRouterAddress, 0);
        IERC20(assetToSwapFrom).approve(ubeswapRouterAddress, amountToSwap);

        address[] memory path;
        path = new address[](2);
        path[0] = assetToSwapFrom;
        path[1] = assetToSwapTo;

        uint[] memory amounts = IUniswapV2Router02(ubeswapRouterAddress).swapExactTokensForTokens(amountToSwap, minAmountOut, path, addressToSwapFrom, block.timestamp);

        emit Swapped(addressToSwapFrom, assetToSwapFrom, assetToSwapTo, amounts[0], amounts[amounts.length - 1], block.timestamp);

        return amounts[amounts.length - 1];
    }

    /**
    * @dev Adds liquidity for the two given tokens
    * @param addressToAddFrom Address of the pool
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param amountA Amount of first token
    * @param amountB Amount of second token
    * @return uint The number of tokens LP tokens minted
    */
    function _addLiquidity(address addressToAddFrom, address tokenA, address tokenB, uint amountA, uint amountB) internal returns (uint) {
        address ubeswapRouterAddress = ADDRESS_RESOLVER.getContractAddress("UbeswapRouter");

        // Approves the transfer for the swap. Approves for 0 first to comply with tokens that implement the anti frontrunning approval fix.
        IERC20(tokenA).approve(ubeswapRouterAddress, 0);
        IERC20(tokenA).approve(ubeswapRouterAddress, amountA);

        // Approves the transfer for the swap. Approves for 0 first to comply with tokens that implement the anti frontrunning approval fix.
        IERC20(tokenB).approve(ubeswapRouterAddress, 0);
        IERC20(tokenB).approve(ubeswapRouterAddress, amountB);

        (,, uint numberOfLPTokens) = IUniswapV2Router02(ubeswapRouterAddress).addLiquidity(tokenA, tokenB, amountA, amountB, 0, 0, addressToAddFrom, block.timestamp.add(10 minutes));

        emit AddedLiquidity(addressToAddFrom, tokenA, tokenB, amountA, amountB, numberOfLPTokens, block.timestamp);

        return numberOfLPTokens;
    }

    /**
    * @dev Removes liquidity for the two given tokens
    * @param addressToRemoveFrom Address of the pool
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param numberOfLPTokens Number of LP tokens for the given pair
    * @return (uint, uint) Amount of tokenA and tokenB withdrawn
    */
    function _removeLiquidity(address addressToRemoveFrom, address tokenA, address tokenB, uint numberOfLPTokens) internal returns (uint, uint) {
        address ubeswapRouterAddress = ADDRESS_RESOLVER.getContractAddress("UbeswapRouter");

        (uint amountAReceived, uint amountBReceived) = IUniswapV2Router02(ubeswapRouterAddress).removeLiquidity(tokenA, tokenB, numberOfLPTokens, 0, 0, addressToRemoveFrom, block.timestamp.add(10 minutes));
        emit RemovedLiquidity(addressToRemoveFrom, tokenA, tokenB, amountAReceived, amountBReceived, block.timestamp);

        return (amountAReceived, amountBReceived);
    }

    /**
    * @dev Get the decimals of an asset
    * @return number of decimals of the asset
    */
    function _getDecimals(address asset) internal view returns (uint) {
        return IERC20(asset).decimals();
    }

    /* ========== EVENTS ========== */

    event Swapped(address addressSwappedFrom, address fromAsset, address toAsset, uint fromAmount, uint receivedAmount, uint timestamp);
    event AddedLiquidity(address addressAddedFrom, address tokenA, address tokenB, uint amountA, uint amountB, uint numberOfLPTokens, uint timestamp);
    event RemovedLiquidity(address addressRemovedFrom, address tokenA, address tokenB, uint amountAReceived, uint amountBReceived, uint timestamp);
}