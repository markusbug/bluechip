// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IChip} from "./interfaces/IChip.sol";

/// @title ChipVault
/// @notice Collects the $BLUE mint fees and backs $CHIP with them. Burn CHIP here to claim your
///         pro-rata share of the vault's $BLUE: `blue * amount / chip.totalSupply()`.
///         Every mint adds BLUE and every claim burns CHIP at the current ratio, so the backing
///         per CHIP never goes down.
/// @dev    No owner, no upgrade path, no way for BLUE to leave except through `claim`.
contract ChipVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IChip;

    IERC20 public immutable blue;
    IChip public immutable chip;

    event Claimed(address indexed by, address indexed to, uint256 chipBurned, uint256 blueOut);

    error ZeroAddress();
    error ZeroAmount();
    error Slippage(uint256 out, uint256 minOut);

    constructor(IERC20 blue_, IChip chip_) {
        if (address(blue_) == address(0) || address(chip_) == address(0)) revert ZeroAddress();
        blue = blue_;
        chip = chip_;
    }

    /// @notice Burn `amount` CHIP (needs an allowance) and send the backing $BLUE to `to`.
    function claim(uint256 amount, uint256 minBlueOut, address to)
        external
        nonReentrant
        returns (uint256 out)
    {
        return _claim(amount, minBlueOut, to);
    }

    /// @notice `claim` in one transaction, using CHIP's EIP-2612 permit instead of an approval.
    /// @dev    A failed permit is ignored (it may have been front-run); `transferFrom` still needs
    ///         the allowance to be there.
    function claimWithPermit(
        uint256 amount,
        uint256 minBlueOut,
        address to,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 out) {
        try chip.permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        return _claim(amount, minBlueOut, to);
    }

    function _claim(uint256 amount, uint256 minBlueOut, address to) private returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        out = previewClaim(amount);
        if (out == 0 || out < minBlueOut) revert Slippage(out, minBlueOut);

        chip.safeTransferFrom(msg.sender, address(this), amount);
        // Burns anything else sitting here too; that only raises everyone's backing.
        chip.burn(chip.balanceOf(address(this)));
        blue.safeTransfer(to, out);
        emit Claimed(msg.sender, to, amount, out);
    }

    /// @notice $BLUE paid for burning `amount` CHIP right now.
    function previewClaim(uint256 amount) public view returns (uint256) {
        uint256 supply = chip.totalSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(blue.balanceOf(address(this)), amount, supply);
    }

    /// @notice $BLUE (in wei) backing one whole CHIP (1e18 units).
    function backingPerChip() external view returns (uint256) {
        return previewClaim(1e18);
    }

    function totalBacking() external view returns (uint256) {
        return blue.balanceOf(address(this));
    }
}
