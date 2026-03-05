// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {OmniErrors} from "../common/OmniErrors.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title Registry
/// @notice Records protocol key component addresses and versions, as a trusted entry point.
contract Registry is Initializable, OwnableUpgradeable, PausableUpgradeable {
    /// @notice Record table: key -> address.
    mapping(bytes32 => address) public records;

    event Initialized(address indexed owner, uint64 timestamp);
    event RecordUpdated(
        bytes32 indexed key,
        address indexed value,
        uint64 timestamp
    );

    /// @notice Initialize once, called after deployment or clone.
    /// @param _owner Admin address.
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert OmniErrors.ZeroOwner();
        __Ownable_init(_owner);
        __Pausable_init();
        emit Initialized(_owner, uint64(block.timestamp));
    }

    /// @notice Pause contract (only owner).
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /// @notice Unpause contract (only owner).
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /// @notice Set or update component address, e.g., factory, default arbitration adapter, etc.
    /// @param key Component key name (custom bytes32, e.g., "factory").
    /// @param value Component address.
    function setRecord(bytes32 key, address value) external onlyOwner {
        if (value == address(0)) revert OmniErrors.ZeroAddress();
        records[key] = value;
        emit RecordUpdated(key, value, uint64(block.timestamp));
    }

    uint256[50] private __gap;
}
