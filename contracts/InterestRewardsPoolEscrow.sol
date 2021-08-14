pragma solidity >=0.5.0;

//Libraries
import './libraries/SafeMath.sol';

// Inheritance
import "./Ownable.sol";
import './interfaces/IInterestRewardsPoolEscrow.sol';

// Internal references
import "./interfaces/IERC20.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/ISettings.sol";

contract InterestRewardsPoolEscrow is Ownable, IInterestRewardsPoolEscrow {
    using SafeMath for uint;

    IAddressResolver public immutable ADDRESS_RESOLVER;

    constructor(IAddressResolver _addressResolver) public Ownable() {
        ADDRESS_RESOLVER = _addressResolver;
    }

    /* ========== VIEWS ========== */

    function getCurrentRewardRate() public view override returns (uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();

        return IERC20(stableCoinAddress).balanceOf(address(this));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function claimRewards(address user, uint amount) public override onlyStableCoinStakingRewards {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();
        
        require(user != address(0), "InterestRewardsPoolEscrow: invalid user address");
        require(amount > 0, "InterestRewardsPoolEscrow: No rewards to claim");
        require(IERC20(stableCoinAddress).balanceOf(address(this)) >= amount, "InterestRewardsPoolEscrow: Not enough cUSD in escrow");
        
        IERC20(stableCoinAddress).transfer(user, amount);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyStableCoinStakingRewards() {
        address stakingRewardsAddress = ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards");

        require(msg.sender == stakingRewardsAddress, "Only the StableCoinStakingRewards contract can call this function");
        _;
    }
}