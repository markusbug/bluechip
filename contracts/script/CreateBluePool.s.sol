// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";

/// @notice The subset of Aerodrome Slipstream's CL factory, pool and position manager this script uses.
interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address);
}

interface ICLPoolSlot0 {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool unlocked);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    function factory() external view returns (address);
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @notice Opens a BLUE/USDC market on Aerodrome Slipstream: creates the pool at BLUE's NAV (the
///         rebalancer's Chainlink valuation over total supply) if it doesn't exist yet, and adds a
///         position about ±20% around that price. The position NFT goes to the broadcaster.
///
///         It spends equal USD values of BLUE and USDC: whichever of BLUE_AMOUNT (wei) and USDC_AMOUNT
///         (6 decimals) is worth less sets the size; both default to the wallet's balance. It approves
///         the position manager for exactly those amounts and clears any leftover allowance. If the
///         pool already exists at a price more than MAX_DEVIATION_BPS (default 100) off NAV, it stops.
///         Run it while the Chainlink prices are fresh (the rebalancer's max feed age), i.e. around
///         the US session.
///
///   BLUE_AMOUNT=50000000000000000 USDC_AMOUNT=5000000 \
///   forge script script/CreateBluePool.s.sol --rpc-url base --account deployer --broadcast
///
///   Optional: TICK_SPACING (default 100, a 0.05% fee), RANGE_TICKS (default 2000, about ±20%).
contract CreateBluePool is DeploymentIO {
    using SafeERC20 for IERC20;

    /// @dev Aerodrome Slipstream's CL factory the stock pools live in, and its position manager.
    ICLFactory internal constant CL_FACTORY = ICLFactory(0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef);
    INonfungiblePositionManager internal constant POSITIONS =
        INonfungiblePositionManager(0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53);

    uint256 internal constant BPS = 10_000;
    /// @dev Each amount may come in this much under the desired one: the range is centred on the
    ///      price only up to tick spacing, so one side can be used slightly less.
    uint256 internal constant MIN_USED_BPS = 9_500;

    function run() external returns (address pool, uint256 tokenId) {
        string memory dep = vm.readFile(_deploymentPath());
        BlueFund fund = BlueFund(vm.parseJsonAddress(dep, ".fund"));
        Rebalancer rebalancer = Rebalancer(vm.parseJsonAddress(dep, ".rebalancer"));
        IERC20 usdc = IERC20(vm.parseJsonAddress(dep, ".usdc"));
        require(POSITIONS.factory() == address(CL_FACTORY), "position manager is on another factory");

        // NAV per whole BLUE in USD, 18 decimals.
        (,,, uint256 nav) = rebalancer.valuation();
        uint256 navPerShare = Math.mulDiv(nav, 1e18, fund.totalSupply());

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        (uint256 blueIn, uint256 usdcIn) = _amounts(fund, usdc, me, navPerShare);
        require(blueIn != 0 && usdcIn != 0, "nothing to add");
        pool = _openPool(address(usdc), address(fund), navPerShare);
        tokenId = _mintPosition(ICLPool(pool), address(usdc), usdcIn, blueIn, me);
        vm.stopBroadcast();

        _setDeploymentAddress("bluePool", pool);
        console.log("NAV per BLUE (USD, 18 decimals):", navPerShare);
        console.log("pool:", pool);
        console.log("position NFT:", tokenId);
    }

    function _tickSpacing() internal view returns (int24) {
        return int24(vm.envOr("TICK_SPACING", int256(100)));
    }

    /// @dev The BLUE/USDC pool at this tick spacing, created at NAV if it doesn't exist.
    function _openPool(address usdc, address blue, uint256 navPerShare) internal returns (address pool) {
        bool usdcIsToken0 = usdc < blue;
        uint160 sqrtPriceX96 = _sqrtPriceX96(usdcIsToken0, navPerShare);
        pool = CL_FACTORY.getPool(usdc, blue, _tickSpacing());
        if (pool == address(0)) {
            pool = CL_FACTORY.createPool(usdc, blue, _tickSpacing(), sqrtPriceX96);
        } else {
            _checkPrice(pool, sqrtPriceX96);
        }
    }

    /// @dev Adds the position with exact approvals, and clears them again if the position manager
    ///      used less.
    function _mintPosition(ICLPool pool, address usdc, uint256 usdcIn, uint256 blueIn, address me)
        internal
        returns (uint256 tokenId)
    {
        bool usdcIsToken0 = pool.token0() == usdc;
        INonfungiblePositionManager.MintParams memory p =
            _mintParams(pool, usdcIsToken0 ? usdcIn : blueIn, usdcIsToken0 ? blueIn : usdcIn, me);
        IERC20(p.token0).forceApprove(address(POSITIONS), p.amount0Desired);
        IERC20(p.token1).forceApprove(address(POSITIONS), p.amount1Desired);
        (uint256 id,, uint256 used0, uint256 used1) = POSITIONS.mint(p);
        if (used0 < p.amount0Desired) IERC20(p.token0).forceApprove(address(POSITIONS), 0);
        if (used1 < p.amount1Desired) IERC20(p.token1).forceApprove(address(POSITIONS), 0);
        console.log("USDC used:", usdcIsToken0 ? used0 : used1);
        console.log("BLUE used:", usdcIsToken0 ? used1 : used0);
        return id;
    }

    /// @dev A position RANGE_TICKS either side of the pool's current tick.
    function _mintParams(ICLPool pool, uint256 amount0, uint256 amount1, address me)
        internal
        view
        returns (INonfungiblePositionManager.MintParams memory)
    {
        int24 spacing = _tickSpacing();
        int24 rangeTicks = int24(vm.envOr("RANGE_TICKS", int256(2000)));
        (, int24 tick,,,,) = ICLPoolSlot0(address(pool)).slot0();
        return INonfungiblePositionManager.MintParams({
            token0: pool.token0(),
            token1: pool.token1(),
            tickSpacing: spacing,
            tickLower: _floorTick(tick - rangeTicks, spacing),
            tickUpper: _floorTick(tick + rangeTicks, spacing) + spacing,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0 * MIN_USED_BPS / BPS,
            amount1Min: amount1 * MIN_USED_BPS / BPS,
            recipient: me,
            deadline: block.timestamp + 30 minutes,
            sqrtPriceX96: 0
        });
    }

    /// @dev The requested amounts (default: the whole balance), trimmed to equal USD value at NAV.
    function _amounts(BlueFund fund, IERC20 usdc, address me, uint256 navPerShare)
        internal
        view
        returns (uint256 blueIn, uint256 usdcIn)
    {
        blueIn = vm.envOr("BLUE_AMOUNT", fund.balanceOf(me));
        usdcIn = vm.envOr("USDC_AMOUNT", usdc.balanceOf(me));
        // BLUE has 18 decimals and USDC 6, so one BLUE-wei is worth navPerShare / 1e30 USDC units.
        uint256 blueValue = Math.mulDiv(blueIn, navPerShare, 1e30);
        if (usdcIn > blueValue) usdcIn = blueValue;
        else blueIn = Math.mulDiv(usdcIn, 1e30, navPerShare);
    }

    /// @dev sqrt(token1 per token0, in base units) as a Q64.96. With USDC as token0 the price is
    ///      1e30 / navPerShare BLUE-wei per USDC unit, else its inverse.
    function _sqrtPriceX96(bool usdcIsToken0, uint256 navPerShare) internal pure returns (uint160) {
        return usdcIsToken0
            ? SafeCast.toUint160(Math.sqrt(Math.mulDiv(1e30, 1 << 64, navPerShare)) << 64)
            : SafeCast.toUint160(Math.sqrt(Math.mulDiv(navPerShare, 1 << 192, 1e30)));
    }

    /// @dev An existing pool must trade within MAX_DEVIATION_BPS of NAV, or the position would be
    ///      added at someone else's price.
    function _checkPrice(address pool, uint160 target) internal view {
        (uint160 current,,,,,) = ICLPoolSlot0(pool).slot0();
        uint256 maxDeviationBps = vm.envOr("MAX_DEVIATION_BPS", uint256(100));
        // Price is the square of sqrtPrice, so a price band of ±d is about ±d/2 in sqrtPrice.
        uint256 band = uint256(target) * maxDeviationBps / (2 * BPS);
        require(current + band >= target && current <= target + band, "existing pool is too far from NAV");
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 t = tick / spacing * spacing;
        return tick < 0 && t != tick ? t - spacing : t;
    }
}
