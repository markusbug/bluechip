// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {MockStock} from "./MockStock.sol";

/// @notice Testnet stand-in for a DEX: pays out the feed value of the input minus `slippageBps`,
///         minting the output mock stock. Keeps the input.
contract MockOracleSwapper is ISwapper {
    mapping(address token => address feed) public feedOf;
    uint256 public slippageBps;

    constructor(address[] memory tokens, address[] memory feeds, uint256 slippageBps_) {
        for (uint256 i; i < tokens.length; ++i) {
            feedOf[tokens[i]] = feeds[i];
        }
        slippageBps = slippageBps_;
    }

    function setSlippage(uint256 bps) external {
        slippageBps = bps;
    }

    function swap(address sell, address buy, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut)
    {
        uint256 usd = Math.mulDiv(amountIn, _price(sell), 10 ** MockStock(sell).decimals());
        usd = usd * (10_000 - slippageBps) / 10_000;
        amountOut = Math.mulDiv(usd, 10 ** MockStock(buy).decimals(), _price(buy));
        MockStock(buy).mint(recipient, amountOut);
    }

    function _price(address token) private view returns (uint256) {
        (, int256 answer,,,) = IPriceFeed(feedOf[token]).latestRoundData();
        return uint256(answer);
    }
}
