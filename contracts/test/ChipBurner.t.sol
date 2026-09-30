// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "./Fixture.sol";
import {ChipBurner} from "../src/ChipBurner.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ChipBurnerTest is Fixture {
    function _pending() internal view returns (uint256) {
        return burner.pendingBlue();
    }

    function test_feesAccrueToTheBurner() public {
        assertEq(fund.feeRecipient(), address(burner));
        _mintAs(alice, 100e18);
        assertEq(_pending(), 100e18 * FEE_BPS / 10_000);
    }

    function test_burnBuysAndBurnsChip() public {
        _mintAs(alice, 1_000e18);
        uint256 pending = _pending();
        uint256 supply = chip.totalSupply();
        uint256 nav = _nav();
        uint256 supplyBlue = fund.totalSupply();

        vm.prank(keeper);
        uint256 burned = burner.burn(pending, 0, new address[](0));

        assertGt(burned, 0);
        assertEq(chip.totalSupply(), supply - burned);
        assertEq(burner.totalBurned(), burned);
        assertEq(_pending(), 0);
        // The fee's USD value, less the mock DEX's 0.3% on the stock sale, bought CHIP at $0.01.
        uint256 feeUsd = nav * pending / supplyBlue;
        uint256 expectedChip = feeUsd * (10_000 - DEX_SLIPPAGE_BPS) / 10_000 * 100;
        assertApproxEqRel(burned, expectedChip, 0.001e18);
        // Nothing is left behind.
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(stocks[i].balanceOf(address(burner)), 0);
        }
        assertEq(usdc.balanceOf(address(burner)), 0);
        assertEq(chip.balanceOf(address(burner)), 0);
    }

    function test_burnsPartOfThePending() public {
        _mintAs(alice, 1_000e18);
        uint256 pending = _pending();
        vm.prank(keeper);
        burner.burn(pending / 2, 0, new address[](0));
        assertEq(_pending(), pending - pending / 2);
    }

    function test_burnsStrayChipToo() public {
        _mintAs(alice, 1_000e18);
        vm.prank(owner);
        chip.transfer(address(burner), 5e18);
        uint256 supply = chip.totalSupply();
        uint256 pending = _pending();
        vm.prank(keeper);
        uint256 burned = burner.burn(pending, 0, new address[](0));
        assertEq(chip.totalSupply(), supply - burned);
        assertEq(chip.balanceOf(address(burner)), 0);
    }

    function test_onlyKeeper() public {
        _mintAs(alice, 1_000e18);
        uint256 pending = _pending();
        vm.expectRevert(ChipBurner.NotKeeper.selector);
        vm.prank(owner);
        burner.burn(pending, 0, new address[](0));
    }

    function test_revertsOnZero() public {
        vm.expectRevert(ChipBurner.ZeroAmount.selector);
        vm.prank(keeper);
        burner.burn(0, 0, new address[](0));
    }

    function test_enforcesMinChipOut() public {
        _mintAs(alice, 1_000e18);
        uint256 pending = _pending();
        vm.expectPartialRevert(ChipBurner.Slippage.selector);
        vm.prank(keeper);
        burner.burn(pending, type(uint256).max, new address[](0));
    }

    function test_skipsAFrozenStock() public {
        _mintAs(alice, 1_000e18);
        uint256 pending = _pending();
        stocks[1].setFrozen(true);

        vm.expectRevert("MockStock: frozen");
        vm.prank(keeper);
        burner.burn(pending, 0, new address[](0));

        // Leave it behind: its share stays in the fund, the rest is burned.
        address[] memory skip = new address[](1);
        skip[0] = tokens[1];
        uint256 supply = chip.totalSupply();
        vm.prank(keeper);
        uint256 burned = burner.burn(pending, 0, skip);
        assertGt(burned, 0);
        assertEq(chip.totalSupply(), supply - burned);
    }

    function test_setKeeper() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        burner.setKeeper(alice);

        vm.prank(owner);
        burner.setKeeper(alice);
        assertEq(burner.keeper(), alice);

        _mintAs(bob, 1_000e18);
        uint256 pending = _pending();
        vm.expectRevert(ChipBurner.NotKeeper.selector);
        vm.prank(keeper);
        burner.burn(pending, 0, new address[](0));
        vm.prank(alice);
        burner.burn(pending, 0, new address[](0));
    }

    function test_wiring() public view {
        assertEq(address(burner.fund()), address(fund));
        assertEq(address(burner.chip()), address(chip));
        assertEq(burner.usdc(), address(usdc));
        assertEq(address(burner.stockSwapper()), address(swapper));
        assertEq(address(burner.chipSwapper()), address(chipSwapper));
        assertEq(burner.owner(), owner);
        assertEq(burner.keeper(), keeper);
    }
}
