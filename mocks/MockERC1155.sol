// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @title MockERC1155
/// @notice Simplified ERC1155 token for testing and simulation only.
contract MockERC1155 is ERC1155 {
    /// @notice Constructor, sets metadata URI.
    /// @dev Name "Test Multi-Token", symbol "tPact-MTX" (ERC1155 has no standard name/symbol, can be expressed in metadata).
    constructor() ERC1155("https://example.com/api/item/{id}.json") {}

    /// @notice Mint token with specified id to target address.
    /// @param to Receiver address
    /// @param id Token ID
    /// @param amount Mint amount
    /// @param data Extra data
    function mint(address to, uint256 id, uint256 amount, bytes memory data) external {
        _mint(to, id, amount, data);
    }

    /// @notice Batch mint tokens.
    /// @param to Receiver address
    /// @param ids Token ID list
    /// @param amounts Amount list
    /// @param data Extra data
    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external {
        _mintBatch(to, ids, amounts, data);
    }
}
