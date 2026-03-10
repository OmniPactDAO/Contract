// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Simplified ERC20 token for testing and simulation only, not intended for production.
contract MockERC20 is ERC20 {
    /// @notice Constructor that sets the token name and symbol.
    /// @dev Default name is "Test USDT", symbol is "tPact"
    constructor() ERC20("tPact-USD", "tPact-USD") {}

    /// @notice Mints tokens to the specified address (unrestricted, test-only).
    /// @param to Receiver address
    /// @param amount Mint amount
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
