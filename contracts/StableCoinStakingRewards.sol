pragma solidity >=0.5.0;

//Adapters
import './interfaces/IBaseUbeswapAdapter.sol';

// Inheritance
import "./Ownable.sol";
import "./interfaces/IStableCoinStakingRewards.sol";
import "./openzeppelin-solidity/ReentrancyGuard.sol";

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

contract StableCoinStakingRewards is Ownable, IStableCoinStakingRewards, ReentrancyGuard {
    using SafeMath for uint;

    IAddressResolver public immutable ADDRESS_RESOLVER;

    uint public lastUpdateTime;
    uint public stakingRewardPerTokenStored;
    uint public interestRewardPerTokenStored;
    mapping(address => uint) public userStakingRewardPerTokenPaid;
    mapping(address => uint) public userInterestRewardPerTokenPaid;
    mapping(address => uint) public stakingRewards;
    mapping(address => uint) public interestRewards;

    /* Lists of (timestamp, quantity) pairs per account, sorted in ascending time order.
     * These are the times at which each given quantity of cUSD vests. */
    mapping(address => uint[2][]) public vestingSchedules;

    /* An account's total vested cUSD balance to save recomputing this */
    mapping(address => uint) public totalVestedAccountBalance;

    /* The total remaining vested balance, for verifying the actual cUSD balance of this contract against. */
    uint public totalVestedBalance;

    uint public constant TIME_INDEX = 0;
    uint public constant QUANTITY_INDEX = 1;

    /* Limit vesting entries to disallow unbounded iteration over vesting schedules. */
    uint public constant MAX_VESTING_ENTRIES = 48;

    /* ========== CONSTRUCTOR ========== */

    constructor(IAddressResolver _addressResolver) public Ownable() {
        ADDRESS_RESOLVER = _addressResolver;
        lastUpdateTime = block.timestamp;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice A simple alias to totalVestedAccountBalance: provides ERC20 balance integration.
     */
    function balanceOf(address account) public view override returns (uint) {
        return totalVestedAccountBalance[account];
    }

    /**
     * @notice The number of vesting dates in an account's schedule.
     */
    function numVestingEntries(address account) public view override returns (uint) {
        return vestingSchedules[account].length;
    }

    /**
     * @notice Get a particular schedule entry for an account.
     * @return A pair of uints: (timestamp, cUSD quantity).
     */
    function getVestingScheduleEntry(address account, uint index) public view override returns (uint[2] memory) {
        return vestingSchedules[account][index];
    }

    /**
     * @notice Get the time at which a given schedule entry will vest.
     */
    function getVestingTime(address account, uint index) public view override returns (uint) {
        return getVestingScheduleEntry(account, index)[TIME_INDEX];
    }

    /**
     * @notice Get the quantity of cUSD associated with a given schedule entry.
     */
    function getVestingQuantity(address account, uint index) public view override returns (uint) {
        return getVestingScheduleEntry(account, index)[QUANTITY_INDEX];
    }

    /**
     * @notice Obtain the index of the next schedule entry that will vest for a given user.
     */
    function getNextVestingIndex(address account) public view override returns (uint) {
        uint len = numVestingEntries(account);

        for (uint i = 0; i < len; i++)
        {
            if (getVestingTime(account, i) != 0)
            {
                return i;
            }
        }

        return len;
    }

    /**
     * @notice Calculates the amount of TGEN reward and the amount of cUSD interest reward per token staked
     */
    function rewardPerToken() public view override returns (uint, uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address interestRewardsPoolEscrowAddress = ADDRESS_RESOLVER.getContractAddress("InterestRewardsPoolEscrow");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();
        uint stakingRewardRate = ISettings(settingsAddress).getParameterValue("WeeklyStableCoinStakingRewards");
        uint interestRewardRate = IERC20(stableCoinAddress).balanceOf(interestRewardsPoolEscrowAddress);

        if (totalVestedBalance == 0)
        {
            return (stakingRewardPerTokenStored, interestRewardPerTokenStored);
        }
        uint stakingRewardPerToken = stakingRewardPerTokenStored.add(block.timestamp.sub(lastUpdateTime).mul(stakingRewardRate).mul(1e18).div(totalVestedBalance));
        uint interestRewardPerToken = interestRewardPerTokenStored.add(block.timestamp.sub(lastUpdateTime).mul(interestRewardRate).mul(1e18).div(totalVestedBalance));

        return (stakingRewardPerToken, interestRewardPerToken);
    }

    /**
     * @notice Calculates the amount of TGEN rewards and cUSD interest rewards earned.
     */
    function earned(address account) public view override returns (uint, uint) {
        (uint stakingRewardPerToken, uint interestRewardPerToken) = rewardPerToken();
        uint stakingRewardEarned = totalVestedAccountBalance[account].mul(stakingRewardPerToken.sub(userStakingRewardPerTokenPaid[account])).div(1e18).add(stakingRewards[account]);
        uint interestRewardEarned = totalVestedAccountBalance[account].mul(interestRewardPerToken.sub(userInterestRewardPerTokenPaid[account])).div(1e18).add(interestRewards[account]);

        return (stakingRewardEarned, interestRewardEarned);
    }

    /**
     * @notice Obtain the next schedule entry that will vest for a given user.
     * @return A pair of uints: (timestamp, cUSD quantity). */
    function getNextVestingEntry(address account) public view override returns (uint[2] memory) {
        uint index = getNextVestingIndex(account);
        if (index == numVestingEntries(account))
        {
            return [uint(0), 0];
        }

        return getVestingScheduleEntry(account, index);
    }

    /**
     * @notice Obtain the time at which the next schedule entry will vest for a given user.
     */
    function getNextVestingTime(address account) external view override returns (uint) {
        return getNextVestingEntry(account)[TIME_INDEX];
    }

    /**
     * @notice Obtain the quantity which the next schedule entry will vest for a given user.
     */
    function getNextVestingQuantity(address account) external view override returns (uint) {
        return getNextVestingEntry(account)[QUANTITY_INDEX];
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @notice Add a new vesting entry at a given time and quantity to an account's schedule.
     * @param account The account to append a new vesting entry to.
     * @param time The absolute unix timestamp after which the vested quantity may be withdrawn.
     * @param quantity The quantity of cUSD that will vest.
     */
    function appendVestingEntry(address account, uint time, uint quantity) internal {
        /* No empty or already-passed vesting entries allowed. */
        require(block.timestamp < time, "Time must be in the future");
        require(quantity != 0, "Quantity cannot be zero");

        /* Disallow arbitrarily long vesting schedules in light of the gas limit. */
        uint scheduleLength = vestingSchedules[account].length;
        require(scheduleLength <= MAX_VESTING_ENTRIES, "Vesting schedule is too long");

        if (scheduleLength == 0)
        {
            totalVestedAccountBalance[account] = quantity;
        }
        else
        {
            /* Disallow adding new vested cUSD earlier than the last one.
             * Since entries are only appended, this means that no vesting date can be repeated. */
            require(
                getVestingTime(account, numVestingEntries(account) - 1) < time,
                "Cannot add new vested entries earlier than the last one"
            );

            totalVestedAccountBalance[account] = totalVestedAccountBalance[account].add(quantity);
        }

        vestingSchedules[account].push([time, quantity]);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Stakes the given cUSD amount.
     */
    function stake(uint amount) external override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "StableCoinStakingRewards: Staked amount must be greater than 0");

        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        uint vestingTimestamp = block.timestamp.add(30 days);
        appendVestingEntry(msg.sender, vestingTimestamp, amount);

        totalVestedBalance = totalVestedBalance.add(amount);
        IERC20(stableCoinAddress).transferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, vestingTimestamp, block.timestamp);
    }

    /**
     * @notice Allow a user to withdraw any cUSD in their schedule that have vested.
     */
    function vest() external override nonReentrant updateReward(msg.sender) {
        uint numEntries = numVestingEntries(msg.sender);
        uint total;

        for (uint i = 0; i < numEntries; i++)
        {
            uint time = getVestingTime(msg.sender, i);
            /* The list is sorted; when we reach the first future time, bail out. */
            if (time > block.timestamp)
            {
                break;
            }

            uint qty = getVestingQuantity(msg.sender, i);

            if (qty > 0)
            {
                vestingSchedules[msg.sender][i] = [0, 0];
                total = total.add(qty);
            }
        }

        if (total != 0)
        {
            address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
            address insuranceFundAddress = ADDRESS_RESOLVER.getContractAddress("InsuranceFund");
            address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();
            totalVestedBalance = totalVestedBalance.sub(total);
            totalVestedAccountBalance[msg.sender] = totalVestedAccountBalance[msg.sender].sub(total);

            uint contractStableCoinBalance = IERC20(stableCoinAddress).balanceOf(address(this));
            uint deficit = (contractStableCoinBalance < total) ? total.sub(contractStableCoinBalance) : 0;

            //First withdraw min(contract cUSD balance, total) from this contract
            if (deficit < total)
            {
                IERC20(stableCoinAddress).transfer(msg.sender, total.sub(deficit));
            }
            
            //Withdraw from insurance fund if not enough cUSD in this contract to cover withdrawal
            if (deficit > 0)
            {
                IInsuranceFund(insuranceFundAddress).withdrawFromFund(deficit, msg.sender);
            }

            emit Vested(msg.sender, block.timestamp, total);
        }

        getReward();
    }

    /**
     * @notice Allow a user to claim any available staking rewards and interest rewards.
     */
    function getReward() public override nonReentrant updateReward(msg.sender) {
        address baseTradegenAddress = ADDRESS_RESOLVER.getContractAddress("BaseTradegen");
        address interestRewardsPoolEscrowAddress = ADDRESS_RESOLVER.getContractAddress("InterestRewardsPoolEscrow");
        uint stakingReward = stakingRewards[msg.sender];
        uint interestReward = interestRewards[msg.sender];

        if (stakingReward > 0)
        {
            stakingRewards[msg.sender] = 0;
            IERC20(baseTradegenAddress).transfer(msg.sender, stakingReward);
            emit StakingRewardPaid(msg.sender, stakingReward, block.timestamp);
        }

        if (interestReward > 0)
        {
            interestRewards[msg.sender] = 0;
            IInterestRewardsPoolEscrow(interestRewardsPoolEscrowAddress).claimRewards(msg.sender, interestReward);
            emit InterestRewardPaid(msg.sender, interestReward, block.timestamp);
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
     * @notice Swaps cUSD for specified asset; meant to be called from LeveragedAssetPositionManager contract
     * @param asset Asset to swap to
     * @param collateral Amount of cUSD to transfer from user
     * @param borrowedAmount Amount of cUSD borrowed
     * @param user Address of the user
     * @return uint Number of asset tokens received
     */
    function swapToAsset(address asset, uint collateral, uint borrowedAmount, address user) public override onlyLeveragedAssetPositionManager returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        require(ISettings(settingsAddress).checkIfCurrencyIsAvailable(asset), "StableCoinStakingRewards: currency not available");
        require(IERC20(asset).balanceOf(address(this)) >= collateral.add(borrowedAmount), "StableCoinStakingRewards: not enough cUSD available to swap");

        uint numberOfDecimals = IERC20(asset).decimals();
        uint tokenToUSD = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getPrice(asset);
        uint numberOfTokens = (collateral.add(borrowedAmount)).div(tokenToUSD).div(10 ** numberOfDecimals);

        //Remove collateral from user
        IERC20(stableCoinAddress).transferFrom(user, address(this), collateral);

        //Swap cUSD for asset
        IERC20(stableCoinAddress).transfer(baseUbeswapAdapterAddress, collateral.add(borrowedAmount));
        uint numberOfTokensReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromStableCoinPool(stableCoinAddress, asset, collateral.add(borrowedAmount), numberOfTokens);

        return numberOfTokensReceived;
    }

    /**
     * @notice Swaps specified asset for cUSD; meant to be called from LeveragedAssetPositionManager contract
     * @param asset Asset to swap from
     * @param userShare User's ratio of received tokens
     * @param poolShare Pool's ratio of received tokens
     * @param numberOfAssetTokens Number of asset tokens to swap
     * @param user Address of the user
     * @return uint Amount of cUSD user received
     */
    function swapFromAsset(address asset, uint userShare, uint poolShare, uint numberOfAssetTokens, address user) public override onlyLeveragedAssetPositionManager returns (uint) {
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
    function liquidateLeveragedAsset(address asset, uint userShare, uint liquidatorShare, uint poolShare, uint numberOfAssetTokens, address user, address liquidator) public override onlyLeveragedAssetPositionManager returns (uint) {
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
    function payInterest(address asset, uint numberOfAssetTokens) public override onlyLeveragedAssetPositionManager {
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
    function claimUserUBE(address user, uint amountOfUBE) public override onlyLeveragedLiquidityPositionManager {
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
    function claimFarmUBE(address user, address farmAddress) public override onlyLeveragedLiquidityPositionManager returns (uint, uint) {
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
    function addLiquidity(address tokenA, address tokenB, uint amountA, uint amountB, address farmAddress) public override onlyLeveragedLiquidityPositionManager returns (uint) {
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
    function removeLiquidity(address pair, address farmAddress, uint numberOfLPTokens) public override onlyLeveragedLiquidityPositionManager returns (uint, uint) {
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

    modifier updateReward(address account) {
        (uint stakingRewardPerToken, uint interestRewardPerToken) = rewardPerToken();
        stakingRewardPerTokenStored = stakingRewardPerToken;
        interestRewardPerTokenStored = interestRewardPerToken;
        lastUpdateTime = block.timestamp;
        if (account != address(0))
        {
            (uint stakingReward, uint interestReward) = earned(account);
            stakingRewards[account] = stakingReward;
            interestRewards[account] = interestReward;
            userStakingRewardPerTokenPaid[account] = stakingRewardPerTokenStored;
            userInterestRewardPerTokenPaid[account] = interestRewardPerTokenStored;
        }
        _;
    }

    modifier onlyLeveragedAssetPositionManager() {
        require(msg.sender == ADDRESS_RESOLVER.getContractAddress("LeveragedAssetPositionManager"), "StableCoinStakingRewards: Only LeveragedAssetPositionManager contract can call this function");
        _;
    }

    modifier onlyLeveragedLiquidityPositionManager() {
        require(msg.sender == ADDRESS_RESOLVER.getContractAddress("LeveragedLiquidityPositionManager"), "StableCoinStakingRewards: Only LeveragedLiquidityPositionManager contract can call this function");
        _;
    }

    /* ========== EVENTS ========== */

    event Vested(address indexed beneficiary, uint time, uint value);
    event Staked(address indexed beneficiary, uint total, uint vestingTimestamp, uint timestamp);
    event StakingRewardPaid(address indexed user, uint amount, uint timestamp);
    event InterestRewardPaid(address indexed user, uint amount, uint timestamp);
}