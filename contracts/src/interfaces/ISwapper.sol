// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Trades one constituent for another on behalf of the fund.
interface ISwapper {
    /// @notice Swap `amountIn` of `sell`, already transferred to the swapper, into `buy` and send it
    ///         to `recipient`. The caller measures what arrives and enforces its own minimum.
    function swap(address sell, address buy, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut);
}
