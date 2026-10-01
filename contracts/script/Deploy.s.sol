// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipBurner} from "../src/ChipBurner.sol";
import {ChipSwapper} from "../src/ChipSwapper.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {AerodromeSwapper} from "../src/AerodromeSwapper.sol";
import {MintZap} from "../src/MintZap.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";

/// @notice Mainnet deploy: BlueFund over the real stock tokens and the rebalancer trading through
///         the stocks' Aerodrome USDC pools. With CHIP_ADDRESS (and its v4 pool key from
///         scripts/chip-pool.mjs) it also deploys the CHIP burner as the fee recipient; without it,
///         mint fees go to FEE_RECIPIENT (default: the owner) until script/DeployBurner.s.sol.
///         Last comes the zap that mints the fund for USDC or ETH through the same pools.
///         FUND=<id> deploys another fund from basket/<id>.json (default: BLUE, see DeploymentIO).
///         Never calls the stock tokens (they are chain-native and can't run in forge's simulator),
///         so seeding is a separate step: scripts/seed.sh.
///
///   [CHIP_ADDRESS=0x... CHIP_POOL_FEE=... CHIP_POOL_TICK_SPACING=... CHIP_POOL_HOOKS=0x...] \
///   [FUND=blueai] [OWNER=0x...] [UPDATER=0x...] [KEEPER=0x...] [MINT_FEE_BPS=30] [SUPPLY_CAP=...] \
///   forge script script/Deploy.s.sol --rpc-url base --account deployer --broadcast --verify
contract Deploy is DeploymentIO {
    function run() external returns (BlueFund fund, Rebalancer rebalancer, ChipBurner burner) {
        Basket memory b = _readBasket();
        address chip = vm.envOr("CHIP_ADDRESS", address(0));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);

        // Swappers first: they don't depend on the fund.
        AerodromeSwapper swapper = new AerodromeSwapper(b.usdc, b.addresses, b.pools);
        ChipSwapper chipSwapper =
            chip == address(0) ? ChipSwapper(address(0)) : _deployChipSwapper(b.usdc, chip);

        // Then the fund, its rebalancer and (with CHIP) its burner, whose addresses it needs.
        fund = _deployFund(b, deployer, owner, chip != address(0));
        rebalancer = _deployRebalancer(fund, swapper, b, owner);
        if (chip != address(0)) {
            burner = new ChipBurner(
                fund,
                IChip(chip),
                b.usdc,
                ISwapper(address(swapper)),
                ISwapper(address(chipSwapper)),
                owner,
                vm.envOr("KEEPER", owner)
            );
            require(address(burner) == fund.feeRecipient(), "burner address mismatch");
        }
        MintZap zap = _deployZap(fund, b);
        vm.stopBroadcast();
        require(address(rebalancer) == fund.rebalancer(), "rebalancer address mismatch");

        _writeDeployment(
            b,
            address(fund),
            address(burner),
            chip,
            address(rebalancer),
            address(swapper),
            b.addresses,
            b.symbols,
            b.feeds,
            address(0)
        );
        _setDeploymentAddress("zap", address(zap));
        _setDeploymentAddress("usdc", b.usdc);
        _setDeploymentAddress("weth", address(zap.weth()));
    }

    /// @dev The rebalancer is the next contract after the fund and the burner the one after that.
    function _deployFund(Basket memory b, address deployer, address owner, bool withBurner)
        private
        returns (BlueFund)
    {
        uint256 nonce = vm.getNonce(deployer);
        address feeRecipient =
            withBurner ? vm.computeCreateAddress(deployer, nonce + 2) : vm.envOr("FEE_RECIPIENT", owner);
        return new BlueFund(
            b.tokenName,
            b.tokenSymbol,
            b.addresses,
            b.units,
            owner,
            feeRecipient,
            vm.envOr("MINT_FEE_BPS", uint256(30)),
            vm.envOr("SUPPLY_CAP", uint256(1_000e18)),
            vm.computeCreateAddress(deployer, nonce + 1)
        );
    }

    function _deployRebalancer(BlueFund fund, AerodromeSwapper swapper, Basket memory b, address owner)
        private
        returns (Rebalancer)
    {
        return new Rebalancer(
            fund,
            ISwapper(address(swapper)),
            b.feeds,
            _decimals(b),
            b.floatShares,
            b.multipliers,
            owner,
            vm.envOr("UPDATER", owner),
            _rebalancerParams()
        );
    }

    function _deployChipSwapper(address usdc, address chip) internal returns (ChipSwapper) {
        return new ChipSwapper(
            usdc,
            WETH,
            chip,
            ICLPool(USDC_WETH_POOL),
            IPoolManager(POOL_MANAGER),
            uint24(vm.envUint("CHIP_POOL_FEE")),
            int24(vm.envInt("CHIP_POOL_TICK_SPACING")),
            vm.envAddress("CHIP_POOL_HOOKS")
        );
    }
}
