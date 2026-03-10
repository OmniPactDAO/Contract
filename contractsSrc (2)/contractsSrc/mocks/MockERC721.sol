// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title MockERC721
/// @notice Simplified ERC721 token for testing and simulation only.
contract MockERC721 is ERC721 {
    /// @notice Constructor that sets the token name and symbol.
    /// @dev Default name is "Test NFT", symbol is "tPact-NFT"
    constructor() ERC721("tPact-NFT", "tPact-NFT") {}

    /// @notice Mints a token with the specified id to the target address (unrestricted, test-only).
    /// @param to Receiver address
    /// @param tokenId Token ID
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}
