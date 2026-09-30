// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "./Fixture.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BlueFundTest is Fixture {
    // ---------------------------------------------------------------- constructor

    function test_constructor_rejectsBadBaskets() public {
        address[] memory t = new address[](0);
        uint256[] memory u = new uint256[](0);
        vm.expectRevert(BlueFund.BadBasket.selector);
        new BlueFund("B", "B", t, u, owner, owner, 0, CAP, address(0));

        t = new address[](2);
        u = new uint256[](1);
        vm.expectRevert(BlueFund.BadBasket.selector);
        new BlueFund("B", "B", t, u, owner, owner, 0, CAP, address(0));

        u = new uint256[](2);
        t[0] = tokens[0];
        t[1] = tokens[0];
        u[0] = 1;
        u[1] = 1;
        vm.expectRevert(BlueFund.BadBasket.selector); // duplicate
        new BlueFund("B", "B", t, u, owner, owner, 0, CAP, address(0));

        t[1] = address(0);
        vm.expectRevert(BlueFund.BadBasket.selector); // zero token
        new BlueFund("B", "B", t, u, owner, owner, 0, CAP, address(0));

        t[1] = tokens[1];
        u[1] = 0;
        vm.expectRevert(BlueFund.BadBasket.selector); // zero units
        new BlueFund("B", "B", t, u, owner, owner, 0, CAP, address(0));

        u[1] = 1;
        vm.expectRevert(BlueFund.FeeTooHigh.selector);
        new BlueFund("B", "B", t, u, owner, owner, 101, CAP, address(0));

        vm.expectRevert(BlueFund.ZeroAddress.selector);
        new BlueFund("B", "B", t, u, owner, address(0), 30, CAP, address(0));
    }

    function test_constructor_state() public view {
        assertEq(fund.name(), "Bluechip Index");
        assertEq(fund.symbol(), "BLUE");
        assertEq(fund.decimals(), 18);
        assertEq(fund.owner(), owner);
        assertEq(fund.feeRecipient(), address(burner));
        assertEq(fund.mintFeeBps(), FEE_BPS);
        assertEq(fund.supplyCap(), CAP);
        assertEq(fund.constituents(), tokens);
        assertEq(fund.seedUnits(), units);
    }

    // ---------------------------------------------------------------- seed

    function test_seed_mintsDeadSharesAndPullsBasket() public view {
        assertTrue(fund.seeded());
        assertEq(fund.totalSupply(), SEED);
        assertEq(fund.balanceOf(fund.DEAD()), fund.DEAD_SHARES());
        assertEq(fund.balanceOf(owner), SEED - fund.DEAD_SHARES());
        for (uint256 i; i < tokens.length; ++i) {
            uint256 expected = units[i] * SEED / 1e18;
            assertEq(fund.holdings(tokens[i]), expected);
            assertEq(stocks[i].balanceOf(address(fund)), expected);
        }
    }

    function test_seed_onlyOnce() public {
        vm.prank(owner);
        vm.expectRevert(BlueFund.AlreadySeeded.selector);
        fund.seed(SEED);
    }

    function test_seed_onlyOwnerAndChecks() public {
        BlueFund f = new BlueFund("B", "B", tokens, units, owner, owner, 30, 5e18, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        f.seed(1e18);

        uint256 dead = f.DEAD_SHARES();
        vm.startPrank(owner);
        vm.expectRevert(BlueFund.ZeroAmount.selector);
        f.seed(dead);
        vm.expectRevert(BlueFund.CapExceeded.selector);
        f.seed(6e18);
        vm.stopPrank();
    }

    function test_mint_beforeSeedReverts() public {
        BlueFund f = new BlueFund("B", "B", tokens, units, owner, owner, 30, CAP, address(0));
        vm.expectRevert(BlueFund.NotSeeded.selector);
        f.mint(1e18, alice);
    }

    function test_seed_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(fot);
        u[0] = 1e18;
        BlueFund f = new BlueFund("B", "B", t, u, owner, owner, 30, CAP, address(0));
        fot.mint(owner, 10e18);
        vm.startPrank(owner);
        fot.approve(address(f), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(BlueFund.TransferMismatch.selector, address(fot)));
        f.seed(1e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- mint

    function test_mint_pullsPreviewAndSplitsFee() public {
        uint256 shares = 3e18;
        (, uint256[] memory expected) = fund.previewMint(shares);
        uint256[] memory deposited = _mintAs(alice, shares);
        assertEq(deposited, expected);

        uint256 fee = shares * FEE_BPS / 10_000;
        assertEq(fund.balanceOf(alice), shares - fee);
        assertEq(fund.balanceOf(address(burner)), fee);
        assertEq(fund.totalSupply(), SEED + shares);
        (uint256 toMinter, uint256 f) = fund.previewMintFee(shares);
        assertEq(toMinter, shares - fee);
        assertEq(f, fee);
    }

    function test_mint_toOtherRecipient() public {
        _fundBasket(alice, 1e18);
        vm.startPrank(alice);
        _approveAll(address(fund));
        fund.mint(1e18, bob);
        vm.stopPrank();
        assertEq(fund.balanceOf(bob), 1e18 - 1e18 * FEE_BPS / 10_000);
        assertEq(fund.balanceOf(alice), 0);
    }

    function test_mint_zeroFee() public {
        vm.prank(owner);
        fund.setMintFee(0);
        _mintAs(alice, 1e18);
        assertEq(fund.balanceOf(alice), 1e18);
        assertEq(fund.balanceOf(address(burner)), 0);
    }

    function test_mint_roundsUpForDust() public {
        // 1 wei of BLUE still costs at least 1 base unit of every constituent.
        uint256[] memory deposited = _mintAs(alice, 1);
        for (uint256 i; i < deposited.length; ++i) {
            assertEq(deposited[i], 1);
        }
    }

    function test_mint_reverts() public {
        vm.expectRevert(BlueFund.ZeroAmount.selector);
        fund.mint(0, alice);
        vm.expectRevert(BlueFund.ZeroAddress.selector);
        fund.mint(1e18, address(0));
        vm.expectRevert(BlueFund.CapExceeded.selector);
        fund.mint(CAP, alice);
    }

    function test_mint_capZeroPausesMintButNotRedeem() public {
        _mintAs(alice, 1e18);
        vm.prank(owner);
        fund.setSupplyCap(0);
        vm.expectRevert(BlueFund.CapExceeded.selector);
        fund.mint(1, alice);

        uint256 bal = fund.balanceOf(alice);
        vm.prank(alice);
        fund.redeem(bal, alice);
        assertEq(fund.balanceOf(alice), 0);
    }

    function test_mint_exactApprovalIsEnough() public {
        (, uint256[] memory amounts) = fund.previewMint(2e18);
        _fundBasket(alice, 2e18);
        vm.startPrank(alice);
        for (uint256 i; i < stocks.length; ++i) {
            stocks[i].approve(address(fund), amounts[i]);
        }
        fund.mint(2e18, alice);
        vm.stopPrank();
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(stocks[i].allowance(alice, address(fund)), 0);
        }
    }

    // ---------------------------------------------------------------- redeem

    function test_redeem_paysPreviewAndBurns() public {
        _mintAs(alice, 5e18);
        uint256 shares = fund.balanceOf(alice);
        (, uint256[] memory expected) = fund.previewRedeem(shares);
        uint256 supplyBefore = fund.totalSupply();

        vm.prank(alice);
        uint256[] memory paid = fund.redeem(shares, bob);

        assertEq(paid, expected);
        assertEq(fund.balanceOf(alice), 0);
        assertEq(fund.totalSupply(), supplyBefore - shares);
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(stocks[i].balanceOf(bob), expected[i]);
        }
    }

    function test_redeem_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(BlueFund.ZeroAmount.selector);
        fund.redeem(0, alice);
        vm.expectRevert(BlueFund.ZeroAddress.selector);
        fund.redeem(1, address(0));
        vm.expectRevert(); // no balance
        fund.redeem(1, alice);
        vm.stopPrank();
    }

    function test_redeem_everyoneOutLeavesDeadSharesBacked() public {
        _mintAs(alice, 2e18);
        uint256 a = fund.balanceOf(alice);
        uint256 o = fund.balanceOf(owner);
        uint256 v = fund.balanceOf(address(burner));
        vm.prank(alice);
        fund.redeem(a, alice);
        vm.prank(owner);
        fund.redeem(o, owner);
        vm.prank(address(burner));
        fund.redeem(v, address(burner));

        assertEq(fund.totalSupply(), fund.DEAD_SHARES());
        for (uint256 i; i < tokens.length; ++i) {
            assertGt(fund.holdings(tokens[i]), 0);
        }
        // Mint still works at the preserved ratio.
        _mintAs(bob, 1e18);
        assertGt(fund.balanceOf(bob), 0);
    }

    function test_redeemExcept_exitsPastAFrozenToken() public {
        _mintAs(alice, 4e18);
        uint256 shares = fund.balanceOf(alice);
        stocks[1].setFrozen(true);

        vm.prank(alice);
        vm.expectRevert("MockStock: frozen");
        fund.redeem(shares, alice);

        address[] memory skip = new address[](1);
        skip[0] = tokens[1];
        (, uint256[] memory preview) = fund.previewRedeem(shares);
        uint256 frozenHoldings = fund.holdings(tokens[1]);

        vm.prank(alice);
        uint256[] memory paid = fund.redeemExcept(shares, alice, skip);

        assertEq(paid[0], preview[0]);
        assertEq(paid[1], 0);
        assertEq(paid[2], preview[2]);
        assertEq(fund.holdings(tokens[1]), frozenHoldings); // forfeited to remaining holders
        assertEq(fund.balanceOf(alice), 0);
    }

    function test_redeemExcept_rejectsUnknownToken() public {
        _mintAs(alice, 1e18);
        address[] memory skip = new address[](1);
        skip[0] = address(0xBEEF);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlueFund.NotConstituent.selector, address(0xBEEF)));
        fund.redeemExcept(1e17, alice, skip);
    }

    // ---------------------------------------------------------------- donations & sweep

    function test_donation_changesNothing() public {
        (, uint256[] memory mintBefore) = fund.previewMint(1e18);
        (, uint256[] memory redeemBefore) = fund.previewRedeem(1e18);
        stocks[0].mint(address(fund), 1e12);
        (, uint256[] memory mintAfter) = fund.previewMint(1e18);
        (, uint256[] memory redeemAfter) = fund.previewRedeem(1e18);
        assertEq(mintBefore, mintAfter);
        assertEq(redeemBefore, redeemAfter);
    }

    function test_sweep_onlyTakesExcess() public {
        uint256 held = fund.holdings(tokens[0]);
        stocks[0].mint(address(fund), 777);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fund.sweep(tokens[0], alice);

        vm.prank(owner);
        fund.sweep(tokens[0], bob);
        assertEq(stocks[0].balanceOf(bob), 777);
        assertEq(stocks[0].balanceOf(address(fund)), held);

        vm.prank(owner);
        fund.sweep(tokens[0], bob); // nothing left to take
        assertEq(stocks[0].balanceOf(address(fund)), held);
    }

    function test_sweep_nonConstituent() public {
        MockStock other = new MockStock("Other", "OTH", 6);
        other.mint(address(fund), 5);
        vm.prank(owner);
        fund.sweep(address(other), bob);
        assertEq(other.balanceOf(bob), 5);
    }

    // ---------------------------------------------------------------- admin

    function test_admin_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fund.setMintFee(10);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fund.setSupplyCap(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fund.setFeeRecipient(alice);
        vm.stopPrank();
    }

    function test_admin_limits() public {
        vm.startPrank(owner);
        vm.expectRevert(BlueFund.FeeTooHigh.selector);
        fund.setMintFee(101);
        fund.setMintFee(100);
        assertEq(fund.mintFeeBps(), 100);
        vm.expectRevert(BlueFund.ZeroAddress.selector);
        fund.setFeeRecipient(address(0));
        fund.setFeeRecipient(bob);
        assertEq(fund.feeRecipient(), bob);
        fund.setSupplyCap(42);
        assertEq(fund.supplyCap(), 42);
        vm.stopPrank();
    }

    function test_ownership_twoStep() public {
        vm.prank(owner);
        fund.transferOwnership(bob);
        assertEq(fund.owner(), owner);
        vm.prank(bob);
        fund.acceptOwnership();
        assertEq(fund.owner(), bob);
    }

    function test_views() public view {
        (address[] memory t, uint256[] memory u) = fund.unitsPerShare();
        assertEq(t, tokens);
        for (uint256 i; i < u.length; ++i) {
            assertEq(u[i], units[i]); // seed ratio, nothing else happened yet
        }
    }

    // ---------------------------------------------------------------- fuzz

    /// Minting then redeeming never returns more than was deposited, for any size.
    function testFuzz_roundTripNeverProfits(uint256 shares) public {
        shares = bound(shares, 1, 100_000e18);
        vm.prank(owner);
        fund.setMintFee(0); // isolate rounding from the fee
        uint256[] memory deposited = _mintAs(alice, shares);
        uint256 bal = fund.balanceOf(alice);
        vm.prank(alice);
        uint256[] memory paid = fund.redeem(bal, alice);
        for (uint256 i; i < paid.length; ++i) {
            assertLe(paid[i], deposited[i]);
        }
    }

    /// Mint and redeem never lower holdings per share (cross-multiplied to avoid precision loss).
    function testFuzz_ratiosNeverDecrease(uint256 mintShares, uint256 redeemFrac) public {
        mintShares = bound(mintShares, 1, 100_000e18);
        uint256[] memory h0 = _holdings();
        uint256 s0 = fund.totalSupply();

        _mintAs(alice, mintShares);
        _assertRatiosAtLeast(h0, s0);

        uint256[] memory h1 = _holdings();
        uint256 s1 = fund.totalSupply();
        uint256 shares = bound(redeemFrac, 1, fund.balanceOf(alice));
        vm.prank(alice);
        fund.redeem(shares, alice);
        _assertRatiosAtLeast(h1, s1);
    }

    function _holdings() internal view returns (uint256[] memory h) {
        h = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            h[i] = fund.holdings(tokens[i]);
        }
    }

    function _assertRatiosAtLeast(uint256[] memory hBefore, uint256 sBefore) internal view {
        uint256 s = fund.totalSupply();
        for (uint256 i; i < tokens.length; ++i) {
            assertGe(fund.holdings(tokens[i]) * sBefore, hBefore[i] * s);
        }
    }
}

import {MockBasketFaucet} from "../src/mocks/MockBasketFaucet.sol";

contract MockBasketFaucetTest is Fixture {
    function test_dripCoversAMint() public {
        MockBasketFaucet faucet = new MockBasketFaucet(fund);
        faucet.drip(alice, 3e18);
        vm.startPrank(alice);
        _approveAll(address(fund));
        fund.mint(3e18, alice);
        vm.stopPrank();
        assertGt(fund.balanceOf(alice), 0);
    }
}
