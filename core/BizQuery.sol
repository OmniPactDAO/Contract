// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IRegistry} from "../interfaces/IRegistry.sol";
import {IUserStats} from "../interfaces/IUserStats.sol";
import {IEscrowManager} from "../interfaces/IEscrowManager.sol";
import {
    IArbitrationAdapterExtended
} from "../interfaces/IArbitrationAdapterExtended.sol";
import {OmniErrors} from "../common/OmniErrors.sol";
import {
    EscrowOrder,
    CaseSummary,
    CaseRecord,
    OrderRecord,
    CaseState,
    CaseQueryFilter
} from "../common/Types.sol";

/// @title BizQuery
contract BizQuery is Initializable, OwnableUpgradeable {
    /// @notice Registry address.
    IRegistry public registry;

    /// @dev Registry key: escrowManager.
    bytes32 private constant _ESCROW_MANAGER_KEY = bytes32("escrowManager");
    /// @dev Registry key: arbitrationAdapter.
    bytes32 private constant _ARBITRATION_ADAPTER_KEY =
        bytes32("arbitrationAdapter");
    /// @dev Registry key: userStats.
    bytes32 private constant _USER_STATS_KEY = bytes32("userStats");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize contract.
    /// @param registry_ Registry contract address.
    /// @param initialOwner Initial admin address.
    function initialize(
        address registry_,
        address initialOwner
    ) external initializer {
        if (initialOwner == address(0)) revert OmniErrors.ZeroOwner();
        __Ownable_init(initialOwner);
        if (registry_ == address(0)) revert OmniErrors.ZeroRegistry();
        registry = IRegistry(registry_);
    }

    /// @notice Set Registry address.
    /// @param registry_ New Registry address.
    function setRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert OmniErrors.ZeroRegistry();
        registry = IRegistry(registry_);
    }

    /// @notice Paginated query for order details by user (aggregates UserStats + EscrowManager).
    /// @param user User address.
    /// @param offset Start index (from 0).
    /// @param limit Max number of returns (<= 50).
    /// @return orders Order details list (order consistent with UserStats records).
    /// @return total Total user records (unfiltered).
    function getOrdersByUser(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (EscrowOrder[] memory orders, uint256 total) {
        if (limit > 50) revert OmniErrors.BatchTooLarge();
        IUserStats userStats = IUserStats(_getRecord(_USER_STATS_KEY));
        (OrderRecord[] memory records, uint256 totalRecords) = userStats
            .getOrderRecords(user, offset, limit);
        total = totalRecords;
        if (records.length == 0) {
            return (new EscrowOrder[](0), total);
        }
        bytes32[] memory orderIds = new bytes32[](records.length);
        for (uint256 i = 0; i < records.length; i++) {
            orderIds[i] = records[i].orderId;
        }
        IEscrowManager manager = IEscrowManager(
            _getRecord(_ESCROW_MANAGER_KEY)
        );
        orders = manager.getOrders(orderIds);
    }

    /// @notice Paginated query for arbitration case details by user (aggregates UserStats + ArbitrationAdapter).
    /// @param user User address.
    /// @param offset Start index (from 0).
    /// @param limit Max number of returns (<= 50).
    /// @param filter Status filter: 0=All,1=InProgress,2=Expired,3=Completed.
    /// @return cases Case summary list (may be less than limit).
    /// @return total Total user records (unfiltered).
    function getCasesByUser(
        address user,
        uint256 offset,
        uint256 limit,
        uint8 filter
    ) external view returns (CaseSummary[] memory cases, uint256 total) {
        if (limit > 50) revert OmniErrors.BatchTooLarge();
        IUserStats userStats = IUserStats(_getRecord(_USER_STATS_KEY));
        (CaseRecord[] memory records, uint256 totalRecords) = userStats
            .getCaseRecords(user, offset, limit);
        total = totalRecords;
        if (records.length == 0) {
            return (new CaseSummary[](0), total);
        }
        bytes32[] memory caseIds = new bytes32[](records.length);
        for (uint256 i = 0; i < records.length; i++) {
            caseIds[i] = records[i].caseId;
        }
        IArbitrationAdapterExtended adapter = IArbitrationAdapterExtended(
            _getRecord(_ARBITRATION_ADAPTER_KEY)
        );
        CaseSummary[] memory allCases = adapter.getCases(caseIds);
        if (filter == uint8(CaseQueryFilter.All)) {
            return (allCases, total);
        }
        uint256 matched = 0;
        for (uint256 i = 0; i < allCases.length; i++) {
            if (_matchFilter(allCases[i], filter)) {
                matched++;
            }
        }
        cases = new CaseSummary[](matched);
        uint256 cursor = 0;
        for (uint256 i = 0; i < allCases.length; i++) {
            if (_matchFilter(allCases[i], filter)) {
                cases[cursor] = allCases[i];
                cursor++;
            }
        }
    }


    /// @dev Read Registry record and verify non-zero.
    function _getRecord(bytes32 key) internal view returns (address record) {
        record = registry.records(key);
        if (record == address(0)) revert OmniErrors.ZeroAddress();
    }

    /// @dev Determine if case matches filter criteria (using CaseSummary fields).
    function _matchFilter(
        CaseSummary memory c,
        uint8 filter
    ) internal view returns (bool) {
        if (filter == uint8(CaseQueryFilter.Completed)) {
            return
                c.resolved ||
                c.state == uint8(CaseState.PrimaryResolved) ||
                c.state == uint8(CaseState.FinalResolved) ||
                c.state == uint8(CaseState.ExpertResolved);
        }
        if (filter == uint8(CaseQueryFilter.InProgress)) {
            return
                (c.state == uint8(CaseState.Primary) ||
                    c.state == uint8(CaseState.Final) ||
                    c.state == uint8(CaseState.Expert)) &&
                block.timestamp <= c.deadline;
        }
        if (filter == uint8(CaseQueryFilter.Expired)) {
            return
                (c.state == uint8(CaseState.Primary) ||
                    c.state == uint8(CaseState.Final) ||
                    c.state == uint8(CaseState.Expert)) &&
                block.timestamp > c.deadline;
        }
        return true;
    }

    uint256[50] private __gap;
}
