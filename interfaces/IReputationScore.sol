// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title IReputationScore
/// @notice Generic reputation scoring interface
interface IReputationScore {
    /// @notice Directly set user score (sync with business-side result).
    /// @param user User address.
    /// @param businessId Business ID (e.g., order ID).
    /// @param actionType Action type (for event logging).
    /// @param newScore Final score computed by business logic.
    function setScore(
        address user,
        bytes32 businessId,
        uint8 actionType,
        int256 newScore
    ) external;

    /// @notice Compute and sync score by three metrics (called by the stats contract).
    /// @param user User address.
    /// @param completedTrades Completed trades.
    /// @param totalTrades Total trades (including canceled).
    /// @param disputesLost Disputes lost count.
    /// @param businessId Business ID (e.g., order ID).
    /// @param actionType Action type (for event logging).
    function updateScoreWithStats(
        address user,
        uint256 completedTrades,
        uint256 totalTrades,
        uint256 disputesLost,
        bytes32 businessId,
        uint8 actionType
    ) external;

    /// @notice Query user score.
    function scoreOf(address user) external view returns (int256);
}
