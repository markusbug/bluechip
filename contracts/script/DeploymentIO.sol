// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

/// @notice Reads the basket and writes deployments/<chainId>.json, which the site imports.
abstract contract DeploymentIO is Script {
    string internal constant BASKET = "basket/mag7.json";

    struct Basket {
        string[] symbols;
        address[] addresses;
        address[] feeds;
        uint256[] units;
    }

    function _readBasket() internal view returns (Basket memory b) {
        string memory json = vm.readFile(BASKET);
        b.symbols = vm.parseJsonStringArray(json, ".symbols");
        b.addresses = vm.parseJsonAddressArray(json, ".addresses");
        b.feeds = vm.parseJsonAddressArray(json, ".feeds");
        b.units = vm.parseJsonUintArray(json, ".units");
    }

    function _writeDeployment(
        address fund,
        address vault,
        address chip,
        address[] memory tokens,
        string[] memory symbols,
        address[] memory feeds,
        address faucet
    ) internal {
        string memory k = "deployment";
        bool mock = faucet != address(0);
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "startBlock", block.number);
        vm.serializeBool(k, "mock", mock);
        vm.serializeAddress(k, "fund", fund);
        vm.serializeAddress(k, "vault", vault);
        vm.serializeAddress(k, "chip", chip);
        vm.serializeAddress(k, "tokens", tokens);
        vm.serializeAddress(k, "feeds", feeds);
        if (mock) vm.serializeAddress(k, "faucet", faucet);
        string memory out = vm.serializeString(k, "symbols", symbols);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
    }
}
