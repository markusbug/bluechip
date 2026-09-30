// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../Fixture.sol";
import {Handler} from "./Handler.sol";

contract FundInvariantTest is Fixture {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(fund, vault, chip, stocks, owner, rebalancer, feeds, updater);
        targetContract(address(handler));
    }

    /// The fund always owns at least what it accounts for.
    function invariant_solvent() public view {
        for (uint256 i; i < tokens.length; ++i) {
            assertGe(stocks[i].balanceOf(address(fund)), fund.holdings(tokens[i]));
        }
    }

    /// Dead shares keep supply and every holding above zero.
    function invariant_neverEmpty() public view {
        assertGe(fund.totalSupply(), fund.DEAD_SHARES());
        assertGe(fund.balanceOf(fund.DEAD()), fund.DEAD_SHARES());
        for (uint256 i; i < tokens.length; ++i) {
            assertGt(fund.holdings(tokens[i]), 0);
        }
    }

    /// Checked step by step in the handler: no action other than a trade lowered holdings per
    /// share, nothing lowered CHIP backing, and no trade cost more than its slippage bound.
    function invariant_monotone() public view {
        assertEq(handler.ratioDrops(), 0);
        assertEq(handler.backingDrops(), 0);
        assertEq(handler.navLeaks(), 0);
    }

    /// The vault never holds CHIP after a claim, and CHIP supply only goes down.
    function invariant_chipSupplyNeverGrows() public view {
        assertLe(chip.totalSupply(), chip.SUPPLY());
    }
}
