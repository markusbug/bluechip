// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipBurner} from "../src/ChipBurner.sol";
import {MockChipSwapper} from "../src/mocks/MockChipSwapper.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockChip} from "../src/mocks/MockChip.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";
import {MockOracleSwapper} from "../src/mocks/MockOracleSwapper.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";

/// @notice Three-stock fund (two 8-decimal tokens like the real B20 stocks, one 18-decimal) + CHIP burner
///         + rebalancer over mock feeds and an oracle-priced mock DEX (which also sells stocks for mock
///         USDC), and a mock CHIP market at $0.01. The clock starts on a Wednesday in the US regular
///         session, and the index matches the seed, so the fund starts balanced.
abstract contract Fixture is Test {
    BlueFund internal fund;
    ChipBurner internal burner;
    MockStock internal usdc;
    MockChipSwapper internal chipSwapper;
    MockChip internal chip;
    MockStock[] internal stocks;
    address[] internal tokens;
    uint256[] internal units;
    Rebalancer internal rebalancer;
    MockOracleSwapper internal swapper;
    MockPriceFeed[] internal feeds;
    address[] internal feedAddrs;
    uint256[] internal floatShares;
    uint256[] internal multipliers;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal updater = makeAddr("updater");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant FEE_BPS = 30;
    uint256 internal constant CAP = 1_000_000e18;
    uint256 internal constant SEED = 10e18;
    /// @dev Wednesday 2026-09-30 15:00 UTC.
    uint256 internal constant MARKET_TIME = 1_790_780_400;
    uint256 internal constant MAX_SLIPPAGE_BPS = 50;
    uint256 internal constant MAX_TRADE_BPS = 100;
    uint256 internal constant MIN_TRADE_BPS = 5;
    uint256 internal constant COOLDOWN = 30 minutes;
    uint256 internal constant MAX_FEED_AGE = 6 hours;
    uint256 internal constant DEX_SLIPPAGE_BPS = 30;

    function setUp() public virtual {
        vm.warp(MARKET_TIME);
        stocks.push(new MockStock("NVIDIA", "NVDAc", 8));
        stocks.push(new MockStock("Apple", "AAPLc", 8));
        stocks.push(new MockStock("Wide", "WIDE", 18));
        for (uint256 i; i < stocks.length; ++i) {
            tokens.push(address(stocks[i]));
        }
        units.push(10_139_000); // 0.10139 NVDA per BLUE
        units.push(6_192_345); // 0.06192345 AAPL per BLUE
        units.push(3.3e16); // 0.033 WIDE per BLUE
        // Float shares in proportion to the seed units (all with multiplier 1): balanced from the start.
        floatShares.push(10_139_000);
        floatShares.push(6_192_345);
        floatShares.push(3_300_000);
        multipliers.push(1e18);
        multipliers.push(1e18);
        multipliers.push(1e18);
        feeds.push(new MockPriceFeed(200e8));
        feeds.push(new MockPriceFeed(300e8));
        feeds.push(new MockPriceFeed(50e8));
        uint8[] memory decimals = new uint8[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            feedAddrs.push(address(feeds[i]));
            decimals[i] = stocks[i].decimals();
        }
        // The mock DEX also prices mock USDC at $1, so it can sell stocks for it.
        usdc = new MockStock("USD Coin", "USDC", 6);
        address[] memory dexTokens = new address[](stocks.length + 1);
        address[] memory dexFeeds = new address[](stocks.length + 1);
        for (uint256 i; i < stocks.length; ++i) {
            (dexTokens[i], dexFeeds[i]) = (tokens[i], feedAddrs[i]);
        }
        (dexTokens[stocks.length], dexFeeds[stocks.length]) = (address(usdc), address(new MockPriceFeed(1e8)));
        swapper = new MockOracleSwapper(dexTokens, dexFeeds, DEX_SLIPPAGE_BPS);

        chip = new MockChip(owner);
        // CHIP at $0.01: 1 USDC (1e6) buys 100 CHIP (1e20). The market holds 10B CHIP ($100M).
        chipSwapper = new MockChipSwapper(address(usdc), address(chip), 1e14);
        vm.prank(owner);
        chip.transfer(address(chipSwapper), 10_000_000_000e18);

        // Fee recipient is the burner and the rebalancer needs the fund: predict both addresses.
        uint256 nonce = vm.getNonce(address(this));
        address predictedBurner = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedRebalancer = vm.computeCreateAddress(address(this), nonce + 2);
        fund = new BlueFund(
            "Bluechip Index", "BLUE", tokens, units, owner, predictedBurner, FEE_BPS, CAP, predictedRebalancer
        );
        burner = new ChipBurner(
            fund,
            IChip(address(chip)),
            address(usdc),
            ISwapper(address(swapper)),
            ISwapper(address(chipSwapper)),
            owner,
            keeper
        );
        rebalancer = new Rebalancer(
            fund,
            ISwapper(address(swapper)),
            feedAddrs,
            decimals,
            floatShares,
            multipliers,
            owner,
            updater,
            _params()
        );
        assertEq(address(burner), predictedBurner);
        assertEq(address(rebalancer), predictedRebalancer);

        _fundBasket(owner, SEED);
        vm.startPrank(owner);
        _approveAll(address(fund));
        fund.seed(SEED);
        vm.stopPrank();
    }

    function _params() internal pure returns (Rebalancer.Params memory) {
        return Rebalancer.Params({
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            maxTradeBps: MAX_TRADE_BPS,
            minTradeBps: MIN_TRADE_BPS,
            cooldown: COOLDOWN,
            maxFeedAge: MAX_FEED_AGE
        });
    }

    /// @dev NAV in USD (18 decimals) at the mock feed prices.
    function _nav() internal view returns (uint256 nav) {
        (,,, nav) = rebalancer.valuation();
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
