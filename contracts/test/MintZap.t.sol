// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "./Fixture.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {MintZap} from "../src/MintZap.sol";
import {MockOraclePool} from "../src/mocks/MockOraclePool.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";

/// @dev Calls the zap twice in one transaction, where transient storage carries over.
contract TwoMints {
    receive() external payable {}

    function usdcTwice(MintZap zap, MockStock usdc, uint256 shares, uint256 maxEach)
        external
        returns (uint256 first, uint256 second)
    {
        usdc.approve(address(zap), type(uint256).max);
        first = zap.mintWithUsdc(shares, msg.sender, maxEach, block.timestamp);
        second = zap.mintWithUsdc(shares, msg.sender, maxEach, block.timestamp);
    }

    /// @dev A WETH mint, then a USDC one: the second must pay in USDC.
    function wethThenUsdc(
        MintZap zap,
        MockStock usdc,
        IERC20 weth,
        uint256 shares,
        uint256 maxWeth,
        uint256 maxUsdc
    ) external returns (uint256 wethIn, uint256 usdcIn) {
        weth.approve(address(zap), type(uint256).max);
        usdc.approve(address(zap), type(uint256).max);
        wethIn = zap.mintWithWeth(shares, msg.sender, maxWeth, block.timestamp);
        usdcIn = zap.mintWithUsdc(shares, msg.sender, maxUsdc, block.timestamp);
    }

    /// @dev An ETH mint, then a WETH one: the second must pay from this contract, not the zap.
    function ethThenWeth(MintZap zap, IERC20 weth, uint256 shares, uint256 maxEach)
        external
        payable
        returns (uint256 ethIn, uint256 wethIn)
    {
        weth.approve(address(zap), type(uint256).max);
        ethIn = zap.mintWithEth{value: maxEach}(shares, msg.sender, block.timestamp);
        wethIn = zap.mintWithWeth(shares, msg.sender, maxEach, block.timestamp);
    }

    function ethTwice(MintZap zap, uint256 shares, uint256 valueEach)
        external
        payable
        returns (uint256 first, uint256 second)
    {
        first = zap.mintWithEth{value: valueEach}(shares, msg.sender, block.timestamp);
        second = zap.mintWithEth{value: valueEach}(shares, msg.sender, block.timestamp);
    }
}

/// @dev A contract that can't take ETH back.
contract NoReceive {
    function mint(MintZap zap, uint256 shares) external payable {
        zap.mintWithEth{value: msg.value}(shares, msg.sender, block.timestamp);
    }
}

