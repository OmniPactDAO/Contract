// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Stats, OrderRecord, CaseRecord} from "../common/Types.sol";

/// @title IUserStats
/// @notice User stats interface with read-only methods for frontend queries.
interface IUserStats {
    function getStats(address user) external view returns (Stats memory);

    /// @notice Three core reputation metrics (completed/total/disputesLost).
    /// @dev totalTrades = created (+1 when order is created, including canceled/ongoing).
    function getReputationSummary(address user)
        external
        view
        returns (uint256 completedTrades, uint256 totalTrades, uint256 disputesLost);
    function getOrderCount(address user) external view returns (uint256);
    function getOrderRecord(address user, uint256 index) external view returns (OrderRecord memory);
    function getOrderRecords(address user, uint256 offset, uint256 limit)
        external
        view
        returns (OrderRecord[] memory items, uint256 total);
    function getCaseCount(address user) external view returns (uint256);
    function getCaseRecord(address user, uint256 index) external view returns (CaseRecord memory);
    function getCaseRecords(address user, uint256 offset, uint256 limit)
        external
        view
        returns (CaseRecord[] memory items, uint256 total);
}
