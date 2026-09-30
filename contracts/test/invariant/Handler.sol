// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BlueFund} from "../../src/BlueFund.sol";
import {ChipVault} from "../../src/ChipVault.sol";
import {MockStock} from "../../src/mocks/MockStock.sol";
import {MockChip} from "../../src/mocks/MockChip.sol";

/// @notice Drives random mints, redeems, emergency redeems, donations, fee changes and CHIP claims.
///         After every action it checks that holdings-per-share and backing-per-CHIP did not drop.
contract Handler is Test {
    BlueFund internal fund;
    ChipVault internal vault;
    MockChip internal chip;
    MockStock[] internal stocks;
    address internal owner;
    address[] internal actors;

    uint256 public calls;
    uint256 public ratioDrops;
    uint256 public backingDrops;

    constructor(
        BlueFund fund_,
        ChipVault vault_,
        MockChip chip_,
        MockStock[] memory stocks_,
        address owner_
    ) {
        fund = fund_;
        vault = vault_;
        chip = chip_;
        stocks = stocks_;
        owner = owner_;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.prank(owner);
            chip.transfer(a, 5_000_000_000e18);
        }
    }

    // ------------------------------------------------------------ actions

    function mint(uint256 actorSeed, uint256 shares) external checked {
        address a = _actor(actorSeed);
        uint256 room = fund.supplyCap() - fund.totalSupply();
        if (room == 0) return;
        shares = bound(shares, 1, room < 50_000e18 ? room : 50_000e18);
        (, uint256[] memory amounts) = fund.previewMint(shares);
        vm.startPrank(a);
        for (uint256 i; i < stocks.length; ++i) {
            stocks[i].mint(a, amounts[i]);
            stocks[i].approve(address(fund), amounts[i]);
        }
        fund.mint(shares, a);
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 shares) external checked {
        address a = _actor(actorSeed);
        uint256 bal = fund.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        fund.redeem(shares, a);
    }

    function redeemExcept(uint256 actorSeed, uint256 shares, uint256 skipIdx) external checked {
        address a = _actor(actorSeed);
        uint256 bal = fund.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        address[] memory skip = new address[](1);
        skip[0] = address(stocks[skipIdx % stocks.length]);
        vm.prank(a);
        fund.redeemExcept(shares, a, skip);
    }

    function donate(uint256 idx, uint256 amount) external checked {
        stocks[idx % stocks.length].mint(address(fund), bound(amount, 1, 1e24));
    }

    function setFee(uint256 bps) external checked {
        bps = bound(bps, 0, fund.MAX_FEE_BPS());
        vm.prank(owner);
        fund.setMintFee(bps);
    }

    function claim(uint256 actorSeed, uint256 amount) external checked {
        address a = _actor(actorSeed);
        uint256 bal = chip.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        if (vault.previewClaim(amount) == 0) return;
        vm.startPrank(a);
        chip.approve(address(vault), amount);
        vault.claim(amount, 0, a);
        vm.stopPrank();
    }

    function redeemVaultShares(uint256 actorSeed) external checked {
        // Claimed BLUE is ordinary BLUE: it can be redeemed for the basket.
        address a = _actor(actorSeed);
        uint256 bal = fund.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        fund.redeem(bal, a);
    }

    // ------------------------------------------------------------ monotonicity checks

    modifier checked() {
        uint256 n = stocks.length;
        uint256[] memory h = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            h[i] = fund.holdings(address(stocks[i]));
        }
        uint256 s = fund.totalSupply();
        uint256 b = vault.totalBacking();
        uint256 cs = chip.totalSupply();

        _;

        calls++;
        uint256 s2 = fund.totalSupply();
        for (uint256 i; i < n; ++i) {
            if (fund.holdings(address(stocks[i])) * s < h[i] * s2) ratioDrops++;
        }
        // The only way BLUE leaves the vault is a claim, which also burns CHIP.
        if (vault.totalBacking() * cs < b * chip.totalSupply()) backingDrops++;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}
