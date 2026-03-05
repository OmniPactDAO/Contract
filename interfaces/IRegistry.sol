// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title IRegistry
/// @notice Registry minimal interface: query record address by key.
interface IRegistry {
    /// @notice Query record address by key.
    /// @param key Record key (e.g., bytes32("factory")).
    /// @return addr Corresponding contract address; address(0) if not exists.
    function records(bytes32 key) external view returns (address addr);
}
