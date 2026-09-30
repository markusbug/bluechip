// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/// @notice Testnet stand-in for a Chainlink USD feed (8 decimals). Anyone can set the price.
contract MockPriceFeed is IPriceFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(int256 answer_) {
        setPrice(answer_);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function setPrice(int256 answer_) public {
        answer = answer_;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
