// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "./IArbitrationAdapter.sol";
import {JurorCaseRef, VoteRecord, CaseSummary, Vote} from "../common/Types.sol";

/// @title IArbitrationAdapterExtended
/// @notice Extended Arbitration Adapter, read-only/submit interface, convenient for frontend or other contracts to query cases.
interface IArbitrationAdapterExtended is IArbitrationAdapter {
    /// @notice Submit evidence (e.g., IPFS CID), implement own permission control if needed.
    /// @param caseId Case ID.
    /// @param evidenceCid Evidence CID/data.
    function submitEvidence(
        bytes32 caseId,
        bytes calldata evidenceCid
    ) external;

    /// @notice Juror votes.
    /// @param caseId Case ID.
    /// @param v Vote option (Buyer/Seller).
    function vote(bytes32 caseId, Vote v) external;

    /// @notice Pay final round fee within appeal period and start final round.
    /// @param caseId Case ID.
    function appeal(bytes32 caseId) external payable;

    /// @notice Optional: Pre-deposit final round fee, then call appeal later to start final round.
    function fundFinalAppeal(bytes32 caseId) external payable;

    /// @notice Read-only get case details (if implementation supports).
    /// @param caseId Case ID.
    /// @return escrow Escrow address.
    /// @return orderId Order ID.
    /// @return resolved Whether case is closed.
    /// @return winner Winner address.
    /// @return jurors Juror list.
    /// @return evidences Evidence list.
    function getCase(
        bytes32 caseId
    )
        external
        view
        returns (
            address escrow,
            bytes32 orderId,
            bool resolved,
            address winner,
            address[] memory jurors,
            bytes[] memory evidences
        );

    /// @notice Batch query case summaries (for list display).
    /// @param caseIds Case ID list.
    /// @return items Case summary list (order consistent with input).
    function getCases(
        bytes32[] calldata caseIds
    ) external view returns (CaseSummary[] memory items);
    /// @notice Convenient query for appeal deadline.
    function appealDeadline(bytes32 caseId) external view returns (uint64);

    /// @notice Calculate appeal fee based on order payment amount (final round).
    /// @param client Escrow contract address.
    /// @param orderId Order ID.
    /// @return fee Appeal fee amount.
    /// @return token Appeal fee asset address.
    function calcAppealFee(
        address client,
        bytes32 orderId
    ) external view returns (uint256 fee, address token);

    /// @notice Get case details (including status/fee/deadline).
    function getCaseDetail(
        bytes32 caseId
    )
        external
        view
        returns (
            address escrow,
            bytes32 orderId,
            uint8 state,
            uint8 round,
            uint64 deadline,
            uint64 evidenceDeadline,
            uint64 appealDeadlineTs,
            uint256 feePrimary,
            uint256 feeFinal,
            address feeToken,
            bool resolved,
            address winner,
            address requester,
            address finalFeePayer,
            uint256 yesCount,
            uint256 noCount,
            address[] memory jurors,
            bytes memory context,
            bytes[] memory evidences
        );

    /// @notice Paginated query juror list for a case.
    /// @param caseId Case ID.
    /// @param round Round: 1=Primary, 2=Final, 3=Expert.
    /// @param offset Start index.
    /// @param limit Max number of returns.
    /// @return items Juror address list.
    /// @return total Total jurors in this round.
    function getCaseJurors(
        bytes32 caseId,
        uint8 round,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory items, uint256 total);

    /// @notice Paginated query vote details for a case.
    /// @param caseId Case ID.
    /// @param round Round: 1=Primary, 2=Final, 3=Expert.
    /// @param offset Start index.
    /// @param limit Max number of returns.
    /// @return items Vote record list.
    /// @return total Total vote records in this round.
    function getCaseVotes(
        bytes32 caseId,
        uint8 round,
        uint256 offset,
        uint256 limit
    ) external view returns (VoteRecord[] memory items, uint256 total);
}
