pragma solidity >=0.5.0;

interface IInterestRewardsPoolEscrow {
    
    function getCurrentRewardRate() external view returns (uint);

    function claimRewards(address user, uint amount) external;
}