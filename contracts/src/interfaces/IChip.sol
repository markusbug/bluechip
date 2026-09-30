// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @notice The subset of a Bankr-launched token (DopplerERC20V1) that the burner uses.
///         `burn` burns the caller's own balance; there is no `burnFrom`.
interface IChip is IERC20, IERC20Permit {
    function burn(uint256 amount) external;
}
