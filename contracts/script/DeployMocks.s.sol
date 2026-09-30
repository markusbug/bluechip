// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeploymentIO} from "./DeploymentIO.sol";
import {BlueFund} from "../src/BlueFund.sol";
import {ChipVault} from "../src/ChipVault.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockChip} from "../src/mocks/MockChip.sol";
import {MockBasketFaucet} from "../src/mocks/MockBasketFaucet.sol";
import {IChip} from "../src/interfaces/IChip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Local / Base Sepolia: mock stocks with the real symbols and seed ratio, a mock CHIP,
///         the fund and the vault, seeded and ready.
///
///   forge script script/DeployMocks.s.sol --rpc-url localhost --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract DeployMocks is DeploymentIO {
    function run() external returns (BlueFund fund, ChipVault vault) {
        Basket memory b = _readBasket();
        uint256 seedShares = vm.envOr("SEED_SHARES", uint256(10e18));
        uint256 n = b.symbols.length;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        address[] memory tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = address(new MockStock(b.symbols[i], b.symbols[i], 8));
        }
        MockChip chip = new MockChip(deployer);

        address predictedVault = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        fund = new BlueFund(
            "Bluechip Index", "BLUE", tokens, b.units, deployer, predictedVault, 30, 1_000_000e18
        );
        vault = new ChipVault(IERC20(address(fund)), IChip(address(chip)));
        require(address(vault) == predictedVault, "vault address mismatch");

        (, uint256[] memory amounts) = fund.previewMint(seedShares);
        bool skipSeed = vm.envOr("SKIP_SEED", false); // leave seeding to scripts/seed.sh
        for (uint256 i; i < n; ++i) {
            MockStock(tokens[i]).mint(deployer, amounts[i]);
            if (!skipSeed) MockStock(tokens[i]).approve(address(fund), amounts[i]);
        }
        if (!skipSeed) fund.seed(seedShares);
        MockBasketFaucet faucet = new MockBasketFaucet(fund);
        vm.stopBroadcast();

        _writeDeployment(
            address(fund), address(vault), address(chip), tokens, b.symbols, new address[](0), address(faucet)
        );
    }
}
