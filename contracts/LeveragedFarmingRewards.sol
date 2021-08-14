pragma solidity >=0.5.0;

//Interfaces
import './interfaces/IAddressResolver.sol';
import './interfaces/ISettings.sol';
import './interfaces/IERC20.sol';
import './interfaces/IBaseUbeswapAdapter.sol';
import './interfaces/IStakingRewards.sol';

//Libraries
import './libraries/SafeMath.sol';

//Inheritance
import "./Ownable.sol";

contract LeveragedFarmingRewards is Ownable {
    using SafeMath for uint;

    IAddressResolver public immutable ADDRESS_RESOLVER;
    bool private initialized = false;

    mapping (address => uint) public availableUBE; //Amount of UBE available for each farm
    mapping (address => uint) public lastUpdateTime;
    mapping (address => uint) public rewardPerTokenStored;
    mapping (address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping (address => mapping(address => uint256)) public rewards;

    mapping(address => uint) public totalSupply;
    mapping(address => mapping(address => uint)) public balances;

    constructor(IAddressResolver addressResolver) public Ownable() {
        ADDRESS_RESOLVER = addressResolver;
    }

    /* ========== VIEWS ========== */

    /**
     * @notice Calculates the amount of UBE reward per token staked in the given farm.
     */
    function rewardPerToken(address farmAddress) internal view returns (uint) {
        require(farmAddress != address(0), "LeveragedFarmingRewards: invalid farm address");

        //Account for keeper fee
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        uint keeperFee = ISettings(settingsAddress).getParameterValue("UBEKeeperReward");

        return IStakingRewards(farmAddress).rewardPerToken().mul(1000 - keeperFee).div(1000);
    }

    /**
     * @notice Calculates the amount of UBE rewards earned for the given farm.
     */
    function earned(address account, address farmAddress) internal view returns (uint) {
        require(farmAddress != address(0), "LeveragedFarmingRewards: invalid farm address");

        return balances[farmAddress][account].mul(rewardPerToken(farmAddress).sub(userRewardPerTokenPaid[farmAddress][account])).div(1e18).add(rewards[farmAddress][account]);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Stake LP tokens to the given farm
     */
    function _stake(address user, address farmAddress, uint numberOfLPTokens) internal updateReward(user, farmAddress) {
        require(numberOfLPTokens > 0, "LeveragedFarmingRewards: Cannot stake 0");
        require(farmAddress != address(0), "LeveragedFarmingRewards: invalid farm address");
        require(user != address(0), "LeveragedFarmingRewards: invalid user address");

        totalSupply[farmAddress] = totalSupply[farmAddress].add(numberOfLPTokens);
        balances[farmAddress][user] = balances[farmAddress][user].add(numberOfLPTokens);
    }

    /**
     * @notice Unstake LP tokens from the given farm
     */
    function _unstake(address user, address farmAddress, uint numberOfLPTokens) internal updateReward(user, farmAddress) {
        require(numberOfLPTokens > 0, "LeveragedFarmingRewards: Cannot stake 0");
        require(farmAddress != address(0), "LeveragedFarmingRewards: invalid farm address");
        require(user != address(0), "LeveragedFarmingRewards: invalid user address");

        totalSupply[farmAddress] = totalSupply[farmAddress].sub(numberOfLPTokens);
        balances[farmAddress][user] = balances[farmAddress][user].sub(numberOfLPTokens);
    }

    /**
     * @notice Increases available UBE for the farm
     */
    function _updateAvailableUBE(address farmAddress, uint numberOfUBE) internal {
        require(numberOfUBE > 0, "LeveragedFarmingRewards: Number of UBE must be greater than 0");
        require(farmAddress != address(0), "LeveragedFarmingRewards: invalid farm address");

        availableUBE[farmAddress] = availableUBE[farmAddress].add(numberOfUBE);
    }

    /**
     * @notice Allow a user to claim any available staking rewards for the given farm.
     */
    function _getReward(address farmAddress) internal updateReward(msg.sender, farmAddress) returns (uint) {
        require(farmAddress != address(0), "LeveragedFarmingRewards: invalid farm address");

        uint reward = (rewards[farmAddress][msg.sender] > 0) ? rewards[farmAddress][msg.sender] : 0;

        if (reward > 0)
        {
            rewards[farmAddress][msg.sender] = 0;
            availableUBE[farmAddress] = availableUBE[farmAddress].sub(reward);
        }

        return reward;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
     * @notice Initialize the lastUpdateTime of each Ubeswap farm; meant to be called once
     */
    function initializeFarms() external onlyOwner {
        require(!initialized, "Already initialized farms");

        //Initialize lastUpdateTime of each available Ubeswap farm
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");
        address[] memory farms = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getAvailableUbeswapFarms();

        for (uint i = 0; i < farms.length; i++)
        {
            lastUpdateTime[farms[i]] = block.timestamp;
        }

        initialized = true;
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account, address farmAddress) {
        require(farmAddress != address(0), "LeveragedFarmingRewards: invalid farm address");

        rewardPerTokenStored[farmAddress] = rewardPerToken(farmAddress);
        lastUpdateTime[farmAddress] = IStakingRewards(farmAddress).lastTimeRewardApplicable();

        if (account != address(0))
        {
            rewards[farmAddress][account] = earned(account, farmAddress);
            userRewardPerTokenPaid[farmAddress][account] = rewardPerTokenStored[farmAddress];
        }
        _;
    }
}