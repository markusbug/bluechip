// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {MintZap} from "../src/MintZap.sol";

/// @notice For a fund deployed before the zap existed: deploys MintZap (mint BLUE with USDC, ETH or
///         WETH) over the fund in deployments/<chainId>.json and the stocks' Aerodrome USDC pools from
///         the basket, and records it (and USDC and WETH) there for the site. It has no owner and needs
///         nothing from the fund's owner. Running it again replaces the zap the site uses; an older one
///         keeps working for anyone who calls it directly.
///
///   forge script script/DeployZap.s.sol --rpc-url base --account deployer --broadcast --verify
contract DeployZap is DeploymentIO {
    function run() external returns (MintZap zap) {
        Basket memory b = _readBasket();
        BlueFund fund = BlueFund(vm.parseJsonAddress(vm.readFile(_deploymentPath()), ".fund"));

        vm.startBroadcast();
        zap = _deployZap(fund, b);
        vm.stopBroadcast();

        _setDeploymentAddress("zap", address(zap));
        _setDeploymentAddress("usdc", b.usdc);
        _setDeploymentAddress("weth", address(zap.weth()));
    }
}
