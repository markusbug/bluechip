// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "./Fixture.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {MockStock} from "../src/mocks/MockStock.sol";

/// EOA wallets (MetaMask, Rabby) can't batch approvals: they sign one permit per constituent and
/// send a single transaction.
contract MintWithPermitsTest is Fixture {
    uint256 internal daveKey = 0xDA7E;
    address internal dave = vm.addr(daveKey);

    function test_mintWithPermits_noPriorApprovals() public {
        uint256 shares = 2e18;
        _fundBasket(dave, shares);
        BlueFund.Permit[] memory permits = _signAll(type(uint256).max, block.timestamp + 1 hours);

        vm.prank(dave);
        fund.mintWithPermits(shares, dave, permits);

        assertEq(fund.balanceOf(dave), shares - shares * FEE_BPS / 10_000);
        // Unlimited permits: the next mint needs no signatures at all.
        _fundBasket(dave, 1e18);
        vm.prank(dave);
        fund.mint(1e18, dave);
    }

    function test_mintWithPermits_skipsAlreadyApproved() public {
        uint256 shares = 1e18;
        _fundBasket(dave, shares);
        (, uint256[] memory need) = fund.previewMint(shares);
        vm.prank(dave);
        stocks[0].approve(address(fund), need[0]);

        BlueFund.Permit[] memory permits = _signAll(type(uint256).max, block.timestamp + 1 hours);
        permits[0].deadline = 0; // no permit for the approved token

        vm.prank(dave);
        fund.mintWithPermits(shares, dave, permits);
        assertGt(fund.balanceOf(dave), 0);
    }

    function test_mintWithPermits_exactValues() public {
        uint256 shares = 1e18;
        _fundBasket(dave, shares);
        (, uint256[] memory need) = fund.previewMint(shares);
        BlueFund.Permit[] memory permits = new BlueFund.Permit[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            permits[i] = _sign(stocks[i], need[i], block.timestamp + 1 hours);
        }
        vm.prank(dave);
        fund.mintWithPermits(shares, dave, permits);
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(stocks[i].allowance(dave, address(fund)), 0);
        }
    }

    function test_mintWithPermits_survivesFrontRun() public {
        uint256 shares = 1e18;
        _fundBasket(dave, shares);
        BlueFund.Permit[] memory permits = _signAll(type(uint256).max, block.timestamp + 1 hours);
        // Someone submits one of the permits first; the mint must still go through.
        BlueFund.Permit memory p = permits[1];
        stocks[1].permit(dave, address(fund), p.value, p.deadline, p.v, p.r, p.s);

        vm.prank(dave);
        fund.mintWithPermits(shares, dave, permits);
        assertGt(fund.balanceOf(dave), 0);
    }

    function test_mintWithPermits_badPermitFailsOnPull() public {
        _fundBasket(dave, 1e18);
        BlueFund.Permit[] memory permits = _signAll(type(uint256).max, block.timestamp + 1 hours);
        permits[2].r = bytes32(uint256(1)); // corrupt: ignored, then the pull has no allowance
        vm.prank(dave);
        vm.expectRevert();
        fund.mintWithPermits(1e18, dave, permits);
    }

    function test_mintWithPermits_lengthMismatch() public {
        BlueFund.Permit[] memory permits = new BlueFund.Permit[](1);
        vm.expectRevert(BlueFund.LengthMismatch.selector);
        fund.mintWithPermits(1e18, dave, permits);
    }

    function _signAll(uint256 value, uint256 deadline)
        internal
        view
        returns (BlueFund.Permit[] memory permits)
    {
        permits = new BlueFund.Permit[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            permits[i] = _sign(stocks[i], value, deadline);
        }
    }

    function _sign(MockStock token, uint256 value, uint256 deadline)
        internal
        view
        returns (BlueFund.Permit memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                dave,
                address(fund),
                value,
                token.nonces(dave),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(daveKey, digest);
        return BlueFund.Permit(value, deadline, v, r, s);
    }
}
