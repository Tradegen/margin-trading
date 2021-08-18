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

    /* ========== EVENTS ========== */

    event Vested(address indexed beneficiary, uint time, uint value);
    event Staked(address indexed beneficiary, uint total, uint vestingTimestamp, uint timestamp);
    event StakingRewardPaid(address indexed user, uint amount, uint timestamp);
    event InterestRewardPaid(address indexed user, uint amount, uint timestamp);
}