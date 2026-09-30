// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Testnet stand-in for a tokenized stock (Coinbase B20: 8 decimals, EIP-2612 permit,
///         WAD `multiplier`).
///         Anyone can mint. The owner-less `setFrozen` lets tests model an issuer freeze.
contract MockStock is ERC20Permit {
    uint8 private immutable _decimals;
    uint256 public multiplier = 1e18;
    bool public frozen;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMultiplier(uint256 m) external {
        multiplier = m;
    }

    function setFrozen(bool f) external {
        frozen = f;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!frozen, "MockStock: frozen");
        super._update(from, to, value);
    }
}
