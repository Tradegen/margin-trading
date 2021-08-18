pragma solidity >=0.5.0;

//Inheritance
import './interfaces/IStableCoinReserve.sol';

// Libraries
import "./libraries/SafeMath.sol";

// Internal references
import "./interfaces/IERC20.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/ISettings.sol";
import "./interfaces/IInsuranceFund.sol";
import "./interfaces/IInterestRewardsPoolEscrow.sol";
import "./interfaces/IStakingRewards.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IBaseUbeswapAdapter.sol";

contract StableCoinReserve is IStableCoinReserve {
    using SafeMath for uint;

    IAddressResolver public immutable ADDRESS_RESOLVER;

    constructor(IAddressResolver _addressResolver) public {
        ADDRESS_RESOLVER = _addressResolver;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
     * @notice Swaps cUSD for specified asset; meant to be called from an LToken contract
     * @param asset Asset to swap to
     * @param collateral Amount of cUSD to transfer from user
     * @param borrowedAmount Amount of cUSD borrowed
     * @param user Address of the user
     * @return uint Number of asset tokens received
     */
    function swapToAsset(address asset, uint collateral, uint borrowedAmount, address user) public override onlyLToken returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        //Remove collateral from user
        IERC20(stableCoinAddress).transferFrom(user, address(this), collateral);

        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(asset), "StableCoinReserve: currency not available");
        require(IERC20(asset).balanceOf(address(this)) >= collateral.add(borrowedAmount), "StableCoinReserve: not enough cUSD available to swap");

        uint numberOfDecimals = IERC20(asset).decimals();
        uint tokenToUSD = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(asset);
        uint numberOfTokens = (collateral.add(borrowedAmount)).div(tokenToUSD).div(10 ** numberOfDecimals);

        //Swap cUSD for asset
        IERC20(stableCoinAddress).transfer(baseUbeswapAdapterAddress, collateral.add(borrowedAmount));
        uint numberOfTokensReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromStableCoinPool(stableCoinAddress, asset, collateral.add(borrowedAmount), numberOfTokens);

        return numberOfTokensReceived;
    }

    /**
     * @notice Swaps specified asset for cUSD; meant to be called from an LToken contract
     * @param asset Asset to swap from
     * @param userShare User's ratio of received tokens
     * @param poolShare Pool's ratio of received tokens
     * @param numberOfAssetTokens Number of asset tokens to swap
     * @param user Address of the user
     * @return uint Amount of cUSD user received
     */
    function swapFromAsset(address asset, uint userShare, uint poolShare, uint numberOfAssetTokens, address user) public override onlyLToken returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address insuranceFundAddress = ADDRESS_RESOLVER.getContractAddress("InsuranceFund");
        address baseTradegenAddress = ADDRESS_RESOLVER.getContractAddress("BaseTradegen");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(asset), "StableCoinReserve: currency not available");

        //Get price of asset
        uint numberOfDecimals = IERC20(asset).decimals();
        uint tokenToUSD = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(asset);
        uint amountInUSD = (numberOfAssetTokens).mul(tokenToUSD).div(10 ** numberOfDecimals);

        //Swap asset for cUSD
        IERC20(asset).transfer(baseUbeswapAdapterAddress, numberOfAssetTokens);
        uint cUSDReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromStableCoinPool(asset, stableCoinAddress, numberOfAssetTokens, amountInUSD);

        //Transfer pool share to insurance fund if this contract's cUSD balance > totalVestedBalance (surplus if a withdrawal was made from insurance fund)
        //Swap cUSD for TGEN if insurance fund's TGEN reserves are low
        uint poolUSDAmount = cUSDReceived.mul(poolShare).div(userShare.add(poolShare));
        uint surplus = (IERC20(stableCoinAddress).balanceOf(address(this)) > totalVestedBalance) ? poolUSDAmount.sub(IERC20(stableCoinAddress).balanceOf(address(this))) : 0;
        if (IInsuranceFund(insuranceFundAddress).getFundStatus() < 2)
        {
            //Swap cUSD for TGEN and transfer to insurance fund
            IERC20(stableCoinAddress).transfer(baseUbeswapAdapterAddress, surplus);
            uint numberOfTokensReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromStableCoinPool(stableCoinAddress, asset, surplus, 0);
            IERC20(baseTradegenAddress).transfer(insuranceFundAddress, numberOfTokensReceived);
        }

        //Transfer cUSD to user
        uint userUSDAmount = cUSDReceived.mul(userShare).div(userShare.add(poolShare));
        IERC20(stableCoinAddress).transfer(user, userUSDAmount);

        return userUSDAmount;
    }

    /**
     * @notice Liquidates a leveraged asset; meant to be called from LeveragedAssetPositionManager contract
     * @param asset Asset to swap from
     * @param userShare User's ratio of received tokens
     * @param liquidatorShare Liquidator's ratio of received tokens
     * @param poolShare Pool's ration of received tokens
     * @param numberOfAssetTokens Number of asset tokens to swap
     * @param user Address of the user
     * @param liquidator Address of the liquidator
     * @return uint Amount of cUSD user received
     */
    function liquidateLeveragedAsset(address asset, uint userShare, uint liquidatorShare, uint poolShare, uint numberOfAssetTokens, address user, address liquidator) public override onlyLToken returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address insuranceFundAddress = ADDRESS_RESOLVER.getContractAddress("InsuranceFund");
        address baseTradegenAddress = ADDRESS_RESOLVER.getContractAddress("BaseTradegen");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(asset), "StableCoinStakingRewards: currency not available");

        //Get price of asset
        uint numberOfDecimals = IERC20(asset).decimals();
        uint tokenToUSD = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(asset);
        uint amountInUSD = (numberOfAssetTokens).mul(tokenToUSD).div(10 ** numberOfDecimals);

        //Swap asset for cUSD
        IERC20(asset).transfer(baseUbeswapAdapterAddress, numberOfAssetTokens);
        uint cUSDReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromStableCoinPool(asset, stableCoinAddress, numberOfAssetTokens, amountInUSD);

        //Transfer pool share to insurance fund if this contract's cUSD balance > totalVestedBalance (surplus if a withdrawal was made from insurance fund)
        //Swap cUSD for TGEN if insurance fund's TGEN reserves are low
        uint poolUSDAmount = cUSDReceived.mul(poolShare).div(userShare.add(poolShare).add(liquidatorShare));
        uint surplus = (IERC20(stableCoinAddress).balanceOf(address(this)) > totalVestedBalance) ? poolUSDAmount.sub(IERC20(stableCoinAddress).balanceOf(address(this))) : 0;
        if (IInsuranceFund(insuranceFundAddress).getFundStatus() < 2)
        {
            //Swap cUSD for TGEN and transfer to insurance fund
            IERC20(stableCoinAddress).transfer(baseUbeswapAdapterAddress, surplus);
            uint numberOfTokensReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromStableCoinPool(stableCoinAddress, asset, surplus, 0);
            IERC20(baseTradegenAddress).transfer(insuranceFundAddress, numberOfTokensReceived);
        }

        //Transfer cUSD to user
        uint userUSDAmount = cUSDReceived.mul(userShare).div(userShare.add(poolShare).add(liquidatorShare));
        IERC20(stableCoinAddress).transfer(user, userUSDAmount);

        //Transfer cUSD to liquidator
        uint liquidatorUSDAmount = cUSDReceived.mul(liquidatorShare).div(userShare.add(poolShare).add(liquidatorShare));
        IERC20(stableCoinAddress).transfer(liquidator, liquidatorUSDAmount);

        return userUSDAmount;
    }

    /**
     * @notice Pays interest in the given asset; meant to be called from LeveragedAssetPositionManager contract
     * @param asset Asset to swap from
     * @param numberOfAssetTokens Number of asset tokens to swap
     */
    function payInterest(address asset, uint numberOfAssetTokens) public override onlyLToken {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address insuranceFundAddress = ADDRESS_RESOLVER.getContractAddress("InsuranceFund");
        address interestRewardsPoolEscrowAddress = ADDRESS_RESOLVER.getContractAddress("InterestRewardsPoolEscrow");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(asset), "StableCoinStakingRewards: currency not available");

        //Get price of asset
        uint numberOfDecimals = IERC20(asset).decimals();
        uint tokenToUSD = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(asset);
        uint amountInUSD = (numberOfAssetTokens).mul(tokenToUSD).div(10 ** numberOfDecimals);

        //Swap asset for cUSD
        IERC20(asset).transfer(baseUbeswapAdapterAddress, numberOfAssetTokens);
        uint cUSDReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromStableCoinPool(asset, stableCoinAddress, numberOfAssetTokens, amountInUSD);

        //Adjust distribution ratio based on status of insurance fund
        uint insuranceFundAllocation;
        uint insuranceFundStatus = IInsuranceFund(insuranceFundAddress).getFundStatus();
        if (insuranceFundStatus == 0)
        {
            insuranceFundAllocation = 100;
        }
        else if (insuranceFundStatus == 1)
        {
            insuranceFundAllocation = 60;
        }
        else if (insuranceFundStatus == 2)
        {
            insuranceFundAllocation = 25;
        }
        else
        {
            insuranceFundAllocation = 0;
        }

        //Transfer received cUSD to insurance fund
        IERC20(stableCoinAddress).transfer(insuranceFundAddress, cUSDReceived.mul(insuranceFundAllocation).div(100));

        //Transfer received cUSD to interest rewards pool
        IERC20(stableCoinAddress).transfer(interestRewardsPoolEscrowAddress, cUSDReceived.mul(100 - insuranceFundAllocation).div(100));
    }

    /**
     * @notice Claims user's UBE rewards for leveraged yield farming
     * @param user Address of the user
     * @param amountOfUBE Amount of UBE to transfer to user
     */
    function claimUserUBE(address user, uint amountOfUBE) public override onlyLToken {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address UBE = ISettings(settingsAddress).getCurrencyKeyFromSymbol("UBE");

        require(IERC20(UBE).balanceOf(address(this)) >= amountOfUBE, "StableCoinStakingRewards: not enough UBE in contract");

        IERC20(UBE).transfer(user, amountOfUBE);
    }

    /**
     * @notice Claims farm's UBE rewards for leveraged yield farming
     * @notice Sends a small percentage of claimed UBE to user as a reward
     * @param user Address of the user
     * @param farmAddress Address of the farm
     * @return (uint, uint) Amount of UBE claimed and keeper's share
     */
    function claimFarmUBE(address user, address farmAddress) public override onlyLToken returns (uint, uint) {
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address UBE = ISettings(settingsAddress).getCurrencyKeyFromSymbol("UBE");
        uint keeperReward = ISettings(settingsAddress).getParameterValue("UBEKeeperReward");
        uint initialBalance = IERC20(UBE).balanceOf(address(this));

        require(IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress) != address(0), "StableCoinStakingRewards: invalid farm address");

        //Claim farm's available UBE
        IStakingRewards(farmAddress).getReward();

        //Transfer keeper reward to user
        uint claimedUBE = IERC20(UBE).balanceOf(address(this)).sub(initialBalance);
        IERC20(UBE).transfer(user, claimedUBE.mul(keeperReward).div(1000));

        return (claimedUBE, claimedUBE.mul(keeperReward).div(1000));
    }

    /**
    * @dev Adds liquidity for the two given tokens
    * @param tokenA First token in pair
    * @param tokenB Second token in pair
    * @param amountA Amount of first token
    * @param amountB Amount of second token
    * @param farmAddress The token pair's farm address on Ubeswap
    * @return Number of LP tokens received
    */
    function addLiquidity(address tokenA, address tokenB, uint amountA, uint amountB, address farmAddress) public override onlyLToken returns (uint) {
        require(tokenA != address(0), "StableCoinStakingRewards: invalid address for tokenA");
        require(tokenB != address(0), "StableCoinStakingRewards: invalid address for tokenB");
        require(amountA > 0, "StableCoinStakingRewards: amountA must be greater than 0");
        require(amountB > 0, "StableCoinStakingRewards: amountB must be greater than 0");
        require(IERC20(tokenA).balanceOf(address(this)) >= amountA, "StableCoinStakingRewards: not enough tokens invested in tokenA");
        require(IERC20(tokenB).balanceOf(address(this)) >= amountB, "StableCoinStakingRewards: not enough tokens invested in tokenB");

        //Check if farm exists for the token pair
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stakingTokenAddress = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress);
        address pairAddress = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPair(tokenA, tokenB);

        require(stakingTokenAddress == pairAddress, "StableCoinStakingRewards: stakingTokenAddress does not match pairAddress");

        //Add liquidity to Ubeswap pool and stake LP tokens into associated farm
        uint numberOfLPTokens = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).addLiquidity(tokenA, tokenB, amountA, amountB);
        IStakingRewards(stakingTokenAddress).stake(numberOfLPTokens);

        return numberOfLPTokens;
    }

    /**
    * @dev Removes liquidity for the two given tokens
    * @param pair Address of liquidity pair
    * @param farmAddress The token pair's farm address on Ubeswap
    * @param numberOfLPTokens Number of LP tokens to remove
    * @return (uint, uint) Amount of pair's token0 and token1 received
    */
    function removeLiquidity(address pair, address farmAddress, uint numberOfLPTokens) public override onlyLToken returns (uint, uint) {
        //Check if farm exists for the token pair
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stakingTokenAddress = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).checkIfFarmExists(farmAddress);

        require(stakingTokenAddress == pair, "StableCoinStakingRewards: stakingTokenAddress does not match pair address");

        //Withdraw LP tokens from farm
        IStakingRewards(farmAddress).withdraw(numberOfLPTokens);

        //Remove liquidity from Ubeswap liquidity pool
        return IBaseUbeswapAdapter(baseUbeswapAdapterAddress).removeLiquidity(IUniswapV2Pair(pair).token0(), IUniswapV2Pair(pair).token1(), numberOfLPTokens);
    }

    /* ========== MODIFIERS ========== */

    //TODO:
    modifier onlyLToken() {
        require(msg.sender == ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager"), "StableCoinReserve: Only an LToken contract can call this function");
        _;
    }
}