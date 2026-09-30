// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BlueFund} from "../../src/BlueFund.sol";
import {ChipBurner} from "../../src/ChipBurner.sol";
import {MockStock} from "../../src/mocks/MockStock.sol";
import {MockChip} from "../../src/mocks/MockChip.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";
import {Rebalancer} from "../../src/Rebalancer.sol";

/// @notice Drives random mints, redeems, emergency redeems, donations, fee changes, CHIP burns,
///         price moves, index changes and rebalancing trades.
///         After every action except a trade it checks that holdings-per-share did not drop. A trade
///         may shift holdings between stocks, but must not cost more NAV than the slippage bound on
///         what it traded. A burn must lower CHIP supply by exactly what it burned.
contract Handler is Test {
    BlueFund internal fund;
    ChipBurner internal burner;
    MockChip internal chip;
    MockStock internal usdc;
    address internal keeper;
    MockStock[] internal stocks;
    address internal owner;
    address[] internal actors;
    Rebalancer internal rebalancer;
    MockPriceFeed[] internal feeds;
    address internal updater;

    uint256 public calls;
    uint256 public ratioDrops;
    uint256 public chipLeaks;
    uint256 public burns;
    uint256 public trades;
    uint256 public navLeaks;

    constructor(
        BlueFund fund_,
        ChipBurner burner_,
        MockChip chip_,
        MockStock usdc_,
        address keeper_,
        MockStock[] memory stocks_,
        address owner_,
        Rebalancer rebalancer_,
        MockPriceFeed[] memory feeds_,
        address updater_
    ) {
        fund = fund_;
        burner = burner_;
        chip = chip_;
        usdc = usdc_;
        keeper = keeper_;
        stocks = stocks_;
        owner = owner_;
        rebalancer = rebalancer_;
        feeds = feeds_;
        updater = updater_;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
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

    function burn(uint256 amount) external checked {
        uint256 pending = burner.pendingBlue();
        if (pending == 0) return;
        amount = bound(amount, 1, pending);
        uint256 supply = chip.totalSupply();
        vm.prank(keeper);
        uint256 burned = burner.burn(amount, 0, new address[](0));
        burns++;
        if (chip.totalSupply() != supply - burned) chipLeaks++;
    }

    function redeemAll(uint256 actorSeed) external checked {
        address a = _actor(actorSeed);
        uint256 bal = fund.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        fund.redeem(bal, a);
    }

    function movePrice(uint256 idx, uint256 bps) external checked {
        MockPriceFeed feed = feeds[idx % feeds.length];
        (, int256 answer,,,) = feed.latestRoundData();
        // Anything from -50% to +100%, never below $1.
        uint256 next = uint256(answer) * bound(bps, 5_000, 20_000) / 10_000;
        feed.setPrice(int256(next < 1e8 ? 1e8 : next));
    }

    function changeIndex(uint256 idx, uint256 bps) external checked {
        uint256[] memory fs = rebalancer.floatShares();
        uint256 i = idx % fs.length;
        // A company's float moves by -30% to +30%.
        fs[i] = fs[i] * bound(bps, 7_000, 13_000) / 10_000;
        if (fs[i] == 0) fs[i] = 1;
        uint256[] memory ms = rebalancer.multipliers();
        vm.prank(updater);
        rebalancer.proposeIndex(fs, ms);
        vm.warp(block.timestamp + rebalancer.INDEX_DELAY());
        rebalancer.activateIndex();
    }

    function rebalance() external {
        _toSession();
        if (block.timestamp < rebalancer.lastTradeAt() + rebalancer.cooldown()) {
            vm.warp(rebalancer.lastTradeAt() + rebalancer.cooldown());
            _toSession();
        }
        (bool ok, uint256 s, uint256 b, uint256 value) = rebalancer.plan();
        if (!ok) return;

        (,,, uint256 navBefore) = rebalancer.valuation();
        uint256 supply = fund.totalSupply();
        rebalancer.rebalance(s, b);
        calls++;
        trades++;

        (,,, uint256 navAfter) = rebalancer.valuation();
        assertEq(fund.totalSupply(), supply);
        // Rounding in token units can cost a few wei of USD per token.
        if (navAfter + value * rebalancer.maxSlippageBps() / 10_000 + 1e12 < navBefore) navLeaks++;
    }

    /// @dev Move to the next US session if closed, and mark every price fresh.
    function _toSession() internal {
        if (!rebalancer.marketOpen()) {
            uint256 day = block.timestamp / 1 days + 1;
            while ((day + 4) % 7 == 0 || (day + 4) % 7 == 6) {
                day++;
            }
            vm.warp(day * 1 days + 15 hours);
        }
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
    }

    // ------------------------------------------------------------ monotonicity checks

    modifier checked() {
        uint256 n = stocks.length;
        uint256[] memory h = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            h[i] = fund.holdings(address(stocks[i]));
        }
        uint256 s = fund.totalSupply();

        _;

        calls++;
        uint256 s2 = fund.totalSupply();
        for (uint256 i; i < n; ++i) {
            if (fund.holdings(address(stocks[i])) * s < h[i] * s2) ratioDrops++;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}
