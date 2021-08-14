pragma solidity >=0.5.0;

interface IUbeswapPoolManager {
    struct PoolInfo {
        uint256 index;
        address stakingToken;
        address poolAddress;
        uint256 weight;
        // The next period in which the pool needs to be filled
        uint256 nextPeriod;
    }

    function poolsCount() external view returns(uint256);

    function poolsByIndex(uint256) external view returns(address);
}