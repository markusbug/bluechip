// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "./Fixture.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice The fund's side of rebalancing: who may trade holdings, and how that role changes hands.
contract SwapHoldingsTest is Fixture {
    function _swapAsRebalancer(address sell, uint256 amountIn, address buy, uint256 minOut)
        internal
        returns (uint256)
    {
        vm.prank(address(rebalancer));
        return fund.swapHoldings(sell, amountIn, buy, minOut, address(swapper));
    }

    function test_onlyRebalancer() public {
        vm.expectRevert(BlueFund.NotRebalancer.selector);
        vm.prank(owner);
        fund.swapHoldings(tokens[0], 1, tokens[1], 0, address(swapper));
    }

    function test_rebalancerSwaps() public {
        uint256 h0 = fund.holdings(tokens[0]);
        uint256 h1 = fund.holdings(tokens[1]);
        uint256 out = _swapAsRebalancer(tokens[0], h0 / 10, tokens[1], 0);
        assertGt(out, 0);
        assertEq(fund.holdings(tokens[0]), h0 - h0 / 10);
        assertEq(fund.holdings(tokens[1]), h1 + out);
        assertEq(stocks[0].balanceOf(address(fund)), fund.holdings(tokens[0]));
        assertEq(stocks[1].balanceOf(address(fund)), fund.holdings(tokens[1]));
    }

    function test_checksTokensAndAmounts() public {
        address stranger = makeAddr("stranger");
        uint256 h0 = fund.holdings(tokens[0]);
        vm.startPrank(address(rebalancer));

        vm.expectRevert(abi.encodeWithSelector(BlueFund.NotConstituent.selector, stranger));
        fund.swapHoldings(stranger, 1, tokens[1], 0, address(swapper));
        vm.expectRevert(abi.encodeWithSelector(BlueFund.NotConstituent.selector, stranger));
        fund.swapHoldings(tokens[0], 1, stranger, 0, address(swapper));
        vm.expectRevert(BlueFund.SameToken.selector);
        fund.swapHoldings(tokens[0], 1, tokens[0], 0, address(swapper));
        vm.expectRevert(BlueFund.ZeroAmount.selector);
        fund.swapHoldings(tokens[0], 0, tokens[1], 0, address(swapper));
        // A holding can never be emptied.
        vm.expectRevert(BlueFund.ExceedsHoldings.selector);
        fund.swapHoldings(tokens[0], h0, tokens[1], 0, address(swapper));
        vm.stopPrank();
    }

    function test_enforcesMinOut() public {
        uint256 amountIn = fund.holdings(tokens[0]) / 10;
        vm.expectPartialRevert(BlueFund.Slippage.selector);
        _swapAsRebalancer(tokens[0], amountIn, tokens[1], type(uint256).max);
    }

    function test_donationsDuringSwapOnlyHelp() public {
        // Tokens that were already sitting in the fund are not credited as swap output.
        stocks[1].mint(address(fund), 1e8);
        uint256 h1 = fund.holdings(tokens[1]);
        uint256 out = _swapAsRebalancer(tokens[0], 1e6, tokens[1], 0);
        assertEq(fund.holdings(tokens[1]), h1 + out);
        assertEq(stocks[1].balanceOf(address(fund)), fund.holdings(tokens[1]) + 1e8);
    }

    // ------------------------------------------------------------ handing over the role

    function test_rebalancerTimelock() public {
        address next = makeAddr("next");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fund.proposeRebalancer(next);

        vm.expectRevert(BlueFund.NothingPending.selector);
        fund.acceptRebalancer();

        vm.prank(owner);
        fund.proposeRebalancer(next);
        uint256 eta = block.timestamp + 7 days;
        assertEq(fund.pendingRebalancer(), next);
        assertEq(fund.pendingRebalancerEta(), eta);

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(BlueFund.TooEarly.selector, eta));
        fund.acceptRebalancer();

        vm.warp(eta);
        vm.prank(alice); // anyone
        fund.acceptRebalancer();
        assertEq(fund.rebalancer(), next);
        assertEq(fund.pendingRebalancer(), address(0));
        assertEq(fund.pendingRebalancerEta(), 0);

        // The old rebalancer lost the role.
        vm.expectRevert(BlueFund.NotRebalancer.selector);
        _swapAsRebalancer(tokens[0], 1, tokens[1], 0);
    }

    function test_cancelRebalancer() public {
        vm.expectRevert(BlueFund.NothingPending.selector);
        vm.prank(owner);
        fund.cancelRebalancer();

        vm.prank(owner);
        fund.proposeRebalancer(alice);
        vm.prank(owner);
        fund.cancelRebalancer();
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BlueFund.NothingPending.selector);
        fund.acceptRebalancer();
        assertEq(fund.rebalancer(), address(rebalancer));
    }

    function test_disableIsImmediate() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fund.disableRebalancer();

        vm.prank(owner);
        fund.disableRebalancer();
        assertEq(fund.rebalancer(), address(0));
        vm.expectRevert(BlueFund.NotRebalancer.selector);
        _swapAsRebalancer(tokens[0], 1, tokens[1], 0);

        // Mint and redeem are unaffected.
        _mintAs(alice, 1e18);
        uint256 bal = fund.balanceOf(alice);
        vm.prank(alice);
        fund.redeem(bal, alice);
    }
}
