// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICLPool} from "../../src/interfaces/ICLPool.sol";

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice A Slipstream-shaped pool with a fixed price: sends the output first, then calls back for
///         the input and checks it arrived, like the real pool. Exact input only.
///         `price1Per0` is token1 base units per 1e18 token0 base units.
contract MockCLPool is ICLPool {
    address public immutable token0;
    address public immutable token1;
    uint256 public price1Per0;
    /// @dev Test hook: ask the callback for more than was specified.
    uint256 public overcharge;

    constructor(address token0_, address token1_, uint256 price1Per0_) {
        token0 = token0_;
        token1 = token1_;
        price1Per0 = price1Per0_;
    }

    function setOvercharge(uint256 amount) external {
        overcharge = amount;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact input only");
        uint256 amountIn = uint256(amountSpecified) + overcharge;
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        uint256 out = zeroForOne ? amountIn * price1Per0 / 1e18 : amountIn * 1e18 / price1Per0;
        IERC20(tokenOut).transfer(recipient, out);

        (amount0, amount1) = zeroForOne ? (int256(amountIn), -int256(out)) : (-int256(out), int256(amountIn));
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }
}
