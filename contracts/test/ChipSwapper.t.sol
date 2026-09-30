// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ChipSwapper} from "../src/ChipSwapper.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {IPoolManager, PoolKey} from "../src/interfaces/IPoolManager.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @notice The USDC -> WETH -> CHIP route against a Slipstream-shaped pool and a v4-shaped
///         PoolManager. test/fork/ChipSwapperFork.t.sol runs the same route against Base mainnet.
contract ChipSwapperTest is Test {
    MockStock internal usdc;
    MockStock internal weth;
    MockStock internal chip;
    MockCLPool internal usdcWeth;
    MockPoolManager internal pm;
    ChipSwapper internal swapper;
    address internal hooks = makeAddr("hooks");
    address internal burner = makeAddr("burner");

    function _deploy(bool chipIsCurrency0) internal {
        usdc = new MockStock("USD Coin", "USDC", 6);
        weth = new MockStock("Wrapped Ether", "WETH", 18);
        chip = new MockStock("Chip", "CHIP", 18);
        // Put CHIP on the side of WETH the test asks for.
        if ((address(chip) < address(weth)) != chipIsCurrency0) (weth, chip) = (chip, weth);
        vm.label(address(weth), "WETH");
        vm.label(address(chip), "CHIP");

        // ETH at $2,500: token1 per 1e18 token0.
        usdcWeth = address(usdc) < address(weth)
            ? new MockCLPool(address(usdc), address(weth), 1e18 * 1e18 / 2_500e6)
            : new MockCLPool(address(weth), address(usdc), 2_500e6);
        // CHIP at 0.000004 ETH ($0.01): 250,000 CHIP per ETH either way round.
        (address c0, address c1) =
            address(weth) < address(chip) ? (address(weth), address(chip)) : (address(chip), address(weth));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 200, hooks: hooks});
        pm = new MockPoolManager(key, c0 == address(weth) ? 250_000e18 : 1e18 / 250_000);
        weth.mint(address(usdcWeth), 1e30);
        usdc.mint(address(usdcWeth), 1e30);
        chip.mint(address(pm), 1e30);

        swapper = new ChipSwapper(
            address(usdc),
            address(weth),
            address(chip),
            ICLPool(address(usdcWeth)),
            IPoolManager(address(pm)),
            0x800000,
            200,
            hooks
        );
    }

    function _buy(uint256 usdcIn) internal returns (uint256 out) {
        usdc.mint(address(swapper), usdcIn);
        vm.prank(burner);
        out = swapper.swap(address(usdc), address(chip), usdcIn, burner);
    }

    function test_buysChipWethFirst() public {
        _deploy(false);
        uint256 out = _buy(100e6); // $100 -> 10,000 CHIP
        assertApproxEqRel(out, 10_000e18, 1e12);
        assertEq(chip.balanceOf(burner), out);
        _assertEmpty();
    }

    function test_buysChipChipFirst() public {
        _deploy(true);
        uint256 out = _buy(100e6);
        assertApproxEqRel(out, 10_000e18, 1e12);
        assertEq(chip.balanceOf(burner), out);
        _assertEmpty();
    }

    function test_hookFeeComesOutOfTheOutput() public {
        _deploy(false);
        pm.setHookFee(100); // 1%
        uint256 out = _buy(100e6);
        assertApproxEqRel(out, 9_900e18, 1e12);
        _assertEmpty();
    }

    function test_poolKey() public {
        _deploy(false);
        PoolKey memory key = swapper.poolKey();
        assertEq(key.currency0, address(weth) < address(chip) ? address(weth) : address(chip));
        assertEq(key.fee, 0x800000);
        assertEq(key.tickSpacing, 200);
        assertEq(key.hooks, hooks);
    }

    function test_onlyUsdcToChip() public {
        _deploy(false);
        vm.expectRevert(abi.encodeWithSelector(ChipSwapper.BadRoute.selector, address(chip), address(usdc)));
        swapper.swap(address(chip), address(usdc), 1, burner);
        vm.expectRevert(abi.encodeWithSelector(ChipSwapper.BadRoute.selector, address(usdc), address(weth)));
        swapper.swap(address(usdc), address(weth), 1, burner);
    }

    function test_callbacksOnlyFromThePools() public {
        _deploy(false);
        vm.expectRevert(ChipSwapper.UnexpectedCallback.selector);
        swapper.unlockCallback(abi.encode(uint256(1), burner));
        vm.expectRevert(ChipSwapper.UnexpectedCallback.selector);
        vm.prank(address(usdcWeth)); // the right pool, but no swap in progress
        swapper.uniswapV3SwapCallback(1, 0, "");
    }

    function test_constructorChecksThePool() public {
        _deploy(false);
        MockStock other = new MockStock("Other", "X", 18);
        MockCLPool wrong = new MockCLPool(address(other), address(weth), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ChipSwapper.BadPool.selector, address(wrong)));
        new ChipSwapper(
            address(usdc),
            address(weth),
            address(chip),
            ICLPool(address(wrong)),
            IPoolManager(address(pm)),
            0,
            1,
            hooks
        );
    }

    function _assertEmpty() internal view {
        assertEq(usdc.balanceOf(address(swapper)), 0);
        assertEq(weth.balanceOf(address(swapper)), 0);
        assertEq(chip.balanceOf(address(swapper)), 0);
    }
}
