// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipVault} from "../src/ChipVault.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockChip} from "../src/mocks/MockChip.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Three-stock fund (two 8-decimal tokens like the real B20 stocks, one 18-decimal) + CHIP vault.
abstract contract Fixture is Test {
    BlueFund internal fund;
    ChipVault internal vault;
    MockChip internal chip;
    MockStock[] internal stocks;
    address[] internal tokens;
    uint256[] internal units;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant FEE_BPS = 30;
    uint256 internal constant CAP = 1_000_000e18;
    uint256 internal constant SEED = 10e18;

    function setUp() public virtual {
        stocks.push(new MockStock("NVIDIA", "NVDAc", 8));
        stocks.push(new MockStock("Apple", "AAPLc", 8));
        stocks.push(new MockStock("Wide", "WIDE", 18));
        for (uint256 i; i < stocks.length; ++i) {
            tokens.push(address(stocks[i]));
        }
        units.push(10_139_000); // 0.10139 NVDA per BLUE
        units.push(6_192_345); // 0.06192345 AAPL per BLUE
        units.push(3.3e16); // 0.033 WIDE per BLUE

        chip = new MockChip(owner);
        // Fee recipient is the vault, whose address depends on the fund: predict it.
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        fund = new BlueFund("Bluechip Index", "BLUE", tokens, units, owner, predictedVault, FEE_BPS, CAP);
        vault = new ChipVault(IERC20(address(fund)), IChip(address(chip)));
        assertEq(address(vault), predictedVault);

        _fundBasket(owner, SEED);
        vm.startPrank(owner);
        _approveAll(address(fund));
        fund.seed(SEED);
        vm.stopPrank();
    }

    /// @dev Mint enough of every stock to `who` to mint `shares`, plus a little slack.
    function _fundBasket(address who, uint256 shares) internal {
        (, uint256[] memory amounts) = fund.previewMint(shares);
        for (uint256 i; i < stocks.length; ++i) {
            stocks[i].mint(who, amounts[i] + 10);
        }
    }

    /// @dev Call inside a prank.
    function _approveAll(address spender) internal {
        for (uint256 i; i < stocks.length; ++i) {
            stocks[i].approve(spender, type(uint256).max);
        }
    }

    function _mintAs(address who, uint256 shares) internal returns (uint256[] memory deposited) {
        _fundBasket(who, shares);
        vm.startPrank(who);
        _approveAll(address(fund));
        deposited = fund.mint(shares, who);
        vm.stopPrank();
    }
}
