// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {EscrowOrder, EscrowOrderReq} from "../common/Types.sol";
import {IEscrowEvents} from "./IEscrowEvents.sol";

/// @title IEscrowManager
/// @notice Single contract Escrow management interface (multiple orders).
interface IEscrowManager is IEscrowEvents {
    /// @notice Create a new escrow order.
    /// @param order Order parameters.
    /// @return orderId Generated order ID.
    function createEscrow(EscrowOrderReq calldata order) external payable returns (bytes32 orderId);

    /// @notice Buyer pays funds.
    function markFunded(bytes32 orderId) external payable;

    /// @notice Seller locks target asset.
    function lockAsset(bytes32 orderId) external;

    /// @notice Seller locks collateral.
    function lockCollateral(bytes32 orderId) external payable;

    /// @notice One-click lock seller's assets and collateral.
    function lockSellerAssets(bytes32 orderId) external payable;

    /// @notice Seller marks as delivered.
    function markDelivered(bytes32 orderId) external;

    /// @notice Buyer confirms completion.
    function confirmCompletion(bytes32 orderId) external;

    /// @notice Cancel order.
    function cancel(bytes32 orderId) external;

    /// @notice Timeout handling (auto-complete or cancel).
    function expire(bytes32 orderId) external;

    /// @notice Initiate arbitration.
    function raiseDispute(bytes32 orderId, bytes calldata evidence) external;

    /// @notice Arbitration adapter callback ruling result (old path).
    function resolveDispute(bytes32 orderId, address winner) external;

    /// @notice Arbitration adapter callback ruling result (new path).
    function onArbitrationResolved(
        bytes32 caseId,
        bytes32 orderId,
        address winner
    ) external;

    /// @notice Query order details.
    function getOrder(bytes32 orderId) external view returns (EscrowOrder memory);

    /// @notice Batch query order details (only for off-chain reading).
    /// @param orderIds Order ID list.
    /// @return orders Corresponding order data list (one-to-one with orderIds).
    function getOrders(bytes32[] calldata orderIds) external view returns (EscrowOrder[] memory orders);

    /// @notice Query whether buyer's funds are locked.
    function isFunded(bytes32 orderId) external view returns (bool);

    /// @notice Query whether seller's target asset is locked.
    function isAssetLocked(bytes32 orderId) external view returns (bool);

    /// @notice Query whether seller's collateral is locked.
    function isCollateralLocked(bytes32 orderId) external view returns (bool);

    /// @notice Return order context (for arbitration decoupling).
    function getContext(bytes32 orderId) external view returns (bytes memory);

    /// @notice Query dispute caseId.
    function getDisputeCaseId(bytes32 orderId) external view returns (bytes32);

    /// @notice Query order fee snapshot.
    function getFeeSnapshot(bytes32 orderId) external view returns (address recipient, uint16 feeBps);

    /// @notice Update order metadata (title/description/image, etc.), only allowed to update before buyer pays by seller.
    function updateMetadata(bytes32 orderId, bytes calldata metadataCid) external;
}
