// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICLPool} from "../interfaces/ICLPool.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {MockStock} from "./MockStock.sol";

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Testnet stand-in for an Aerodrome Slipstream pool: trades at the two feed prices minus
///         `spreadBps`, exact input (`amountSpecified > 0`) or exact output (`< 0`), with the real
///         pool's flow: send the output, call back for the input, check it arrived. Mints the output
///         (a mock stock or mock USDC) and keeps the input.
contract MockOraclePool is ICLPool {
    uint256 private constant BPS = 10_000;

    address public immutable token0;
    address public immutable token1;
    address public immutable feed0;
    address public immutable feed1;
    uint256 public spreadBps;

    constructor(address token0_, address token1_, address feed0_, address feed1_, uint256 spreadBps_) {
        (token0, token1, feed0, feed1, spreadBps) = (token0_, token1_, feed0_, feed1_, spreadBps_);
    }

    function setSpread(uint256 bps) external {
        spreadBps = bps;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        (uint256 amountIn, uint256 amountOut) = _amounts(zeroForOne, amountSpecified);
        MockStock(tokenOut).mint(recipient, amountOut);

        (amount0, amount1) =
            zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }

    function _amounts(bool zeroForOne, int256 amountSpecified)
        private
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        (address feedIn, address feedOut) = zeroForOne ? (feed0, feed1) : (feed1, feed0);
        // Value of one base unit of each side, scaled so the decimals cancel out.
        uint256 unitIn = _price(feedIn) * 10 ** IERC20Metadata(tokenOut).decimals();
        uint256 unitOut = _price(feedOut) * 10 ** IERC20Metadata(tokenIn).decimals();
        if (amountSpecified > 0) {
            amountIn = uint256(amountSpecified);
            amountOut = Math.mulDiv(amountIn, unitIn * (BPS - spreadBps), unitOut * BPS);
        } else {
            amountOut = uint256(-amountSpecified);
            amountIn = Math.mulDiv(amountOut, unitOut * BPS, unitIn * (BPS - spreadBps), Math.Rounding.Ceil);
        }
    }

    function _price(address feed) private view returns (uint256) {
        (, int256 answer,,,) = IPriceFeed(feed).latestRoundData();
        return uint256(answer);
    }
}
