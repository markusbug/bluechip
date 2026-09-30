// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipVault} from "../src/ChipVault.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mainnet deploy: BlueFund over the real stock tokens + ChipVault over the Bankr-launched CHIP.
///         Never calls the stock tokens (they are chain-native and can't run in forge's simulator),
///         so seeding is a separate step: scripts/seed.sh.
///
///   CHIP_ADDRESS=0x... [OWNER=0x...] [MINT_FEE_BPS=30] [SUPPLY_CAP=1000000000000000000000] \
///   forge script script/Deploy.s.sol --rpc-url base --account deployer --broadcast --verify
contract Deploy is DeploymentIO {
    function run() external returns (BlueFund fund, ChipVault vault) {
        Basket memory b = _readBasket();
        IChip chip = IChip(vm.envAddress("CHIP_ADDRESS"));
        uint256 feeBps = vm.envOr("MINT_FEE_BPS", uint256(30));
        uint256 cap = vm.envOr("SUPPLY_CAP", uint256(1_000e18));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);
        // The fund's fee recipient is the vault, deployed right after it.
        address predictedVault = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        fund =
            new BlueFund("Bluechip Index", "BLUE", b.addresses, b.units, owner, predictedVault, feeBps, cap);
        vault = new ChipVault(IERC20(address(fund)), chip);
        vm.stopBroadcast();
        require(address(vault) == predictedVault, "vault address mismatch");

        _writeDeployment(
            address(fund), address(vault), address(chip), b.addresses, b.symbols, b.feeds, address(0)
        );
    }
}
