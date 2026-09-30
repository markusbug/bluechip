// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The subset of a Chainlink AggregatorV3 the rebalancer reads.
interface IPriceFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
