// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Asset, OrderState} from "../common/Types.sol";

/// @title IEscrowEvents
/// @notice Escrow business event definitions.
interface IEscrowEvents {
    /// @notice Order created event.
    event OrderCreated(
        bytes32 indexed orderId,
        address indexed buyer,
        address indexed seller,
        address arbitrator,
        Asset paymentAsset,
        Asset targetAsset,
        Asset collateral,
        uint256 price,
        uint256 deadline,
        uint256 feeBps,
        bytes32 metadataHash,
        uint16 arbRewardBps,
        uint16 collateralPenaltyBps,
        OrderState state,
        uint64 timestamp
    );
    /// @notice Buyer's funds have been escrowed.
    event OrderFunded(bytes32 indexed orderId, address indexed payer, uint256 amount, uint64 timestamp);
    /// @notice Target asset has been locked.
    event AssetLocked(bytes32 indexed orderId, address indexed locker, uint64 timestamp);
    /// @notice Seller marks as delivered.
    event Delivered(bytes32 indexed orderId, address indexed caller, uint64 timestamp);
    /// @notice Order completed and settled.
    event Completed(bytes32 indexed orderId, address indexed buyer, address indexed seller, uint64 timestamp);
    /// @notice Order cancelled/expired.
    event Cancelled(bytes32 indexed orderId, address indexed caller, uint64 timestamp);
    /// @notice Dispute initiated.
    event Disputed(bytes32 indexed orderId, address indexed caller, address arbitrator, uint64 timestamp);
    /// @notice Arbitration closed.
    event Resolved(bytes32 indexed orderId, address indexed winner, address arbitrator, uint64 timestamp);
    /// @notice Trigger arbitration request.
    event ArbitrationRequested(
        bytes32 indexed orderId,
        bytes32 indexed caseId,
        address indexed arbitrator,
        uint64 timestamp
    );
    /// @notice Collateral has been locked.
    event CollateralLocked(
        bytes32 indexed orderId,
        address indexed locker,
        uint256 amount,
        address token,
        uint64 timestamp
    );
    /// @notice Collateral has been released (paid out or returned).
    event CollateralReleased(
        bytes32 indexed orderId,
        address indexed to,
        uint256 amount,
        address token,
        uint64 timestamp
    );
    /// @notice Order metadata updated (only allowed to update before buyer pays, used to update off-chain content like title/description/image).
    /// @dev metadataCid is the locator for off-chain storage (IPFS/Arweave/HTTPS); metadataHash is usually keccak256(metadataCid) or keccak256(metadataJson).
    event MetadataUpdated(
        bytes32 indexed orderId,
        address indexed updater,
        bytes metadataCid,
        bytes32 metadataHash,
        uint64 timestamp
    );
}
