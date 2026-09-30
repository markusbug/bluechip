// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChipSwapper} from "../../src/ChipSwapper.sol";
import {ICLPool} from "../../src/interfaces/ICLPool.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";

/// @notice The real route on a Base mainnet fork: USDC -> WETH in Aerodrome's USDC/WETH pool, then
///         WETH -> a live Bankr-launched token in its Uniswap v4 pool, through Bankr's hook. CHIP is
///         launched the same way, so this is the path its burner will take.
///         Skipped unless BASE_FORK_URL is set:
///
///   BASE_FORK_URL=https://mainnet.base.org forge test --match-contract ChipSwapperForkTest -vv
contract ChipSwapperForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC_WETH_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    // A Bankr token and its v4 pool key (scripts/chip-pool.mjs prints these for any Bankr token).
    address constant TOKEN = 0x7D83a652211b8E320068dDE00f1AF6f63571fBa3;
    uint24 constant FEE = 0x800000; // dynamic, set by the hook
    int24 constant TICK_SPACING = 200;
    address constant HOOKS = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;

    ChipSwapper internal swapper;
    address internal burner = makeAddr("burner");

    function setUp() public {
        string memory url = vm.envOr("BASE_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        swapper = new ChipSwapper(
            USDC, WETH, TOKEN, ICLPool(USDC_WETH_POOL), IPoolManager(POOL_MANAGER), FEE, TICK_SPACING, HOOKS
        );
    }

    function test_buysABankrTokenWithUsdc() public {
        uint256 usdcIn = 25e6;
        deal(USDC, address(swapper), usdcIn);
        uint256 before = IERC20(TOKEN).balanceOf(burner);

        vm.prank(burner);
        uint256 out = swapper.swap(USDC, TOKEN, usdcIn, burner);

        emit log_named_decimal_uint("USDC in", usdcIn, 6);
        emit log_named_decimal_uint("tokens out", out, 18);
        assertGt(out, 0);
        assertEq(IERC20(TOKEN).balanceOf(burner) - before, out);
        assertEq(IERC20(USDC).balanceOf(address(swapper)), 0);
        assertEq(IERC20(WETH).balanceOf(address(swapper)), 0);
        assertEq(IERC20(TOKEN).balanceOf(address(swapper)), 0);
    }
}
