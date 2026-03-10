// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {EscrowOrder, EscrowOrderReq} from "../common/Types.sol";
import {IEscrowEvents} from "./IEscrowEvents.sol";

/// @title IEscrowManager
/// @notice Interface for single-contract escrow management (multi-order).
interface IEscrowManager is IEscrowEvents {
    /// @notice Create a new escrow order.
    /// @param order Order parameters.
    /// @return orderId Generated order ID.
    function createEscrow(
        EscrowOrderReq calldata order
    ) external payable returns (bytes32 orderId);

    /// @notice Buyer funds the order.
    function markFunded(bytes32 orderId) external payable;

    /// @notice Seller locks the target asset.
    function lockAsset(bytes32 orderId) external payable;

    /// @notice Seller locks collateral.
    function lockCollateral(bytes32 orderId) external payable;

    /// @notice Lock seller assets and collateral in one transaction.
    function lockSellerAssets(bytes32 orderId) external payable;

    /// @notice Seller marks the order as delivered.
    function markDelivered(bytes32 orderId) external;

    /// @notice Buyer confirms completion.
    function confirmCompletion(bytes32 orderId) external;

    /// @notice Cancel the order.
    function cancel(bytes32 orderId) external;

    /// @notice Handle expiration (auto-complete or cancel).
    function expire(bytes32 orderId) external;

    /// @notice Raise a dispute.
    function raiseDispute(bytes32 orderId, bytes calldata evidence) external;

    /// @notice Callback for arbitration resolution (legacy path).
    function resolveDispute(bytes32 orderId, address winner) external;

    /// @notice Callback for arbitration resolution (new path).
    function onArbitrationResolved(
        bytes32 caseId,
        bytes32 orderId,
        address winner
    ) external;

    /// @notice Get order details.
    function getOrder(
        bytes32 orderId
    ) external view returns (EscrowOrder memory);

    /// @notice Batch get order details (for off-chain reading only).
    /// @param orderIds List of order IDs.
    /// @return orders List of corresponding order data (one-to-one with orderIds).
    function getOrders(
        bytes32[] calldata orderIds
    ) external view returns (EscrowOrder[] memory orders);

    /// @notice Check if buyer funds are locked.
    function isFunded(bytes32 orderId) external view returns (bool);

    /// @notice Check if seller target asset is locked.
    function isAssetLocked(bytes32 orderId) external view returns (bool);

    /// @notice Check if seller collateral is locked.
    function isCollateralLocked(bytes32 orderId) external view returns (bool);

    /// @notice Get order context (used for decoupled arbitration).
    function getContext(bytes32 orderId) external view returns (bytes memory);

    /// @notice Get dispute case ID.
    function getDisputeCaseId(bytes32 orderId) external view returns (bytes32);

    /// @notice Get fee snapshot for the order.
    function getFeeSnapshot(
        bytes32 orderId
    ) external view returns (address recipient, uint16 feeBps);

    /// @notice Get fixed creation fee payment status.
    /// @return buyerPaid Whether buyer has paid the fixed creation fee.
    /// @return sellerPaid Whether seller has paid the fixed creation fee.
    /// @return splitEnabled Whether split fixed creation fee mode is enabled (usually false for old orders).
    function getCreateFeeStatus(
        bytes32 orderId
    )
        external
        view
        returns (bool buyerPaid, bool sellerPaid, bool splitEnabled);

    /// @notice Update order metadata (title/description/image etc.), only allowed by seller before buyer payment.
    function updateMetadata(
        bytes32 orderId,
        bytes calldata metadataCid
    ) external;
}
