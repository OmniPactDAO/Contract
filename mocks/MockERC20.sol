// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Simplified ERC20 token for testing/simulation only, not for production.
contract MockERC20 is ERC20 {
    /// @notice Constructor, sets token name and symbol.
    /// @dev Default name is "Test USDT", symbol is "tPact".
    constructor() ERC20("Test USDT", "tPact") {}

    /// @notice Mint tokens to target address (unrestricted, test only).
    /// @param to Receiver address
    /// @param amount Mint amount
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
