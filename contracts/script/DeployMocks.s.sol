// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipBurner} from "../src/ChipBurner.sol";
import {MockChipSwapper} from "../src/mocks/MockChipSwapper.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockChip} from "../src/mocks/MockChip.sol";
import {MockBasketFaucet} from "../src/mocks/MockBasketFaucet.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";
import {MockOracleSwapper} from "../src/mocks/MockOracleSwapper.sol";
import {MockOraclePool} from "../src/mocks/MockOraclePool.sol";
import {MockWETH} from "../src/mocks/MockWETH.sol";
import {MintZap} from "../src/MintZap.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {IChip} from "../src/interfaces/IChip.sol";

/// @notice Local / Base Sepolia: mock stocks with the real symbols and seed ratio, a mock CHIP,
///         mock price feeds at the basket's snapshot prices, an oracle-priced mock DEX that also sells
///         stocks for mock USDC, a mock CHIP market ($0.01, 10B CHIP of stock), and the fund, CHIP
///         burner and rebalancer, seeded and ready. Plus the zap over oracle-priced mock Slipstream
///         pools (each stock and WETH at $3,000 against mock USDC, 0.05% spread), so the site can
///         mint with USDC or ETH. KEEPER (default: the deployer) runs the burns. The rebalancer only trades in the US regular
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
        MockStock usdc;
        address usdcFeed;
        MockChipSwapper chipSwapper;
    }

    function run() external returns (BlueFund fund, ChipBurner burner, Rebalancer rebalancer) {
        Basket memory b = _readBasket();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Mocks memory m = _deployMocks(b, deployer);

        uint256 nonce = vm.getNonce(deployer);
        address predictedBurner = vm.computeCreateAddress(deployer, nonce + 1);
        address predictedRebalancer = vm.computeCreateAddress(deployer, nonce + 2);
        fund = new BlueFund(
            b.tokenName,
            b.tokenSymbol,
            m.tokens,
            b.units,
            deployer,
            predictedBurner,
            30,
            1_000_000e18,
            predictedRebalancer
        );
        burner = new ChipBurner(
            fund,
            IChip(address(m.chip)),
            address(m.usdc),
            ISwapper(address(m.swapper)),
            ISwapper(address(m.chipSwapper)),
            deployer,
            vm.envOr("KEEPER", deployer)
        );
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
        require(address(burner) == predictedBurner, "burner address mismatch");
        require(address(rebalancer) == predictedRebalancer, "rebalancer address mismatch");

        _seed(fund, deployer);
        MockBasketFaucet faucet = new MockBasketFaucet(fund);
        MintZap zap = _deployMockZap(fund, m);
        vm.stopBroadcast();

        _writeDeployment(
            b,
            address(fund),
            address(burner),
            address(m.chip),
            address(rebalancer),
            address(m.swapper),
            m.tokens,
            b.symbols,
            m.feeds,
            address(faucet)
        );
        _setDeploymentAddress("zap", address(zap));
        _setDeploymentAddress("usdc", address(m.usdc));
        _setDeploymentAddress("weth", address(zap.weth()));
    }

    /// @dev Oracle-priced mock pools with USDC as token0 (as in the real stock pools) and WETH as
    ///      token0 in its pool (as in the real one), and the zap over them.
    function _deployMockZap(BlueFund fund, Mocks memory m) private returns (MintZap) {
        address[] memory pools = new address[](m.tokens.length);
        for (uint256 i; i < pools.length; ++i) {
            pools[i] = address(new MockOraclePool(address(m.usdc), m.tokens[i], m.usdcFeed, m.feeds[i], 5));
        }
        MockWETH weth = new MockWETH();
        address wethFeed = address(new MockPriceFeed(3_000e8));
        MockOraclePool wethPool = new MockOraclePool(address(weth), address(m.usdc), wethFeed, m.usdcFeed, 5);
        return new MintZap(fund, address(m.usdc), IWETH(address(weth)), ICLPool(address(wethPool)), pools);
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
        // Mock USDC at $1, sold for by the same mock DEX, and a CHIP market at $0.01.
        m.usdc = new MockStock("USD Coin", "USDC", 6);
        address[] memory usdcOnly = new address[](1);
        address[] memory usdcFeed = new address[](1);
        usdcOnly[0] = address(m.usdc);
        usdcFeed[0] = address(new MockPriceFeed(1e8));
        m.usdcFeed = usdcFeed[0];
        m.swapper.addTokens(usdcOnly, usdcFeed);
        m.chipSwapper = new MockChipSwapper(address(m.usdc), address(m.chip), 1e14);
        m.chip.transfer(address(m.chipSwapper), 10_000_000_000e18);
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
