// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AerodromeSwapper} from "../src/AerodromeSwapper.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";

contract AerodromeSwapperTest is Test {
    MockStock internal usdc;
    MockStock internal nvda;
    MockStock internal aapl;
    MockCLPool internal nvdaPool;
    MockCLPool internal aaplPool;
    AerodromeSwapper internal swapper;
    address internal fund = makeAddr("fund");

    function setUp() public {
        usdc = new MockStock("USD Coin", "USDC", 6);
        nvda = new MockStock("NVIDIA", "NVDAc", 8);
        aapl = new MockStock("Apple", "AAPLc", 8);
        // USDC is token0 in the real pools. Price: token1 per 1e18 token0, in base units.
        // NVDA at $200: 1 USDC (1e6) buys 0.005 NVDA (5e5) -> 5e5 * 1e18 / 1e6.
        nvdaPool = new MockCLPool(address(usdc), address(nvda), 5e17);
        // Put AAPL on the other side to cover both swap directions: AAPL/USDC at $250.
        aaplPool = new MockCLPool(address(aapl), address(usdc), 250e6 * 1e18 / 1e8);
        for (uint256 i; i < 2; ++i) {
            usdc.mint(address(nvdaPool), 1e15);
            usdc.mint(address(aaplPool), 1e15);
        }
        nvda.mint(address(nvdaPool), 1e15);
        aapl.mint(address(aaplPool), 1e15);

        address[] memory tokens = new address[](2);
        tokens[0] = address(nvda);
        tokens[1] = address(aapl);
        address[] memory pools = new address[](2);
        pools[0] = address(nvdaPool);
        pools[1] = address(aaplPool);
        swapper = new AerodromeSwapper(address(usdc), tokens, pools);
    }

    function test_swapsThroughUsdc() public {
        // 1 NVDA ($200) -> 200 USDC -> 0.8 AAPL ($250).
        nvda.mint(address(swapper), 1e8);
        vm.prank(fund);
        uint256 out = swapper.swap(address(nvda), address(aapl), 1e8, fund);
        assertEq(out, 0.8e8);
        assertEq(aapl.balanceOf(fund), 0.8e8);
        // Nothing stays behind.
        assertEq(nvda.balanceOf(address(swapper)), 0);
        assertEq(usdc.balanceOf(address(swapper)), 0);
        assertEq(aapl.balanceOf(address(swapper)), 0);

        // And back the other way.
        aapl.mint(address(swapper), 0.8e8);
        out = swapper.swap(address(aapl), address(nvda), 0.8e8, fund);
        assertEq(out, 1e8);
    }

    function test_singleHopWithUsdc() public {
        // Stock -> USDC (the CHIP burner's leg): 1 NVDA -> $200.
        nvda.mint(address(swapper), 1e8);
        uint256 out = swapper.swap(address(nvda), address(usdc), 1e8, fund);
        assertEq(out, 200e6);
        assertEq(usdc.balanceOf(fund), 200e6);
        // And USDC -> stock: $250 -> 1 AAPL.
        usdc.mint(address(swapper), 250e6);
        out = swapper.swap(address(usdc), address(aapl), 250e6, fund);
        assertEq(out, 1e8);
        assertEq(nvda.balanceOf(address(swapper)) + usdc.balanceOf(address(swapper)), 0);
    }

    function test_rejectsUnknownToken() public {
        MockStock other = new MockStock("Other", "X", 8);
        vm.expectRevert(abi.encodeWithSelector(AerodromeSwapper.NoPool.selector, address(other)));
        swapper.swap(address(other), address(aapl), 1, fund);
    }

    function test_callbackOnlyFromActivePool() public {
        vm.expectRevert(AerodromeSwapper.UnexpectedCallback.selector);
        vm.prank(address(nvdaPool));
        swapper.uniswapV3SwapCallback(1, 0, abi.encode(address(nvda)));

        vm.expectRevert(AerodromeSwapper.UnexpectedCallback.selector);
        swapper.uniswapV3SwapCallback(1, 0, abi.encode(address(nvda)));
    }

    function test_cannotPayMoreThanItHolds() public {
        // A pool asking for more than the swap's input finds nothing extra to take.
        nvdaPool.setOvercharge(1);
        nvda.mint(address(swapper), 1e8);
        vm.expectRevert();
        swapper.swap(address(nvda), address(aapl), 1e8, fund);
    }

    function test_constructorChecksPools() public {
        address[] memory tokens = new address[](1);
        address[] memory pools = new address[](1);
        tokens[0] = address(aapl);
        pools[0] = address(nvdaPool); // USDC/NVDA, not AAPL
        vm.expectRevert(abi.encodeWithSelector(AerodromeSwapper.BadPool.selector, address(nvdaPool)));
        new AerodromeSwapper(address(usdc), tokens, pools);

        vm.expectRevert(abi.encodeWithSelector(AerodromeSwapper.BadPool.selector, address(0)));
        new AerodromeSwapper(address(usdc), tokens, new address[](2));
    }
}
