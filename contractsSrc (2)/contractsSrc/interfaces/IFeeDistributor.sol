// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title IFeeDistributor
/// @notice Fee distribution interface, used to handle arbitration fees, platform shares, and other fund flows.
interface IFeeDistributor {
    /// @notice Distribute appeal fee.
    /// @param caseId Case ID.
    /// @param round Current round.
    /// @param token Fee asset address (address(0) is native).
    /// @param totalAmount Total distribution amount.
    /// @param platformRecipient Platform recipient address.
    /// @param platformBps Platform share ratio (bps).
    /// @param recipients Final beneficiary list (e.g., voting jurors).
    /// @param payer Payer to refund remaining amount (e.g., refund if no one votes).
    function distributeAppealFee(
        bytes32 caseId,
        uint8 round,
        address token,
        uint256 totalAmount,
        address platformRecipient,
        uint16 platformBps,
        address[] calldata recipients,
        address payer
    ) external payable;

    /// @notice Settle arbitration reward (deducted from business asset).
    /// @param orderId Order ID.
    /// @param token Asset address.
    /// @param amount Total reward amount.
    /// @param recipients Beneficiary list.
    function distributeArbitrationReward(
        bytes32 orderId,
        address token,
        uint256 amount,
        address[] calldata recipients
    ) external payable;

    /// @notice Distribute losing party's collateral penalty.
    /// @param orderId Order ID.
    /// @param token Collateral asset address.
    /// @param totalAmount Total collateral amount.
    /// @param penaltyBps Penalty ratio (bps).
    /// @param winner Winner (receives penalty amount).
    /// @param loser Loser (receives remaining amount).
    function distributeCollateralPenalty(
        bytes32 orderId,
        address token,
        uint256 totalAmount,
        uint16 penaltyBps,
        address winner,
        address loser
    ) external payable;
}
