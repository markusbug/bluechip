// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "./interfaces/IPoolManager.sol";

/// @notice Buys $CHIP with USDC: USDC -> WETH in an Aerodrome Slipstream pool, then WETH -> CHIP in
///         CHIP's Uniswap v4 pool (the one Bankr launched it into, hook and all). Only that route.
///         It has no owner, holds nothing between calls and checks no price; the burner enforces
///         the minimum output.
/// @dev    Talks to the pools directly (no router): the Slipstream pool through its swap callback,
///         the v4 pool through `PoolManager.unlock`.
contract ChipSwapper is ISwapper, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    address public immutable usdc;
    address public immutable weth;
    address public immutable chip;
    ICLPool public immutable usdcWethPool;
    IPoolManager public immutable poolManager;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hooks;

    address private transient _inCallback;

    error BadPool(address pool);
    error BadRoute(address sell, address buy);
    error UnexpectedCallback();

    /// @param fee_, tickSpacing_, hooks_ CHIP's v4 pool key besides the two currencies
    ///        (scripts/chip-pool.mjs reads them from the pool's creation).
    constructor(
        address usdc_,
        address weth_,
        address chip_,
        ICLPool usdcWethPool_,
        IPoolManager poolManager_,
        uint24 fee_,
        int24 tickSpacing_,
        address hooks_
    ) {
        (address t0, address t1) = (usdcWethPool_.token0(), usdcWethPool_.token1());
        if (!((t0 == usdc_ && t1 == weth_) || (t0 == weth_ && t1 == usdc_))) {
            revert BadPool(address(usdcWethPool_));
        }
        usdc = usdc_;
        weth = weth_;
        chip = chip_;
        usdcWethPool = usdcWethPool_;
        poolManager = poolManager_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        hooks = hooks_;
    }

    /// @notice Swap `amountIn` USDC, already transferred here, for CHIP sent to `recipient`.
    function swap(address sell, address buy, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut)
    {
        if (sell != usdc || buy != chip) revert BadRoute(sell, buy);
        uint256 wethOut = _swapUsdcForWeth(amountIn);
        amountOut = abi.decode(poolManager.unlock(abi.encode(wethOut, recipient)), (uint256));
    }

    function poolKey() public view returns (PoolKey memory key) {
        (address c0, address c1) = weth < chip ? (weth, chip) : (chip, weth);
        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
    }

    // ---------------------------------------------------------------- USDC -> WETH (Slipstream)

    function _swapUsdcForWeth(uint256 amountIn) private returns (uint256) {
        bool zeroForOne = usdcWethPool.token0() == usdc;
        _inCallback = address(usdcWethPool);
        (int256 amount0, int256 amount1) = usdcWethPool.swap(
            address(this),
            zeroForOne,
            SafeCast.toInt256(amountIn),
            zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
            ""
        );
        _inCallback = address(0);
        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _inCallback) revert UnexpectedCallback();
        IERC20(usdc).safeTransfer(msg.sender, uint256(amount0Delta > 0 ? amount0Delta : amount1Delta));
    }

    // ---------------------------------------------------------------- WETH -> CHIP (Uniswap v4)

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnexpectedCallback();
        (uint256 amountIn, address recipient) = abi.decode(data, (uint256, address));
        PoolKey memory key = poolKey();
        bool zeroForOne = key.currency0 == weth;

        int256 delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        (int128 paid, int128 received) = zeroForOne ? (amount0, amount1) : (amount1, amount0);

        poolManager.sync(weth);
        IERC20(weth).safeTransfer(address(poolManager), uint256(uint128(-paid)));
        poolManager.settle();
        poolManager.take(chip, recipient, uint256(uint128(received)));
        return abi.encode(uint256(uint128(received)));
    }
}
