// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipBurner} from "../src/ChipBurner.sol";
import {ChipSwapper} from "../src/ChipSwapper.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";

/// @notice For a fund deployed before CHIP existed: deploys the CHIP swapper and burner next to the
///         fund in deployments/<chainId>.json and records them there. The fund owner then points
///         the mint fee at the burner:
///           cast send <fund> "setFeeRecipient(address)" <burner>
///
///   CHIP_ADDRESS=0x... CHIP_POOL_FEE=... CHIP_POOL_TICK_SPACING=... CHIP_POOL_HOOKS=0x... \
///   [OWNER=0x...] [KEEPER=0x...] \
///   forge script script/DeployBurner.s.sol --rpc-url base --account deployer --broadcast --verify
contract DeployBurner is DeploymentIO {
    function run() external returns (ChipBurner burner) {
        Basket memory b = _readBasket();
        string memory json = vm.readFile(_deploymentPath());
        BlueFund fund = BlueFund(vm.parseJsonAddress(json, ".fund"));
        address swapper = vm.parseJsonAddress(json, ".swapper");
        address chip = vm.envAddress("CHIP_ADDRESS");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);
        ChipSwapper chipSwapper = new ChipSwapper(
            b.usdc,
            WETH,
            chip,
            ICLPool(USDC_WETH_POOL),
            IPoolManager(POOL_MANAGER),
            uint24(vm.envUint("CHIP_POOL_FEE")),
            int24(vm.envInt("CHIP_POOL_TICK_SPACING")),
            vm.envAddress("CHIP_POOL_HOOKS")
        );
        burner = new ChipBurner(
            fund,
            IChip(chip),
            b.usdc,
            ISwapper(swapper),
            ISwapper(address(chipSwapper)),
            owner,
            vm.envOr("KEEPER", owner)
        );
        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(burner)), _deploymentPath(), ".burner");
        vm.writeJson(vm.toString(chip), _deploymentPath(), ".chip");
    }
}
