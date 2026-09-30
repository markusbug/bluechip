// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipVault} from "../src/ChipVault.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockChip} from "../src/mocks/MockChip.sol";
import {MockBasketFaucet} from "../src/mocks/MockBasketFaucet.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";
import {MockOracleSwapper} from "../src/mocks/MockOracleSwapper.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Local / Base Sepolia: mock stocks with the real symbols and seed ratio, a mock CHIP,
///         mock price feeds at the basket's snapshot prices, an oracle-priced mock DEX, and the fund,
///         vault and rebalancer, seeded and ready. The rebalancer only trades in the US regular
///         session and needs fresh prices: poke the feeds with `setPrice` to test it.
///         SKEW_INDEX_BPS (test only) raises the last constituent's float in the rebalancer's first
///         index, so the fund starts off target and trades can be tested without the 7-day delay.
///
///   forge script script/DeployMocks.s.sol --rpc-url localhost --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract DeployMocks is DeploymentIO {
    struct Mocks {
        address[] tokens;
        address[] feeds;
        MockChip chip;
        MockOracleSwapper swapper;
    }

    function run() external returns (BlueFund fund, ChipVault vault, Rebalancer rebalancer) {
        Basket memory b = _readBasket();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Mocks memory m = _deployMocks(b, deployer);

        uint256 nonce = vm.getNonce(deployer);
        address predictedVault = vm.computeCreateAddress(deployer, nonce + 1);
        address predictedRebalancer = vm.computeCreateAddress(deployer, nonce + 2);
        fund = new BlueFund(
            "Bluechip Index",
            "BLUE",
            m.tokens,
            b.units,
            deployer,
            predictedVault,
            30,
            1_000_000e18,
            predictedRebalancer
        );
        vault = new ChipVault(IERC20(address(fund)), IChip(address(m.chip)));
        rebalancer = new Rebalancer(
            fund,
            ISwapper(address(m.swapper)),
            m.feeds,
            _decimals(b),
            _skewed(b.floatShares),
            b.multipliers,
            deployer,
            deployer,
            _rebalancerParams()
        );
        require(address(vault) == predictedVault, "vault address mismatch");
        require(address(rebalancer) == predictedRebalancer, "rebalancer address mismatch");

        _seed(fund, deployer);
        MockBasketFaucet faucet = new MockBasketFaucet(fund);
        vm.stopBroadcast();

        _writeDeployment(
            address(fund),
            address(vault),
            address(m.chip),
            address(rebalancer),
            address(m.swapper),
            m.tokens,
            b.symbols,
            m.feeds,
            address(faucet)
        );
    }

    /// @dev Mock stocks and feeds at the basket's snapshot prices, mock CHIP, oracle-priced mock DEX.
    function _deployMocks(Basket memory b, address deployer) private returns (Mocks memory m) {
        uint256 n = b.symbols.length;
        m.tokens = new address[](n);
        m.feeds = new address[](n);
        for (uint256 i; i < n; ++i) {
            m.tokens[i] = address(new MockStock(b.symbols[i], b.symbols[i], uint8(b.decimals[i])));
            m.feeds[i] = address(new MockPriceFeed(int256(b.prices[i])));
        }
        m.chip = new MockChip(deployer);
        m.swapper = new MockOracleSwapper(m.tokens, m.feeds, 30);
    }

    function _skewed(uint256[] memory floatShares) private view returns (uint256[] memory) {
        uint256 skew = vm.envOr("SKEW_INDEX_BPS", uint256(0));
        floatShares[floatShares.length - 1] = floatShares[floatShares.length - 1] * (10_000 + skew) / 10_000;
        return floatShares;
    }

    /// @dev Mint the seed basket to the deployer and seed, unless SKIP_SEED leaves it to scripts/seed.sh.
    function _seed(BlueFund fund, address deployer) private {
        uint256 seedShares = vm.envOr("SEED_SHARES", uint256(10e18));
        bool skipSeed = vm.envOr("SKIP_SEED", false);
        (address[] memory tokens, uint256[] memory amounts) = fund.previewMint(seedShares);
        for (uint256 i; i < tokens.length; ++i) {
            MockStock(tokens[i]).mint(deployer, amounts[i]);
            if (!skipSeed) MockStock(tokens[i]).approve(address(fund), amounts[i]);
        }
        if (!skipSeed) fund.seed(seedShares);
    }
}
