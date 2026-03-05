// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    IERC1155Receiver
} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {OmniErrors} from "../common/OmniErrors.sol";

/// @title EscrowVault
/// @notice Fund and asset escrow vault, only allowed for EscrowManager to call deposit/withdraw.
contract EscrowVault is Initializable, OwnableUpgradeable, IERC1155Receiver {
    using SafeERC20 for IERC20;

    /// @notice Allowed EscrowManager address to call the vault.
    address public escrow;
    /// @notice Event to set escrow manager
    /// Semantic: Record the authorized EscrowManager address and time to call the vault
    event EscrowSet(address indexed escrow, uint64 timestamp);

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert OmniErrors.NotEscrow();
        _;
    }
    /// @notice Initialize vault owner (called once after proxy deployment).
    /// @param owner_ Owner address.
    /// @dev Use OpenZeppelin Upgradeable initialization process.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert OmniErrors.ZeroOwner();
        __Ownable_init(owner_);
    }

    /// @notice Set EscrowManager address (only allowed to set once).
    /// @param escrow_ Escrow manager address.
    /// @dev Only owner can call; escrow can only be set once to avoid being hijacked.
    function setEscrow(address escrow_) external onlyOwner {
        if (escrow_ == address(0)) revert OmniErrors.ZeroEscrow();
        if (escrow != address(0)) revert OmniErrors.EscrowAlreadySet();
        escrow = escrow_;
        emit EscrowSet(escrow_, uint64(block.timestamp));
    }

    /// @notice Escrow native token.
    /// @dev Only EscrowManager can call; native token is transferred via msg.value.
    function depositNative() external payable onlyEscrow {
        if (msg.value == 0) revert OmniErrors.ZeroValue();
    }

    /// @notice Pull ERC20 from specified address for escrow.
    /// @param from Token source address.
    /// @param token ERC20 token address.
    /// @param amount Pull amount.
    /// @dev Requires from to have authorized this vault for sufficient amount.
    function pullERC20(
        address from,
        address token,
        uint256 amount
    ) external onlyEscrow {
        IERC20(token).safeTransferFrom(from, address(this), amount);
    }

    /// @notice Pull ERC721 from specified address for escrow.
    /// @param from NFT current owner address.
    /// @param token ERC721 contract address.
    /// @param id tokenId.
    /// @dev Requires from to have approved this vault for single or all tokens.
    function pullERC721(
        address from,
        address token,
        uint256 id
    ) external onlyEscrow {
        IERC721(token).transferFrom(from, address(this), id);
    }

    /// @notice Pull ERC1155 from specified address for escrow.
    /// @param from Token source address.
    /// @param token ERC1155 contract address.
    /// @param id Token ID.
    /// @param amount Pull amount.
    /// @dev Requires from to have approved this vault globally.
    function pullERC1155(
        address from,
        address token,
        uint256 id,
        uint256 amount
    ) external onlyEscrow {
        IERC1155(token).safeTransferFrom(from, address(this), id, amount, "");
    }

    /// @notice Pay native token to specified address.
    /// @param to Receiver address.
    /// @param amount Pay amount.
    /// @dev Only EscrowManager can call; used for settlement or return.
    function pushNative(address to, uint256 amount) external onlyEscrow {
        Address.sendValue(payable(to), amount);
    }

    /// @notice Pay ERC20 to specified address.
    /// @param to Receiver address.
    /// @param token ERC20 token address.
    /// @param amount Pay amount.
    function pushERC20(
        address to,
        address token,
        uint256 amount
    ) external onlyEscrow {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Pay ERC721 to specified address.
    /// @param to Receiver address.
    /// @param token ERC721 contract address.
    /// @param id tokenId.
    function pushERC721(
        address to,
        address token,
        uint256 id
    ) external onlyEscrow {
        IERC721(token).transferFrom(address(this), to, id);
    }

    /// @notice Pay ERC1155 to specified address.
    /// @param to Receiver address.
    /// @param token ERC1155 contract address.
    /// @param id Token ID.
    /// @param amount Pay amount.
    function pushERC1155(
        address to,
        address token,
        uint256 id,
        uint256 amount
    ) external onlyEscrow {
        IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
    }

    /// @notice ERC1155 receiver interface (single transfer).
    /// @dev Return interface selector to declare support.
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /// @notice ERC1155 receiver interface (batch transfer).
    /// @dev Return interface selector to declare support.
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /// @notice Declare supported interface IDs.
    /// @param interfaceId Interface identifier.
    /// @return Whether the interface is supported.
    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }

    uint256[50] private __gap;
}
