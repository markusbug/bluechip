// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BlueFund} from "./BlueFund.sol";
import {IChip} from "./interfaces/IChip.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/// @title ChipBurner
/// @notice Receives the $BLUE mint fees and turns them into burned $CHIP: redeem the BLUE for the
///         stocks, sell them for USDC, buy CHIP, burn it.
///         Only the `keeper` can run a burn, because it sets the minimum CHIP out: CHIP has no price
///         feed, so an open trigger could be sandwiched. A keeper can only get a bad price on one
///         burn; nothing it does can move the fees anywhere but into burned CHIP.
/// @dev    The swappers are fixed at deployment. Changing the route means a new burner and
///         `fund.setFeeRecipient`, which the fund owner could do anyway.
contract ChipBurner is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    BlueFund public immutable fund;
    IChip public immutable chip;
    address public immutable usdc;
    /// @notice Sells a constituent for USDC.
    ISwapper public immutable stockSwapper;
    /// @notice Buys CHIP with USDC.
    ISwapper public immutable chipSwapper;

    address public keeper;
    /// @notice All CHIP this contract has burned.
    uint256 public totalBurned;

    event Burned(uint256 blueRedeemed, uint256 usdcSpent, uint256 chipBurned);
    event KeeperSet(address keeper);

    error NotKeeper();
    error ZeroAmount();
    error Slippage(uint256 out, uint256 minOut);

    constructor(
        BlueFund fund_,
        IChip chip_,
        address usdc_,
        ISwapper stockSwapper_,
        ISwapper chipSwapper_,
        address owner_,
        address keeper_
    ) Ownable(owner_) {
        fund = fund_;
        chip = chip_;
        usdc = usdc_;
        stockSwapper = stockSwapper_;
        chipSwapper = chipSwapper_;
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Redeem `blueAmount` of the fee BLUE, sell the stocks, buy at least `minChipOut` CHIP
    ///         and burn it. `skip` leaves frozen constituents in the fund (see `redeemExcept`).
    function burn(uint256 blueAmount, uint256 minChipOut, address[] calldata skip)
        external
        nonReentrant
        returns (uint256 burned)
    {
        if (msg.sender != keeper) revert NotKeeper();
        if (blueAmount == 0) revert ZeroAmount();

        uint256[] memory paid = skip.length == 0
            ? fund.redeem(blueAmount, address(this))
            : fund.redeemExcept(blueAmount, address(this), skip);
        address[] memory tokens = fund.constituents();
        for (uint256 i; i < tokens.length; ++i) {
            if (paid[i] == 0) continue;
            IERC20(tokens[i]).safeTransfer(address(stockSwapper), paid[i]);
            stockSwapper.swap(tokens[i], usdc, paid[i], address(this));
        }

        uint256 usdcSpent = IERC20(usdc).balanceOf(address(this));
        uint256 chipBefore = chip.balanceOf(address(this));
        IERC20(usdc).safeTransfer(address(chipSwapper), usdcSpent);
        chipSwapper.swap(usdc, address(chip), usdcSpent, address(this));
        uint256 bought = chip.balanceOf(address(this)) - chipBefore;
        if (bought < minChipOut) revert Slippage(bought, minChipOut);

        // Anything else sitting here is CHIP too: burn it all.
        burned = chip.balanceOf(address(this));
        chip.burn(burned);
        totalBurned += burned;
        emit Burned(blueAmount, usdcSpent, burned);
    }

    /// @notice Fee BLUE waiting to be burned.
    function pendingBlue() external view returns (uint256) {
        return fund.balanceOf(address(this));
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }
}
