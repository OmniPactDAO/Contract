// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title IJurorManager
/// @notice Juror management interface for maintaining juror pools, expert pools, and juror selection logic.
interface IJurorManager {
    /// @notice Select jurors.
    /// @param orderId Order ID (used as pseudo-random seed).
    /// @param isPrimary Whether to select for primary round (true uses primary pool, false uses final pool).
    /// @return selected Selected juror list.
    function pickJurors(
        bytes32 orderId,
        bool isPrimary
    ) external view returns (address[] memory selected);

    /// @notice Check whether address is in primary juror whitelist.
    function isPrimaryJuror(address juror) external view returns (bool);

    /// @notice Check whether address is in final juror whitelist.
    function isFinalJuror(address juror) external view returns (bool);

    /// @notice Check whether address is an expert.
    function isExpertJuror(address juror) external view returns (bool);

    /// @notice Get total expert count.
    function expertCount() external view returns (uint256);

    /// @notice Get target primary juror count.
    function jurorCountPrimary() external view returns (uint8);

    /// @notice Get target primary juror count.
    function jurorCountFinal() external view returns (uint8);

    /// @notice Paginated query for experts.
    function getExpertJurors(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory items, uint256 total);

    /// @notice Paginated query for active primary jurors.
    function getPrimaryJurors(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory items, uint256 total);

    /// @notice Paginated query for active final jurors.
    function getFinalJurors(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory items, uint256 total);

    // --- Admin Functions ---
    function setJurorCountPrimary(uint8 count) external;
    function setJurorCountFinal(uint8 count) external;
    function addJuror(address juror) external;
    function addFinalJuror(address juror) external;
    function removeJuror(address juror) external;
    function removeFinalJuror(address juror) external;
    function addExpertJuror(address juror) external;
    function removeExpertJuror(address juror) external;
}
