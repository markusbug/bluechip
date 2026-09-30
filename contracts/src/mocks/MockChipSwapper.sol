// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";

/// @notice Testnet stand-in for CHIP's pool: sells CHIP for USDC at a fixed rate out of a reserve
///         someone sent it. Keeps the USDC.
contract MockChipSwapper is ISwapper {
    address public immutable usdc;
    address public immutable chip;
    /// @notice CHIP base units per USDC base unit.
    uint256 public rate;

    constructor(address usdc_, address chip_, uint256 rate_) {
        usdc = usdc_;
        chip = chip_;
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function swap(address sell, address buy, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut)
    {
        require(sell == usdc && buy == chip, "MockChipSwapper: route");
        amountOut = amountIn * rate;
        IERC20(chip).transfer(recipient, amountOut);
    }
}
