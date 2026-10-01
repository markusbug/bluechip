// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {MintZap} from "../src/MintZap.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";

/// @notice Reads a fund's basket and writes its deployment file, which the site imports.
///         FUND (default "blue") picks the fund, by the same rule as scripts/lib/fund.mjs:
///         blue    basket/mag7.json    deployments/<chainId>.json
///         <id>    basket/<id>.json    deployments/<chainId>-<id>.json
abstract contract DeploymentIO is Script {
    string internal constant DEFAULT_FUND = "blue";

    // Base mainnet. WETH and the Uniswap v4 PoolManager are fixed; the pool is Aerodrome
    // Slipstream's deepest USDC/WETH pool.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_WETH_POOL = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    struct Basket {
        string tokenName;
        string tokenSymbol;
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

    function _fund() internal view returns (string memory) {
        return vm.envOr("FUND", DEFAULT_FUND);
    }

    function _isDefaultFund() internal view returns (bool) {
        return keccak256(bytes(_fund())) == keccak256(bytes(DEFAULT_FUND));
    }

    function _basketPath() internal view returns (string memory) {
        return string.concat("basket/", _isDefaultFund() ? "mag7" : _fund(), ".json");
    }

    function _readBasket() internal view returns (Basket memory b) {
        string memory json = vm.readFile(_basketPath());
        // BLUE's basket was generated before the token name was part of it.
        b.tokenName =
            vm.keyExistsJson(json, ".tokenName") ? vm.parseJsonString(json, ".tokenName") : "Bluechip Index";
        b.tokenSymbol =
            vm.keyExistsJson(json, ".tokenSymbol") ? vm.parseJsonString(json, ".tokenSymbol") : "BLUE";
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

    /// @dev The zap buys each stock in the pool the rebalancer trades in, and ETH's USDC in USDC_WETH_POOL.
    function _deployZap(BlueFund fund, Basket memory b) internal returns (MintZap) {
        return new MintZap(fund, b.usdc, IWETH(WETH), ICLPool(USDC_WETH_POOL), b.pools);
    }

    function _deploymentPath() internal view returns (string memory) {
        string memory suffix = _isDefaultFund() ? "" : string.concat("-", _fund());
        return string.concat("deployments/", vm.toString(block.chainid), suffix, ".json");
    }

    /// @dev Add or replace one address in the deployment file, keeping everything else.
    ///      (`vm.writeJson(value, path, key)` only replaces keys that already exist.)
    function _setDeploymentAddress(string memory key, address value) internal {
        string memory k = "existing";
        vm.serializeJson(k, vm.readFile(_deploymentPath()));
        vm.writeJson(vm.serializeAddress(k, key, value), _deploymentPath());
    }

    function _writeDeployment(
        Basket memory b,
        address fund,
        address burner,
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
        vm.serializeString(k, "id", _fund());
        vm.serializeString(k, "name", b.tokenName);
        vm.serializeString(k, "symbol", b.tokenSymbol);
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "startBlock", block.number);
        vm.serializeBool(k, "mock", mock);
        vm.serializeAddress(k, "fund", fund);
        vm.serializeAddress(k, "burner", burner);
        vm.serializeAddress(k, "chip", chip);
        vm.serializeAddress(k, "rebalancer", rebalancer);
        vm.serializeAddress(k, "swapper", swapper);
        vm.serializeAddress(k, "tokens", tokens);
        vm.serializeAddress(k, "feeds", feeds);
        if (mock) vm.serializeAddress(k, "faucet", faucet);
        string memory out = vm.serializeString(k, "symbols", symbols);
        vm.writeJson(out, _deploymentPath());
    }
}
