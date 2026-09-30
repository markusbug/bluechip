// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BlueFund} from "../BlueFund.sol";
import {MockStock} from "./MockStock.sol";

/// @notice Testnet only: mints every mock stock needed for `shares` BLUE in one transaction.
contract MockBasketFaucet {
    BlueFund public immutable fund;

    constructor(BlueFund fund_) {
        fund = fund_;
    }

    function drip(address to, uint256 shares) external {
        (address[] memory tokens, uint256[] memory amounts) = fund.previewMint(shares);
        for (uint256 i; i < tokens.length; ++i) {
            MockStock(tokens[i]).mint(to, amounts[i]);
        }
    }
}
