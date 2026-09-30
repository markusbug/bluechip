// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BlueFund} from "./BlueFund.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title MintZap
/// @notice Mint $BLUE with USDC or ETH instead of the stocks: buys exactly the basket a mint of
///         `shares` deposits, each stock in its USDC pool on Aerodrome Slipstream (exact-output
///         swaps), then mints. The buyer pays only what the pools ask, never more than their maximum.
///         `quoteMint` gives the price to set that maximum from.
/// @dev    No owner, holds nothing between calls and checks no price: the buyer's maximum is the
///         only slippage protection. USDC goes from the buyer straight to each pool in its swap
///         callback. ETH is wrapped, and each stock's USDC is bought with WETH inside that callback
///         (a nested exact-output swap in the USDC/WETH pool); the unspent ETH is refunded.
///         Like the fund, the constructor never calls the stock tokens.
contract MintZap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev TickMath.MIN_SQRT_RATIO + 1 and MAX_SQRT_RATIO - 1: no price limit, the maximum protects.
    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    BlueFund public immutable fund;
    address public immutable usdc;
    IWETH public immutable weth;
    /// @notice The USDC/WETH pool the ETH route buys its USDC in.
    ICLPool public immutable wethPool;
    /// @notice Each constituent's USDC pool.
    mapping(address token => address pool) public poolOf;

    /// @dev The pool whose callback is expected right now.
    address private transient _activePool;
    /// @dev Who pays for the swaps in progress: the buyer's USDC, or this contract's WETH.
    address private transient _payer;
    /// @dev What the swaps have cost so far, and the most they may cost (USDC, or WETH for ETH).
    uint256 private transient _spent;
    uint256 private transient _maxIn;
    /// @dev Inside `quoteMint`: every callback reverts with what it was asked to pay.
    bool private transient _quoting;

    event ZapMinted(
        address indexed buyer, address indexed to, uint256 shares, address payToken, uint256 amountIn
    );

    error BadPool(address pool);
    error Expired();
    error PartialFill(address token);
    error Slippage(uint256 amountIn, uint256 maxIn);
    error UnexpectedCallback();
    error RefundFailed();
    /// @dev Only ever raised inside `quoteMint`, which catches it.
    error Quote(uint256 amountIn);

    /// @param pools Each constituent's USDC pool, in the order of `fund.constituents()`.
    constructor(BlueFund fund_, address usdc_, IWETH weth_, ICLPool wethPool_, address[] memory pools) {
        address[] memory tokens = fund_.constituents();
        if (pools.length != tokens.length) revert BadPool(address(0));
        if (!_pairs(wethPool_, usdc_, address(weth_))) revert BadPool(address(wethPool_));
        for (uint256 i; i < tokens.length; ++i) {
            if (!_pairs(ICLPool(pools[i]), usdc_, tokens[i])) revert BadPool(pools[i]);
            poolOf[tokens[i]] = pools[i];
        }
        fund = fund_;
        usdc = usdc_;
        weth = weth_;
        wethPool = wethPool_;
    }

    // ---------------------------------------------------------------- mint

    /// @notice Buy the basket for `shares` with the caller's USDC (approved to this contract) and
    ///         mint them to `to`, minus the fund's mint fee. Spends at most `maxUsdcIn`.
    function mintWithUsdc(uint256 shares, address to, uint256 maxUsdcIn, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcIn)
    {
        return _mintWithUsdc(shares, to, maxUsdcIn, deadline);
    }

    /// @notice `mintWithUsdc` for wallets that can't batch an approval: `permit` is an EIP-2612
    ///         signature for USDC. A failed permit is ignored (it may have been front-run); the
    ///         allowance still has to be there.
    function mintWithUsdcPermit(
        uint256 shares,
        address to,
        uint256 maxUsdcIn,
        uint256 deadline,
        BlueFund.Permit calldata permit
    ) external nonReentrant returns (uint256 usdcIn) {
        try IERC20Permit(usdc).permit(
            msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s
        ) {} catch {}
        return _mintWithUsdc(shares, to, maxUsdcIn, deadline);
    }

    /// @notice Buy the basket for `shares` with ETH and mint them to `to`, minus the fund's mint fee.
    ///         Spends at most `msg.value` and refunds the rest to the caller.
    function mintWithEth(uint256 shares, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 ethIn)
    {
        weth.deposit{value: msg.value}();
        _payer = address(this);
        ethIn = _buyAndMint(shares, to, msg.value, deadline);
        uint256 refund = msg.value - ethIn;
        if (refund != 0) {
            weth.withdraw(refund);
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
        emit ZapMinted(msg.sender, to, shares, address(weth), ethIn);
    }

    function _mintWithUsdc(uint256 shares, address to, uint256 maxUsdcIn, uint256 deadline)
        private
        returns (uint256 usdcIn)
    {
        _payer = msg.sender;
        usdcIn = _buyAndMint(shares, to, maxUsdcIn, deadline);
        emit ZapMinted(msg.sender, to, shares, usdc, usdcIn);
    }

    /// @dev Buys what `fund.mint(shares)` will pull (less anything already here), then mints.
    ///      Nothing can move the fund between the preview and the mint, so the amounts match exactly.
    function _buyAndMint(uint256 shares, address to, uint256 maxIn, uint256 deadline)
        private
        returns (uint256 spent)
    {
        if (block.timestamp > deadline) revert Expired();
        // Transient storage lasts the whole transaction: start from zero on every mint.
        _spent = 0;
        _maxIn = maxIn;
        (address[] memory tokens, uint256[] memory amounts) = fund.previewMint(shares);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 t = IERC20(tokens[i]);
            uint256 have = t.balanceOf(address(this));
            if (amounts[i] > have) {
                uint256 want = amounts[i] - have;
                if (_swapExactOut(ICLPool(poolOf[tokens[i]]), usdc, want, address(this)) < want) {
                    revert PartialFill(tokens[i]);
                }
            }
            if (t.allowance(address(this), address(fund)) < amounts[i]) {
                t.forceApprove(address(fund), type(uint256).max);
            }
        }
        fund.mint(shares, to);
        spent = _spent;
    }

    // ---------------------------------------------------------------- swaps

    /// @dev Swap `tokenIn` in `pool` for exactly `amountOut` of the other token, sent to `recipient`.
    ///      Returns what the pool says it sent (less than asked only if it ran out of liquidity).
    function _swapExactOut(ICLPool pool, address tokenIn, uint256 amountOut, address recipient)
        private
        returns (uint256 received)
    {
        bool zeroForOne = tokenIn == pool.token0();
        address outer = _activePool;
        _activePool = address(pool);
        (int256 amount0, int256 amount1) = pool.swap(
            recipient,
            zeroForOne,
            -SafeCast.toInt256(amountOut),
            zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
            ""
        );
        _activePool = outer;
        received = uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @notice Pays the pool the input it asks for. Only the pool of the swap in progress may call.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _activePool) revert UnexpectedCallback();
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (_quoting) revert Quote(owed);

        if (msg.sender == address(wethPool)) {
            // The ETH route's USDC, bought inside a stock swap: pay with the wrapped ETH.
            _charge(owed);
            IERC20(address(weth)).safeTransfer(msg.sender, owed);
        } else if (_payer == address(this)) {
            // A stock swap on the ETH route: buy the USDC it owes, delivered straight to its pool.
            if (_swapExactOut(wethPool, address(weth), owed, msg.sender) < owed) revert PartialFill(usdc);
        } else {
            _charge(owed);
            IERC20(usdc).safeTransferFrom(_payer, msg.sender, owed);
        }
    }

    function _charge(uint256 amount) private {
        uint256 spent = _spent + amount;
        if (spent > _maxIn) revert Slippage(spent, _maxIn);
        _spent = spent;
    }

    // ---------------------------------------------------------------- quote

    /// @notice What minting `shares` costs at current pool prices, in USDC and in ETH, before
    ///         slippage. Not a view: it simulates each swap and reverts it, so call it with eth_call.
    function quoteMint(uint256 shares) external nonReentrant returns (uint256 usdcIn, uint256 ethIn) {
        (address[] memory tokens, uint256[] memory amounts) = fund.previewMint(shares);
        _quoting = true;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 have = IERC20(tokens[i]).balanceOf(address(this));
            if (amounts[i] > have) {
                usdcIn += _quoteExactOut(ICLPool(poolOf[tokens[i]]), usdc, amounts[i] - have);
            }
        }
        // One swap for the total costs what the mint's separate swaps in the same pool cost, up to rounding.
        if (usdcIn != 0) ethIn = _quoteExactOut(wethPool, address(weth), usdcIn);
        _quoting = false;
    }

    function _quoteExactOut(ICLPool pool, address tokenIn, uint256 amountOut) private returns (uint256) {
        bool zeroForOne = tokenIn == pool.token0();
        _activePool = address(pool);
        try pool.swap(
            address(this),
            zeroForOne,
            -SafeCast.toInt256(amountOut),
            zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
            ""
        ) {
            revert UnexpectedCallback();
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != Quote.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            _activePool = address(0);
            uint256 amountIn;
            assembly ("memory-safe") {
                amountIn := mload(add(reason, 36))
            }
            return amountIn;
        }
    }

    // ---------------------------------------------------------------- misc

    /// @dev Only WETH sends ETH here, when the ETH route unwraps a refund.
    receive() external payable {
        if (msg.sender != address(weth)) revert UnexpectedCallback();
    }

    function _pairs(ICLPool pool, address a, address b) private view returns (bool) {
        (address t0, address t1) = (pool.token0(), pool.token1());
        return (t0 == a && t1 == b) || (t0 == b && t1 == a);
    }
}
