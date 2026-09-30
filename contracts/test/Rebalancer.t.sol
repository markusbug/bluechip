// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "./Fixture.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RebalancerTest is Fixture {
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------ helpers

    /// @dev Warp to 15:00 UTC on the next weekday and mark every feed fresh.
    function _nextSession() internal {
        uint256 day = block.timestamp / 1 days + 1;
        while ((day + 4) % 7 == 0 || (day + 4) % 7 == 6) {
            day++;
        }
        vm.warp(day * 1 days + 15 hours);
        _refreshFeeds();
    }

    function _refreshFeeds() internal {
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].setUpdatedAt(block.timestamp);
        }
    }

    /// @dev Propose `fs` as the index, wait out the delay, activate, and land in a session.
    function _changeIndex(uint256[] memory fs) internal {
        vm.prank(updater);
        rebalancer.proposeIndex(fs, multipliers);
        vm.warp(block.timestamp + rebalancer.INDEX_DELAY());
        rebalancer.activateIndex();
        _nextSession();
    }

    /// @dev WIDE's float doubles: it becomes underweight, the others overweight.
    function _doubleWide() internal {
        uint256[] memory fs = floatShares;
        fs[2] *= 2;
        _changeIndex(fs);
    }

    function _maxDeviation() internal view returns (uint256 maxDev, uint256 nav) {
        (, uint256[] memory values, uint256[] memory targets, uint256 nav_) = rebalancer.valuation();
        nav = nav_;
        for (uint256 i; i < values.length; ++i) {
            uint256 dev = values[i] > targets[i] ? values[i] - targets[i] : targets[i] - values[i];
            if (dev > maxDev) maxDev = dev;
        }
    }

    // ------------------------------------------------------------ steady state

    function test_startsBalanced() public view {
        (bool ok,,, uint256 valueUsd) = rebalancer.plan();
        assertFalse(ok);
        assertLt(valueUsd, _nav() * MIN_TRADE_BPS / BPS);
        (uint256 dev, uint256 nav) = _maxDeviation();
        assertLt(dev, nav / 1e12);
    }

    function test_priceMovesNeedNoTrades() public {
        feeds[0].setPrice(400e8); // NVDA doubles
        feeds[2].setPrice(10e8); // WIDE falls 80%
        (bool ok,,,) = rebalancer.plan();
        assertFalse(ok);
        (uint256 dev, uint256 nav) = _maxDeviation();
        assertLt(dev, nav / 1e12);
    }

    function test_splitNeedsNoTrades() public {
        // A 10:1 split: each token is now 10 shares, the token price is unchanged.
        stocks[0].setMultiplier(10e18);
        (bool ok,,,) = rebalancer.plan();
        assertFalse(ok);
    }

    // ------------------------------------------------------------ rebalancing

    function test_indexChangeConverges() public {
        _doubleWide();
        uint256 navBefore = _nav();
        uint256 traded;
        uint256 trades;
        for (uint256 guard; guard < 500; ++guard) {
            (bool ok, uint256 s, uint256 b, uint256 v) = rebalancer.plan();
            if (!ok) {
                if (v < _nav() * MIN_TRADE_BPS / BPS) break;
                // Cooldown or session end: move on.
                vm.warp(block.timestamp + COOLDOWN);
                if (!rebalancer.marketOpen()) _nextSession();
                _refreshFeeds();
                continue;
            }
            assertLe(v, _nav() * MAX_TRADE_BPS / BPS + 1);
            rebalancer.rebalance(s, b);
            traded += v;
            trades++;
        }
        assertGt(trades, 1);

        (uint256 dev, uint256 nav) = _maxDeviation();
        // Stops once the best trade is under the minimum; with 3 constituents every gap is at most 2x that.
        assertLe(dev, 2 * nav * MIN_TRADE_BPS / BPS);
        // The only cost is the DEX slippage on what was traded, well inside the oracle bound.
        assertLe(navBefore - nav, traded * MAX_SLIPPAGE_BPS / BPS);
        assertApproxEqRel(navBefore - nav, traded * DEX_SLIPPAGE_BPS / BPS, 0.01e18);
    }

    function test_tradeIsCappedAndCreditsHoldings() public {
        _doubleWide();
        (bool ok, uint256 s, uint256 b, uint256 v) = rebalancer.plan();
        assertTrue(ok);
        uint256 nav = _nav();
        assertEq(v, nav * MAX_TRADE_BPS / BPS);
        uint256 hs = fund.holdings(tokens[s]);
        uint256 hb = fund.holdings(tokens[b]);

        (uint256 amountIn, uint256 amountOut) = rebalancer.rebalance(s, b);
        assertEq(fund.holdings(tokens[s]), hs - amountIn);
        assertEq(fund.holdings(tokens[b]), hb + amountOut);
        assertEq(stocks[b].balanceOf(address(fund)), fund.holdings(tokens[b]));
        assertEq(rebalancer.lastTradeAt(), block.timestamp);
    }

    function test_mintAndRedeemStayProRataAfterTrades() public {
        _doubleWide();
        (, uint256 s, uint256 b,) = rebalancer.plan();
        rebalancer.rebalance(s, b);

        uint256 supply = fund.totalSupply();
        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            before[i] = fund.holdings(tokens[i]);
        }
        uint256[] memory deposited = _mintAs(alice, 1e18);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(deposited[i], Math.mulDiv(before[i], 1e18, supply, Math.Rounding.Ceil));
        }
    }

    function test_revertsWhenMarketClosed() public {
        _doubleWide();
        (, uint256 s, uint256 b,) = rebalancer.plan();
        uint256 day = block.timestamp / 1 days * 1 days;

        vm.warp(day + 14 hours + 29 minutes); // before the session
        _refreshFeeds();
        vm.expectRevert(Rebalancer.MarketClosed.selector);
        rebalancer.rebalance(s, b);

        vm.warp(day + 20 hours); // after
        _refreshFeeds();
        vm.expectRevert(Rebalancer.MarketClosed.selector);
        rebalancer.rebalance(s, b);

        uint256 saturday = day + ((6 + 7 - ((day / 1 days + 4) % 7)) % 7) * 1 days;
        vm.warp(saturday + 15 hours);
        _refreshFeeds();
        assertFalse(rebalancer.marketOpen());
        vm.expectRevert(Rebalancer.MarketClosed.selector);
        rebalancer.rebalance(s, b);
    }

    function test_revertsOnStaleOrBadPrice() public {
        _doubleWide();
        (, uint256 s, uint256 b,) = rebalancer.plan();

        feeds[1].setUpdatedAt(block.timestamp - MAX_FEED_AGE - 1);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.StalePrice.selector, address(feeds[1])));
        rebalancer.rebalance(s, b);

        feeds[1].setPrice(0);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.BadPrice.selector, address(feeds[1])));
        rebalancer.rebalance(s, b);
    }

    function test_cooldown() public {
        _doubleWide();
        (, uint256 s, uint256 b,) = rebalancer.plan();
        rebalancer.rebalance(s, b);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.CoolingDown.selector, block.timestamp + COOLDOWN));
        rebalancer.rebalance(s, b);
        (bool ok,,,) = rebalancer.plan();
        assertFalse(ok);

        vm.warp(block.timestamp + COOLDOWN);
        rebalancer.rebalance(s, b);
    }

    function test_revertsOnWrongDirection() public {
        _doubleWide();
        (, uint256 s, uint256 b,) = rebalancer.plan();
        assertEq(b, 2);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotOverweight.selector, tokens[b]));
        rebalancer.rebalance(b, s);
        uint256 other = s == 0 ? 1 : 0;
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.NotUnderweight.selector, tokens[other]));
        rebalancer.rebalance(s, other);
    }

    function test_revertsWhenBalanced() public {
        // Nothing is over- or underweight by more than rounding: whatever the pair, no trade.
        vm.expectRevert();
        rebalancer.rebalance(0, 2);
        vm.expectRevert();
        rebalancer.rebalance(2, 0);
    }

    function test_revertsWhenDexPaysTooLittle() public {
        _doubleWide();
        (, uint256 s, uint256 b,) = rebalancer.plan();
        swapper.setSlippage(MAX_SLIPPAGE_BPS + 10);
        vm.expectPartialRevert(BlueFund.Slippage.selector);
        rebalancer.rebalance(s, b);
    }

    // ------------------------------------------------------------ index

    function test_indexTimelock() public {
        uint256[] memory fs = floatShares;
        fs[0] += 1;

        vm.expectRevert(Rebalancer.NotUpdater.selector);
        vm.prank(alice);
        rebalancer.proposeIndex(fs, multipliers);

        vm.expectRevert(Rebalancer.NothingPending.selector);
        rebalancer.activateIndex();

        vm.prank(updater);
        rebalancer.proposeIndex(fs, multipliers);
        uint256 eta = block.timestamp + 7 days;
        assertEq(rebalancer.pendingIndexEta(), eta);
        assertEq(rebalancer.pendingFloatShares(), fs);

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer.TooEarly.selector, eta));
        rebalancer.activateIndex();

        vm.warp(eta);
        vm.prank(alice); // anyone
        rebalancer.activateIndex();
        assertEq(rebalancer.floatShares(), fs);
        assertEq(rebalancer.pendingIndexEta(), 0);
        assertEq(rebalancer.pendingFloatShares().length, 0);
    }

    function test_cancelIndex() public {
        uint256[] memory fs = floatShares;
        fs[0] += 1;
        vm.prank(updater);
        rebalancer.proposeIndex(fs, multipliers);

        vm.expectRevert(Rebalancer.NotUpdater.selector);
        vm.prank(alice);
        rebalancer.cancelIndex();

        vm.prank(owner);
        rebalancer.cancelIndex();
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Rebalancer.NothingPending.selector);
        rebalancer.activateIndex();
        assertEq(rebalancer.floatShares(), floatShares);
    }

    function test_proposalRestartsDelay() public {
        uint256[] memory fs = floatShares;
        vm.prank(updater);
        rebalancer.proposeIndex(fs, multipliers);
        vm.warp(block.timestamp + 6 days);
        vm.prank(updater);
        rebalancer.proposeIndex(fs, multipliers);
        assertEq(rebalancer.pendingIndexEta(), block.timestamp + 7 days);
    }

    function test_rejectsBadIndex() public {
        uint256[] memory fs = floatShares;
        uint256[] memory ms = multipliers;
        vm.startPrank(updater);

        fs[1] = 0;
        vm.expectRevert(Rebalancer.BadIndex.selector);
        rebalancer.proposeIndex(fs, ms);
        fs[1] = 1e15 + 1;
        vm.expectRevert(Rebalancer.BadIndex.selector);
        rebalancer.proposeIndex(fs, ms);
        fs[1] = 1;
        ms[1] = 0;
        vm.expectRevert(Rebalancer.BadIndex.selector);
        rebalancer.proposeIndex(fs, ms);

        vm.expectRevert(Rebalancer.LengthMismatch.selector);
        rebalancer.proposeIndex(new uint256[](2), ms);
        vm.stopPrank();
    }

    function test_indexUsesItsOwnMultiplier() public {
        // The index is re-counted after a 2:1 split: twice the shares at twice the multiplier.
        stocks[0].setMultiplier(2e18);
        uint256[] memory fs = floatShares;
        uint256[] memory ms = multipliers;
        fs[0] *= 2;
        ms[0] = 2e18;
        vm.prank(updater);
        rebalancer.proposeIndex(fs, ms);
        vm.warp(block.timestamp + 7 days);
        rebalancer.activateIndex();
        _nextSession();
        (bool ok,,,) = rebalancer.plan();
        assertFalse(ok);
        assertEq(rebalancer.multipliers(), ms);
    }

    // ------------------------------------------------------------ admin

    function test_params() public {
        Rebalancer.Params memory p = _params();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        rebalancer.setParams(p);

        vm.startPrank(owner);
        p.maxSlippageBps = 201;
        vm.expectRevert(Rebalancer.BadParams.selector);
        rebalancer.setParams(p);

        p = _params();
        p.maxTradeBps = 0;
        vm.expectRevert(Rebalancer.BadParams.selector);
        rebalancer.setParams(p);
        p.maxTradeBps = 1_001;
        vm.expectRevert(Rebalancer.BadParams.selector);
        rebalancer.setParams(p);

        p = _params();
        p.minTradeBps = p.maxTradeBps + 1;
        vm.expectRevert(Rebalancer.BadParams.selector);
        rebalancer.setParams(p);

        p = _params();
        p.cooldown = 5 minutes - 1;
        vm.expectRevert(Rebalancer.BadParams.selector);
        rebalancer.setParams(p);

        p = _params();
        p.maxFeedAge = 0;
        vm.expectRevert(Rebalancer.BadParams.selector);
        rebalancer.setParams(p);
        p.maxFeedAge = 1 days + 1;
        vm.expectRevert(Rebalancer.BadParams.selector);
        rebalancer.setParams(p);

        p = Rebalancer.Params(200, 1_000, 1_000, 5 minutes, 1 days);
        rebalancer.setParams(p);
        assertEq(rebalancer.maxSlippageBps(), 200);
        assertEq(rebalancer.maxTradeBps(), 1_000);
        assertEq(rebalancer.minTradeBps(), 1_000);
        assertEq(rebalancer.cooldown(), 5 minutes);
        assertEq(rebalancer.maxFeedAge(), 1 days);
        vm.stopPrank();
    }

    function test_setUpdater() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        rebalancer.setUpdater(alice);

        vm.prank(owner);
        rebalancer.setUpdater(alice);
        assertEq(rebalancer.updater(), alice);
        vm.prank(alice);
        rebalancer.proposeIndex(floatShares, multipliers);
    }

    function test_constructorChecksLengths() public {
        vm.expectRevert(Rebalancer.LengthMismatch.selector);
        new Rebalancer(
            fund,
            ISwapper(address(swapper)),
            new address[](2),
            new uint8[](3),
            floatShares,
            multipliers,
            owner,
            updater,
            _params()
        );
    }

    function test_views() public {
        assertEq(rebalancer.constituents(), tokens);
        assertEq(rebalancer.feeds(), feedAddrs);
        assertEq(rebalancer.multipliers(), multipliers);
        assertEq(address(rebalancer.fund()), address(fund));
        assertEq(address(rebalancer.swapper()), address(swapper));

        uint256[] memory ms = multipliers;
        ms[1] = 2e18;
        vm.prank(updater);
        rebalancer.proposeIndex(floatShares, ms);
        assertEq(rebalancer.pendingMultipliers(), ms);
    }

    function test_marketOpen() public {
        // Wednesday 2026-09-30.
        uint256 day = MARKET_TIME / 1 days * 1 days;
        vm.warp(day + 14 hours + 30 minutes);
        assertTrue(rebalancer.marketOpen());
        vm.warp(day + 20 hours - 1);
        assertTrue(rebalancer.marketOpen());
        vm.warp(day + 3 days + 15 hours); // Saturday
        assertFalse(rebalancer.marketOpen());
        vm.warp(day + 4 days + 15 hours); // Sunday
        assertFalse(rebalancer.marketOpen());
        vm.warp(day + 5 days + 15 hours); // Monday
        assertTrue(rebalancer.marketOpen());
    }
}
