// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IPoolManager.sol";

/// @notice A Uniswap v4 PoolManager with one fixed-price pool: unlock -> callback, swap records a
///         delta, sync/settle/take move tokens, and unlock reverts unless every delta was cleared.
///         `price1Per0` is currency1 base units per 1e18 currency0 base units. Exact input only.
contract MockPoolManager is IPoolManager {
    uint256 public price1Per0;
    PoolKey public expected;
    /// @dev Test hook: a fee the "hook" keeps out of the output.
    uint256 public hookFeeBps;

    bool private _unlocked;
    address private _synced;
    uint256 private _syncedBalance;
    mapping(address currency => int256) private _delta;

    constructor(PoolKey memory key, uint256 price1Per0_) {
        expected = key;
        price1Per0 = price1Per0_;
    }

    function setHookFee(uint256 bps) external {
        hookFeeBps = bps;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(_delta[expected.currency0] == 0 && _delta[expected.currency1] == 0, "CurrencyNotSettled");
        _unlocked = false;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256) {
        require(_unlocked, "ManagerLocked");
        require(keccak256(abi.encode(key)) == keccak256(abi.encode(expected)), "wrong pool");
        require(params.amountSpecified < 0, "exact input only");
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 out = params.zeroForOne ? amountIn * price1Per0 / 1e18 : amountIn * 1e18 / price1Per0;
        out -= out * hookFeeBps / 10_000;
        (address tokenIn, address tokenOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _delta[tokenIn] -= int256(amountIn);
        _delta[tokenOut] += int256(out);
        (int128 a0, int128 a1) = params.zeroForOne
            ? (-int128(int256(amountIn)), int128(int256(out)))
            : (int128(int256(out)), -int128(int256(amountIn)));
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    function sync(address currency) external {
        _synced = currency;
        _syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedBalance;
        _delta[_synced] += int256(paid);
        _synced = address(0);
    }

    function take(address currency, address to, uint256 amount) external {
        _delta[currency] -= int256(amount);
        IERC20(currency).transfer(to, amount);
    }
}
