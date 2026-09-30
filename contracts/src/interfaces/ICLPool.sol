// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The subset of an Aerodrome Slipstream (Uniswap v3 style) concentrated-liquidity pool the
///         swapper uses. The pool calls `uniswapV3SwapCallback` on the caller to collect the input.
interface ICLPool {
    function token0() external view returns (address);
    function token1() external view returns (address);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
