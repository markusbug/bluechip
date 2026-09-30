// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Stand-in for the Bankr-launched $CHIP (DopplerERC20V1): fixed 100B supply, permit,
///         `burn` of the caller's own balance and no `burnFrom`. `faucet` hands out test tokens
///         from a reserve the contract holds, so total supply behaves like the real token.
contract MockChip is ERC20Permit {
    uint256 public constant SUPPLY = 100_000_000_000e18;
    uint256 public constant FAUCET_AMOUNT = 1_000_000_000e18;

    constructor(address holder) ERC20("Chip", "CHIP") ERC20Permit("Chip") {
        _mint(holder, SUPPLY / 2);
        _mint(address(this), SUPPLY - SUPPLY / 2);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function faucet() external {
        _transfer(address(this), msg.sender, FAUCET_AMOUNT);
    }
}
