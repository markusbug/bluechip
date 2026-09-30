// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";

/// @notice Swaps one stock for another through each one's USDC pool on Aerodrome Slipstream:
///         stock -> USDC -> stock, in one call. With USDC on either side it is a single hop
///         (stock -> USDC for the CHIP burner). It has no owner, holds nothing between calls and
///         checks no price; the caller enforces its own minimum output.
/// @dev    Talks to the pools directly (no router), so the only external code it trusts is the pool
///         set fixed at deployment. Anyone may call `swap`, but only with tokens they sent in first.
contract AerodromeSwapper is ISwapper {
    using SafeERC20 for IERC20;

    /// @dev TickMath.MIN_SQRT_RATIO + 1 and MAX_SQRT_RATIO - 1: no price limit, `minOut` protects.
    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    address public immutable usdc;
    mapping(address token => address pool) public poolOf;

    /// @dev The pool whose callback is expected right now.
    address private transient _activePool;

    error BadPool(address pool);
    error NoPool(address token);
    error UnexpectedCallback();

    constructor(address usdc_, address[] memory tokens, address[] memory pools) {
        if (tokens.length != pools.length) revert BadPool(address(0));
        usdc = usdc_;
        for (uint256 i; i < tokens.length; ++i) {
            ICLPool pool = ICLPool(pools[i]);
            (address t0, address t1) = (pool.token0(), pool.token1());
            if (!((t0 == usdc_ && t1 == tokens[i]) || (t1 == usdc_ && t0 == tokens[i]))) {
                revert BadPool(pools[i]);
            }
            poolOf[tokens[i]] = pools[i];
        }
    }

    function swap(address sell, address buy, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut)
    {
        if (buy == usdc) return _swap(sell, amountIn, sell, recipient);
        if (sell == usdc) return _swap(buy, amountIn, usdc, recipient);
        uint256 usdcOut = _swap(sell, amountIn, sell, address(this));
        amountOut = _swap(buy, usdcOut, usdc, recipient);
    }

    /// @dev Exact-input swap of `amountIn` of `tokenIn` in `stock`'s USDC pool.
    function _swap(address stock, uint256 amountIn, address tokenIn, address recipient)
        private
        returns (uint256 amountOut)
    {
        address pool = poolOf[stock];
        if (pool == address(0)) revert NoPool(stock);
        bool zeroForOne = tokenIn == ICLPool(pool).token0();
        _activePool = pool;
        (int256 amount0, int256 amount1) = ICLPool(pool).swap(
            recipient,
            zeroForOne,
            SafeCast.toInt256(amountIn),
            zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
            abi.encode(tokenIn)
        );
        _activePool = address(0);
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @notice Pays the pool the input it asks for. Only the pool of the swap in progress may call.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _activePool) revert UnexpectedCallback();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }
}
