// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {AssetType} from "../common/Types.sol";

/// @title IArbitrable
/// @notice General arbitration callback interface, called when arbitrator decouples business contracts.
interface IArbitrable {
    /// @notice Get business order value information (used to calculate appeal fee).
    /// @param orderId Business-side identifier (e.g., Order ID).
    /// @return amount Order amount.
    /// @return token Order asset address (native token is address(0)).
    /// @return assetType Asset type.
    /// @return partyA Party A (usually buyer/initiator).
    /// @return partyB Party B (usually seller/responder).
    function getArbitrationValue(
        bytes32 orderId
    )
        external
        view
        returns (
            uint256 amount,
            address token,
            AssetType assetType,
            address partyA,
            address partyB
        );

    /// @notice Callback to business contract after arbitrator closes case.
    /// @param caseId Arbitration case ID.
    /// @param orderId Business-side identifier (e.g., Order ID).
    /// @param winner Winner address (if applicable).
    function onArbitrationResolved(
        bytes32 caseId,
        bytes32 orderId,
        address winner
    ) external;
}
