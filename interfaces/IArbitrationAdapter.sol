// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title IArbitrationAdapter
/// @notice Arbitration Adapter Interface, for Escrow contracts to trigger and receive arbitration results.
interface IArbitrationAdapter {
    /// @notice Escrow requests arbitration.
    event ArbitrationRequested(
        bytes32 indexed orderId,
        address indexed escrow,
        address indexed requester,
        bytes data,
        bytes context,
        uint64 timestamp
    );
    /// @notice Arbitration completed and callback to Escrow.
    event ArbitrationResolved(
        bytes32 indexed orderId,
        address indexed escrow,
        address winner,
        bytes data,
        uint64 timestamp
    );

    /// @notice Request arbitration, returns case ID; implementation should record internally and rule asynchronously.
    /// @param orderId Order ID.
    /// @param requester Initiator.
    /// @param data Additional data/evidence.
    /// @param context Business context (can include buyer and seller, etc.).
    /// @return caseId Arbitration case ID.
    function requestArbitration(
        bytes32 orderId,
        address requester,
        bytes calldata data,
        bytes calldata context
    ) external returns (bytes32 caseId);

    /// @notice Called by Arbitration Adapter to Escrow contract, passing winner info (can attach evidence hash, etc.).
    /// @param orderId Order ID.
    /// @param winner Winner address.
    /// @param data Additional data/evidence.
    // function resolveArbitration(
    //     bytes32 orderId,
    //     address winner,
    //     bytes calldata data
    // ) external;

    /// @notice Submit evidence.
    function submitEvidence(
        bytes32 caseId,
        bytes calldata evidenceCid
    ) external;

    /// @notice Deposit arbitration reward (called by business contract during settlement).
    function depositReward(bytes32 caseId) external payable;
}
