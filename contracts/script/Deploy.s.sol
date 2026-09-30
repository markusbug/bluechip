// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipVault} from "../src/ChipVault.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {AerodromeSwapper} from "../src/AerodromeSwapper.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mainnet deploy: BlueFund over the real stock tokens, ChipVault over the Bankr-launched
///         CHIP, and the rebalancer trading through the stocks' Aerodrome USDC pools.
///         Never calls the stock tokens (they are chain-native and can't run in forge's simulator),
///         so seeding is a separate step: scripts/seed.sh.
///
///   CHIP_ADDRESS=0x... [OWNER=0x...] [UPDATER=0x...] [MINT_FEE_BPS=30] \
///   [SUPPLY_CAP=1000000000000000000000] \
///   forge script script/Deploy.s.sol --rpc-url base --account deployer --broadcast --verify
contract Deploy is DeploymentIO {
    function run() external returns (BlueFund fund, ChipVault vault, Rebalancer rebalancer) {
        Basket memory b = _readBasket();
        IChip chip = IChip(vm.envAddress("CHIP_ADDRESS"));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);
        // The fund's fee recipient is the vault and its rebalancer comes last: predict both.
        uint256 nonce = vm.getNonce(deployer);
        address predictedVault = vm.computeCreateAddress(deployer, nonce + 1);
        address predictedRebalancer = vm.computeCreateAddress(deployer, nonce + 3);
        fund = new BlueFund(
            "Bluechip Index",
            "BLUE",
            b.addresses,
            b.units,
            owner,
            predictedVault,
            vm.envOr("MINT_FEE_BPS", uint256(30)),
            vm.envOr("SUPPLY_CAP", uint256(1_000e18)),
            predictedRebalancer
        );
        vault = new ChipVault(IERC20(address(fund)), chip);
        AerodromeSwapper swapper = new AerodromeSwapper(b.usdc, b.addresses, b.pools);
        rebalancer = _deployRebalancer(fund, swapper, b, owner);
        vm.stopBroadcast();
        require(address(vault) == predictedVault, "vault address mismatch");
        require(address(rebalancer) == predictedRebalancer, "rebalancer address mismatch");

        _writeDeployment(
            address(fund),
            address(vault),
            address(chip),
            address(rebalancer),
            address(swapper),
            b.addresses,
            b.symbols,
            b.feeds,
            address(0)
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
}
