// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";

/// @notice Reads the basket and writes deployments/<chainId>.json, which the site imports.
abstract contract DeploymentIO is Script {
    string internal constant BASKET = "basket/mag7.json";

    struct Basket {
        string[] symbols;
        address[] addresses;
        address[] feeds;
        address[] pools;
        uint256[] decimals;
        uint256[] floatShares;
        uint256[] multipliers;
        uint256[] prices;
        uint256[] units;
        address usdc;
    }

    function _readBasket() internal view returns (Basket memory b) {
        string memory json = vm.readFile(BASKET);
        b.symbols = vm.parseJsonStringArray(json, ".symbols");
        b.addresses = vm.parseJsonAddressArray(json, ".addresses");
        b.feeds = vm.parseJsonAddressArray(json, ".feeds");
        b.pools = vm.parseJsonAddressArray(json, ".pools");
        b.decimals = vm.parseJsonUintArray(json, ".decimals");
        b.floatShares = vm.parseJsonUintArray(json, ".floatShares");
        b.multipliers = vm.parseJsonUintArray(json, ".multipliers");
        b.prices = vm.parseJsonUintArray(json, ".prices");
        b.units = vm.parseJsonUintArray(json, ".units");
        b.usdc = vm.parseJsonAddress(json, ".usdc");
    }

    function _decimals(Basket memory b) internal pure returns (uint8[] memory d) {
        d = new uint8[](b.decimals.length);
        for (uint256 i; i < d.length; ++i) {
            d[i] = uint8(b.decimals[i]);
        }
    }

    /// @dev Launch settings: 0.5% max slippage vs the oracle, trades of at most 1% of NAV and at
    ///      least 0.05%, 30 minutes apart, on prices at most 6 hours old.
    function _rebalancerParams() internal view returns (Rebalancer.Params memory) {
        return Rebalancer.Params({
            maxSlippageBps: vm.envOr("MAX_SLIPPAGE_BPS", uint256(50)),
            maxTradeBps: vm.envOr("MAX_TRADE_BPS", uint256(100)),
            minTradeBps: vm.envOr("MIN_TRADE_BPS", uint256(5)),
            cooldown: vm.envOr("COOLDOWN", uint256(30 minutes)),
            maxFeedAge: vm.envOr("MAX_FEED_AGE", uint256(6 hours))
        });
    }

    function _writeDeployment(
        address fund,
        address vault,
        address chip,
        address rebalancer,
        address swapper,
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
        vm.serializeAddress(k, "rebalancer", rebalancer);
        vm.serializeAddress(k, "swapper", swapper);
        vm.serializeAddress(k, "tokens", tokens);
        vm.serializeAddress(k, "feeds", feeds);
        if (mock) vm.serializeAddress(k, "faucet", faucet);
        string memory out = vm.serializeString(k, "symbols", symbols);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
    }
}