contract MintZapTest is Fixture {
    uint256 internal constant SPREAD_BPS = 30;
    uint256 internal constant ETH_PRICE = 3_000e8;

    MockWETH internal weth;
    MockOraclePool internal wethPool;
    MockOraclePool[] internal pools;
    address[] internal poolAddrs;
    MintZap internal zap;
    MockPriceFeed internal usdcFeed;
    uint256 internal aliceKey;

    function setUp() public override {
        super.setUp();
        (, aliceKey) = makeAddrAndKey("alice");
        weth = new MockWETH();
        usdcFeed = new MockPriceFeed(1e8);
        MockPriceFeed wethFeed = new MockPriceFeed(int256(ETH_PRICE));
        // USDC is token0 in the real stock pools; put one stock on the other side to cover both.
        for (uint256 i; i < stocks.length; ++i) {
            MockOraclePool p = i == 1
                ? new MockOraclePool(tokens[i], address(usdc), feedAddrs[i], address(usdcFeed), SPREAD_BPS)
                : new MockOraclePool(address(usdc), tokens[i], address(usdcFeed), feedAddrs[i], SPREAD_BPS);
            pools.push(p);
            poolAddrs.push(address(p));
        }
        // WETH is token0 in the real USDC/WETH pool.
        wethPool =
            new MockOraclePool(address(weth), address(usdc), address(wethFeed), address(usdcFeed), SPREAD_BPS);
        zap = new MintZap(fund, address(usdc), IWETH(address(weth)), ICLPool(address(wethPool)), poolAddrs);
    }

    // ---------------------------------------------------------------- USDC

    function test_mintWithUsdc() public {
        uint256 shares = 3e18;
        (uint256 quoted,) = zap.quoteMint(shares);
        usdc.mint(alice, 10_000e6);

        vm.startPrank(alice);
        usdc.approve(address(zap), type(uint256).max);
        vm.expectEmit(address(zap));
        emit MintZap.ZapMinted(alice, alice, shares, address(usdc), quoted);
        uint256 spent = zap.mintWithUsdc(shares, alice, quoted, block.timestamp);
        vm.stopPrank();

        assertEq(spent, quoted);
        assertEq(usdc.balanceOf(alice), 10_000e6 - spent);
        (uint256 toMinter, uint256 fee) = fund.previewMintFee(shares);
        assertEq(fund.balanceOf(alice), toMinter);
        assertEq(fund.balanceOf(address(burner)), fee);
        _assertZapEmpty();

        // The price is the NAV plus the pools' spread, give or take rounding.
        assertApproxEqRel(spent, _navOf(shares) * 10_000 / (10_000 - SPREAD_BPS), 1e12);
    }

    function test_mintToSomeoneElse() public {
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), type(uint256).max);
        zap.mintWithUsdc(1e18, bob, type(uint256).max, block.timestamp);
        vm.stopPrank();
        (uint256 toMinter,) = fund.previewMintFee(1e18);
        assertEq(fund.balanceOf(bob), toMinter);
        assertEq(fund.balanceOf(alice), 0);
    }

    function test_mintWithUsdcPermit() public {
        uint256 shares = 1e18;
        (uint256 quoted,) = zap.quoteMint(shares);
        usdc.mint(alice, quoted);
        BlueFund.Permit memory p = _signUsdcPermit(quoted, block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 spent = zap.mintWithUsdcPermit(shares, alice, quoted, block.timestamp, p);
        assertEq(spent, quoted);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.allowance(alice, address(zap)), 0);
        _assertZapEmpty();
    }

    function test_frontRunPermitStillMints() public {
        uint256 shares = 1e18;
        (uint256 quoted,) = zap.quoteMint(shares);
        usdc.mint(alice, quoted);
        BlueFund.Permit memory p = _signUsdcPermit(quoted, block.timestamp + 1 hours);
        // Someone submits the signature first: the zap's permit fails, the allowance is there anyway.
        usdc.permit(alice, address(zap), p.value, p.deadline, p.v, p.r, p.s);

        vm.prank(alice);
        zap.mintWithUsdcPermit(shares, alice, quoted, block.timestamp, p);
        assertGt(fund.balanceOf(alice), 0);
    }

    function test_usdcSlippage() public {
        uint256 shares = 2e18;
        (uint256 quoted,) = zap.quoteMint(shares);
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), type(uint256).max);
        vm.expectPartialRevert(MintZap.Slippage.selector);
        zap.mintWithUsdc(shares, alice, quoted - 1, block.timestamp);

        // A stock rallies between the quote and the mint: the maximum holds.
        feeds[0].setPrice(220e8);
        vm.expectPartialRevert(MintZap.Slippage.selector);
        zap.mintWithUsdc(shares, alice, quoted, block.timestamp);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function test_needsAllowance() public {
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        vm.expectRevert();
        zap.mintWithUsdc(1e18, alice, type(uint256).max, block.timestamp);
    }

    function test_expired() public {
        vm.prank(alice);
        vm.expectRevert(MintZap.Expired.selector);
        zap.mintWithUsdc(1e18, alice, type(uint256).max, block.timestamp - 1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(MintZap.Expired.selector);
        zap.mintWithEth{value: 1 ether}(1e18, alice, block.timestamp - 1);
    }

    function test_fundLimitsStillApply() public {
        usdc.mint(alice, 1e15);
        vm.startPrank(alice);
        usdc.approve(address(zap), type(uint256).max);
        vm.expectRevert(BlueFund.CapExceeded.selector);
        zap.mintWithUsdc(CAP, alice, type(uint256).max, block.timestamp);
        vm.expectRevert(BlueFund.ZeroAmount.selector);
        zap.mintWithUsdc(0, alice, type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- ETH

    function test_mintWithEth() public {
        uint256 shares = 3e18;
        (uint256 quotedUsdc, uint256 quoted) = zap.quoteMint(shares);
        assertApproxEqRel(quoted, quotedUsdc * 1e12 * 1e8 / ETH_PRICE * 10_000 / (10_000 - SPREAD_BPS), 1e12);
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        vm.expectEmit(false, false, false, false, address(zap));
        emit MintZap.ZapMinted(alice, alice, shares, address(0), 0);
        uint256 spent = zap.mintWithEth{value: quoted * 101 / 100}(shares, alice, block.timestamp);

        // Separate swaps round up separately: at most a wei per stock above the one-swap quote.
        assertApproxEqAbs(spent, quoted, stocks.length);
        assertEq(alice.balance, 10 ether - spent);
        (uint256 toMinter,) = fund.previewMintFee(shares);
        assertEq(fund.balanceOf(alice), toMinter);
        _assertZapEmpty();
        assertEq(address(zap).balance, 0);
    }

    function test_ethSlippage() public {
        uint256 shares = 2e18;
        (, uint256 quoted) = zap.quoteMint(shares);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectPartialRevert(MintZap.Slippage.selector);
        zap.mintWithEth{value: quoted / 2}(shares, alice, block.timestamp);
        assertEq(alice.balance, 10 ether);
    }

    function test_refundMustArrive() public {
        NoReceive c = new NoReceive();
        vm.deal(address(this), 10 ether);
        vm.expectRevert(MintZap.RefundFailed.selector);
        c.mint{value: 1 ether}(zap, 1e18);
    }

    function test_onlyWethSendsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(zap).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- WETH

    function test_mintWithWeth() public {
        uint256 shares = 3e18;
        (, uint256 quoted) = zap.quoteMint(shares);
        _giveWeth(alice, 10 ether);

        vm.startPrank(alice);
        weth.approve(address(zap), type(uint256).max);
        uint256 max = quoted * 101 / 100;
        uint256 spent = zap.mintWithWeth(shares, alice, max, block.timestamp);
        vm.stopPrank();

        // Like ETH, a wei per stock of rounding at most; only what the pools asked for leaves the wallet.
        assertApproxEqAbs(spent, quoted, stocks.length);
        assertEq(weth.balanceOf(alice), 10 ether - spent);
        assertEq(alice.balance, 0);
        (uint256 toMinter,) = fund.previewMintFee(shares);
        assertEq(fund.balanceOf(alice), toMinter);
        _assertZapEmpty();
        assertEq(address(zap).balance, 0);
    }

    function test_mintWithWethEmits() public {
        (, uint256 quoted) = zap.quoteMint(1e18);
        _giveWeth(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(zap), type(uint256).max);
        vm.expectEmit(true, true, false, false, address(zap));
        emit MintZap.ZapMinted(alice, bob, 1e18, address(weth), 0);
        zap.mintWithWeth(1e18, bob, quoted * 101 / 100, block.timestamp);
        vm.stopPrank();
    }

    function test_wethSlippage() public {
        uint256 shares = 2e18;
        (, uint256 quoted) = zap.quoteMint(shares);
        _giveWeth(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(zap), type(uint256).max);
        vm.expectPartialRevert(MintZap.Slippage.selector);
        zap.mintWithWeth(shares, alice, quoted / 2, block.timestamp);
        vm.stopPrank();
        assertEq(weth.balanceOf(alice), 10 ether);
    }

    function test_wethNeedsAllowance() public {
        _giveWeth(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert();
        zap.mintWithWeth(1e18, alice, type(uint256).max, block.timestamp);
    }

    function test_wethExpired() public {
        vm.prank(alice);
        vm.expectRevert(MintZap.Expired.selector);
        zap.mintWithWeth(1e18, alice, type(uint256).max, block.timestamp - 1);
    }

    // ---------------------------------------------------------------- transient state

    function test_mixedRoutesInOneTransaction() public {
        TwoMints c = new TwoMints();
        uint256 shares = 1e18;
        (uint256 quotedUsdc, uint256 quotedEth) = zap.quoteMint(shares);

        // WETH then USDC: the USDC mint takes USDC and leaves the rest of the WETH alone.
        _giveWeth(address(c), 1 ether);
        usdc.mint(address(c), 1_000e6);
        (uint256 wethIn, uint256 usdcIn) =
            c.wethThenUsdc(zap, usdc, IERC20(address(weth)), shares, quotedEth * 2, quotedUsdc * 2);
        assertApproxEqAbs(wethIn, quotedEth, stocks.length);
        assertApproxEqAbs(usdcIn, quotedUsdc, stocks.length);
        assertEq(weth.balanceOf(address(c)), 1 ether - wethIn);
        assertEq(usdc.balanceOf(address(c)), 1_000e6 - usdcIn);

        // ETH then WETH: the WETH mint pays from the caller's WETH.
        vm.deal(address(this), 10 ether);
        uint256 ethBefore = address(c).balance;
        uint256 wethBefore = weth.balanceOf(address(c));
        uint256 ethIn;
        (ethIn, wethIn) =
            c.ethThenWeth{value: quotedEth * 2}(zap, IERC20(address(weth)), shares, quotedEth * 2);
        assertEq(address(c).balance, ethBefore + quotedEth * 2 - ethIn);
        assertEq(weth.balanceOf(address(c)), wethBefore - wethIn);
        _assertZapEmpty();
    }

    function test_twoMintsInOneTransaction() public {
        TwoMints c = new TwoMints();
        uint256 shares = 1e18;
        (uint256 quotedUsdc, uint256 quotedEth) = zap.quoteMint(shares);

        usdc.mint(address(c), 3 * quotedUsdc);
        (uint256 a, uint256 b) = c.usdcTwice(zap, usdc, shares, quotedUsdc * 3 / 2);
        // Each pays for its own mint only. The mock pools trade at feed prices, so both cost the same
        // up to rounding.
        assertApproxEqAbs(a, quotedUsdc, 1);
        assertApproxEqAbs(b, quotedUsdc, stocks.length);
        assertEq(usdc.balanceOf(address(c)), 3 * quotedUsdc - a - b);

        vm.deal(address(this), 10 ether);
        (a, b) = c.ethTwice{value: 2 * quotedEth * 3 / 2}(zap, shares, quotedEth * 3 / 2);
        assertApproxEqAbs(a, quotedEth, stocks.length);
        assertApproxEqAbs(b, quotedEth, 2 * stocks.length);
        assertEq(address(c).balance, 2 * quotedEth * 3 / 2 - a - b);
        _assertZapEmpty();
    }

    // ---------------------------------------------------------------- pools

    function test_usesStockAlreadyHere() public {
        uint256 shares = 1e18;
        (uint256 before,) = zap.quoteMint(shares);
        (, uint256[] memory need) = fund.previewMint(shares);
        // Someone sends the zap half of the first stock: the next mint buys only the rest.
        stocks[0].mint(address(zap), need[0] / 2);
        (uint256 after_,) = zap.quoteMint(shares);
        assertLt(after_, before);

        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), type(uint256).max);
        uint256 spent = zap.mintWithUsdc(shares, alice, after_, block.timestamp);
        vm.stopPrank();
        assertEq(spent, after_);
        _assertZapEmpty();
    }

    function test_partialFill() public {
        // Swap in fixed-price pools with test hooks: the first stock's, and the USDC/WETH one.
        MockCLPool stockPool = new MockCLPool(address(usdc), tokens[0], 5e17); // NVDA at $200
        MockCLPool ethPool = new MockCLPool(address(weth), address(usdc), 3_000e6);
        stocks[0].mint(address(stockPool), 1e15);
        usdc.mint(address(ethPool), 1e15);
        address[] memory ps = poolAddrs;
        ps[0] = address(stockPool);
        MintZap z = new MintZap(fund, address(usdc), IWETH(address(weth)), ICLPool(address(ethPool)), ps);

        usdc.mint(alice, 10_000e6);
        vm.deal(alice, 10 ether);
        _giveWeth(alice, 1 ether);
        vm.startPrank(alice);
        usdc.approve(address(z), type(uint256).max);
        weth.approve(address(z), type(uint256).max);
        // Works while the pools deliver in full.
        z.mintWithUsdc(1e18, alice, type(uint256).max, block.timestamp);
        z.mintWithEth{value: 1 ether}(1e18, alice, block.timestamp);
        z.mintWithWeth(1e18, alice, 1 ether, block.timestamp);

        stockPool.setShortfall(1);
        vm.expectRevert(abi.encodeWithSelector(MintZap.PartialFill.selector, tokens[0]));
        z.mintWithUsdc(1e18, alice, type(uint256).max, block.timestamp);

        stockPool.setShortfall(0);
        ethPool.setShortfall(1);
        vm.expectRevert(abi.encodeWithSelector(MintZap.PartialFill.selector, address(usdc)));
        z.mintWithEth{value: 1 ether}(1e18, alice, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(MintZap.PartialFill.selector, address(usdc)));
        z.mintWithWeth(1e18, alice, 1 ether, block.timestamp);
        vm.stopPrank();
    }

    function test_overchargingPoolIsCapped() public {
        MockCLPool stockPool = new MockCLPool(address(usdc), tokens[0], 5e17);
        stocks[0].mint(address(stockPool), 1e15);
        address[] memory ps = poolAddrs;
        ps[0] = address(stockPool);
        MintZap z = new MintZap(fund, address(usdc), IWETH(address(weth)), ICLPool(address(wethPool)), ps);
        (uint256 quoted,) = z.quoteMint(1e18);
        stockPool.setOvercharge(1e6);

        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(z), type(uint256).max);
        vm.expectPartialRevert(MintZap.Slippage.selector);
        z.mintWithUsdc(1e18, alice, quoted, block.timestamp);
        vm.stopPrank();
    }

    function test_callbackOnlyFromActivePool() public {
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(zap), type(uint256).max);

        // Not even a real pool can collect outside a swap the zap started.
        vm.prank(address(pools[0]));
        vm.expectRevert(MintZap.UnexpectedCallback.selector);
        zap.uniswapV3SwapCallback(1e6, 0, "");
        vm.expectRevert(MintZap.UnexpectedCallback.selector);
        zap.uniswapV3SwapCallback(1e6, 0, "");
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function test_quoteBubblesPoolErrors() public {
        MockCLPool stockPool = new MockCLPool(address(usdc), tokens[0], 5e17);
        address[] memory ps = poolAddrs;
        ps[0] = address(stockPool);
        MintZap z = new MintZap(fund, address(usdc), IWETH(address(weth)), ICLPool(address(wethPool)), ps);
        // The pool holds no stock to send: its own revert comes through, not a bogus quote.
        vm.expectRevert();
        z.quoteMint(1e18);
    }

    function test_constructorChecksPools() public {
        IWETH w = IWETH(address(weth));
        address[] memory ps = poolAddrs;
        ps[0] = poolAddrs[1]; // the second stock's pool for the first stock
        vm.expectRevert(abi.encodeWithSelector(MintZap.BadPool.selector, poolAddrs[1]));
        new MintZap(fund, address(usdc), w, ICLPool(address(wethPool)), ps);

        vm.expectRevert(abi.encodeWithSelector(MintZap.BadPool.selector, address(0)));
        new MintZap(fund, address(usdc), w, ICLPool(address(wethPool)), new address[](2));

        vm.expectRevert(abi.encodeWithSelector(MintZap.BadPool.selector, poolAddrs[0]));
        new MintZap(fund, address(usdc), w, ICLPool(poolAddrs[0]), poolAddrs);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_mintsExactlyAtTheQuote(uint256 shares, uint256 nvdaPrice, uint8 route) public {
        shares = bound(shares, 1, 10_000e18);
        feeds[0].setPrice(int256(bound(nvdaPrice, 1e8, 10_000e8)));
        (uint256 quotedUsdc, uint256 quotedEth) = zap.quoteMint(shares);
        (uint256 toMinter,) = fund.previewMintFee(shares);

        uint256 spent;
        route %= 3;
        if (route == 2) {
            _giveWeth(alice, quotedEth + stocks.length);
            vm.startPrank(alice);
            weth.approve(address(zap), type(uint256).max);
            spent = zap.mintWithWeth(shares, alice, quotedEth + stocks.length, block.timestamp);
            vm.stopPrank();
            assertApproxEqAbs(spent, quotedEth, stocks.length);
            assertEq(weth.balanceOf(alice), quotedEth + stocks.length - spent);
        } else if (route == 1) {
            vm.deal(alice, quotedEth + 1 ether);
            vm.prank(alice);
            spent = zap.mintWithEth{value: quotedEth + stocks.length}(shares, alice, block.timestamp);
            assertApproxEqAbs(spent, quotedEth, stocks.length);
            assertEq(alice.balance, quotedEth + 1 ether - spent);
        } else {
            usdc.mint(alice, quotedUsdc);
            vm.startPrank(alice);
            usdc.approve(address(zap), quotedUsdc);
            spent = zap.mintWithUsdc(shares, alice, quotedUsdc, block.timestamp);
            vm.stopPrank();
            assertEq(spent, quotedUsdc);
            assertEq(usdc.balanceOf(alice), 0);
        }
        assertEq(fund.balanceOf(alice), toMinter);
        _assertZapEmpty();
    }

    // ---------------------------------------------------------------- helpers

    function _giveWeth(address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        weth.deposit{value: amount}();
    }

    function _assertZapEmpty() internal view {
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(stocks[i].balanceOf(address(zap)), 0, "stock left in zap");
        }
        assertEq(usdc.balanceOf(address(zap)), 0, "USDC left in zap");
        assertEq(weth.balanceOf(address(zap)), 0, "WETH left in zap");
    }

    /// @dev Feed value of what a mint of `shares` deposits, in USDC base units.
    function _navOf(uint256 shares) internal view returns (uint256 usdcValue) {
        (, uint256[] memory amounts) = fund.previewMint(shares);
        for (uint256 i; i < stocks.length; ++i) {
            (, int256 p,,,) = feeds[i].latestRoundData();
            usdcValue += amounts[i] * uint256(p) / 1e8 * 1e6 / 10 ** stocks[i].decimals();
        }
    }

    function _signUsdcPermit(uint256 value, uint256 deadline)
        internal
        view
        returns (BlueFund.Permit memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                alice,
                address(zap),
                value,
                usdc.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        return BlueFund.Permit({value: value, deadline: deadline, v: v, r: r, s: s});
    }
}
