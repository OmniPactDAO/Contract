// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Stats, OrderRecord, CaseRecord, StatsAction} from "../common/Types.sol";
import {OmniErrors} from "../common/OmniErrors.sol";
import {IReputationScore} from "../interfaces/IReputationScore.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title UserStats
/// @notice Tracks counters for user escrow orders for frontend/analytics.
contract UserStats is Initializable, OwnableUpgradeable, PausableUpgradeable {
    /// @notice Stats mapping.
    mapping(address => Stats) public statsOf;
    /// @notice Updater whitelist (set by factory/escrow).
    mapping(address => bool) public isUpdater;
    /// @notice Manager whitelist.
    mapping(address => bool) public isManager;
    /// @notice User participated order records.
    mapping(address => OrderRecord[]) private _orders;

    /// @notice User participated arbitration case records.
    mapping(address => CaseRecord[]) private _cases;
    /// @notice Avoid duplicate recording of a caseId.
    mapping(address => mapping(bytes32 => bool)) private _caseRecorded;

    // --- New Variables (Appended to the end to preserve storage layout) ---

    /// @notice User completed order records.
    mapping(address => OrderRecord[]) private _completedOrders;
    /// @notice User ongoing order records.
    mapping(address => OrderRecord[]) private _ongoingOrders;
    /// @notice User disputed order records.
    mapping(address => OrderRecord[]) private _disputedOrders;
    /// @notice User canceled order records.
    mapping(address => OrderRecord[]) private _cancelledOrders;

    /// @notice Stores index (index + 1) of ongoing orders for O(1) deletion.
    /// @dev user => orderId => index + 1
    mapping(address => mapping(bytes32 => uint256)) private _ongoingIndex;

    /// @notice Stores index (index + 1) of disputed orders.
    /// @dev user => orderId => index + 1
    mapping(address => mapping(bytes32 => uint256)) private _disputedIndex;

    /// @notice Juror ongoing-case index (caseId => index + 1).
    mapping(address => mapping(bytes32 => uint256)) private _ongoingJurorIndex;

    /// @notice Juror case records (all).
    mapping(address => CaseRecord[]) private _jurorCases;
    /// @notice Juror ongoing case records.
    mapping(address => CaseRecord[]) private _ongoingJurorCases;
    /// @notice Juror completed case records.
    mapping(address => CaseRecord[]) private _completedJurorCases;

    /// @notice Score contract address (ReputationScore), pluggable.
    address public reputationScore;

    uint8 public constant ROLE_BUYER = 1;
    uint8 public constant ROLE_SELLER = 2;
    uint8 public constant ROLE_INITIATOR = 1;
    uint8 public constant ROLE_PARTY = 2;
    /// @notice Updater permission changed event
    /// Semantics: records granting/removing updater permission for an address (e.g., escrow contract).
    event UpdaterSet(address indexed updater, bool allowed, uint64 timestamp);
    /// @notice Manager permission changed event
    /// Semantics: records granting/removing manager permission for an address.
    event ManagerSet(address indexed manager, bool allowed, uint64 timestamp);
    /// @notice User stats changed event
    /// Semantics: records post-change snapshot of statsOf for off-chain analytics.
    event StatsUpdated(
        address indexed user,
        uint64 created,
        uint64 completed,
        uint64 cancelled,
        uint64 disputesRaised,
        uint64 disputesWon,
        uint64 disputesLost,
        int256 currentScore,
        bytes32 orderId,
        bytes32 caseId,
        StatsAction action,
        uint64 timestamp
    );

    modifier onlyOwnerOrManager() {
        if (msg.sender != owner() && !isManager[msg.sender])
            revert OmniErrors.NotAuthorized();
        _;
    }

    modifier onlyUpdater() {
        if (!isUpdater[msg.sender]) revert OmniErrors.NotUpdater();
        _;
    }

    /// @notice Initialize, called once after deployment/proxy deployment.
    /// @param _owner Manager address.
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert OmniErrors.ZeroOwner();
        __Ownable_init(_owner);
        __Pausable_init();
    }

    /// @notice Pause contract (owner only).
    /// @dev Enter paused state; owner only.
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /// @notice Unpause contract (owner only).
    /// @dev Exit paused state; owner only.
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /// @notice Set manager.
    /// @param manager Manager address.
    /// @param allowed Whether allowed.
    /// @dev Owner only; grant or revoke manager permission.
    function setManager(address manager, bool allowed) external onlyOwner {
        isManager[manager] = allowed;
        emit ManagerSet(manager, allowed, uint64(block.timestamp));
    }

    /// @notice Set data updater (escrow contract, etc.).
    /// @param updater Address.
    /// @param allowed Whether allowed.
    /// @dev Only owner or manager can call; updater can perform stats updates.
    function setUpdater(
        address updater,
        bool allowed
    ) external onlyOwnerOrManager {
        isUpdater[updater] = allowed;
        emit UpdaterSet(updater, allowed, uint64(block.timestamp));
    }

    /// @notice Set score contract address.
    function setReputationScore(address _reputationScore) external onlyOwner {
        reputationScore = _reputationScore;
    }

    /// @notice Generic stats update interface (supports multiple integration modes).
    /// @param user User address.
    /// @param orderId Order/business ID.
    /// @param caseId Associated case ID (if any).
    /// @param role User role in this business flow (e.g., 1:Buyer, 2:Seller).
    /// @param action Action type occurred.
    function updateOnAction(
        address user,
        bytes32 orderId,
        bytes32 caseId,
        uint8 role,
        StatsAction action
    ) public onlyUpdater {
        if (user == address(0)) revert OmniErrors.ZeroAccount();
        if (orderId == bytes32(0)) revert OmniErrors.EmptyOrderId();

        bool shouldSync = false;

        if (action == StatsAction.Create) {
            statsOf[user].created += 1;
            _orders[user].push(OrderRecord(orderId, role));
            _ongoingOrders[user].push(OrderRecord(orderId, role));
            _ongoingIndex[user][orderId] = _ongoingOrders[user].length;
            shouldSync = true;
        } else if (action == StatsAction.Complete) {
            statsOf[user].completed += 1;
            _removeOngoing(user, orderId);
            _completedOrders[user].push(OrderRecord(orderId, role));
            shouldSync = true;
        } else if (action == StatsAction.Cancel) {
            statsOf[user].cancelled += 1;
            _removeOngoing(user, orderId);
            _cancelledOrders[user].push(OrderRecord(orderId, role));
        } else if (action == StatsAction.Dispute) {
            if (caseId == bytes32(0)) revert OmniErrors.EmptyCaseId();
            if (!_caseRecorded[user][caseId]) {
                _caseRecorded[user][caseId] = true;
                _cases[user].push(CaseRecord(caseId, orderId, role));
                // Only the dispute initiator (role includes INITIATOR) increments disputesRaised.
                if ((role & ROLE_INITIATOR) != 0) {
                    statsOf[user].disputesRaised += 1;
                }
                _removeOngoing(user, orderId);
                _disputedOrders[user].push(OrderRecord(orderId, role));
                _disputedIndex[user][orderId] = _disputedOrders[user].length;
            }
        } else if (action == StatsAction.ResolveWin) {
            statsOf[user].disputesWon += 1;
            _removeDisputed(user, orderId);
            if (!_caseRecorded[user][caseId]) {
                _caseRecorded[user][caseId] = true;
                _cases[user].push(CaseRecord(caseId, orderId, role));
            }
            _completedOrders[user].push(OrderRecord(orderId, role));
        } else if (action == StatsAction.ResolveLose) {
            statsOf[user].disputesLost += 1;
            _removeDisputed(user, orderId);
            if (!_caseRecorded[user][caseId]) {
                _caseRecorded[user][caseId] = true;
                _cases[user].push(CaseRecord(caseId, orderId, role));
            }
            _completedOrders[user].push(OrderRecord(orderId, role));
            shouldSync = true;
        }

        if (shouldSync) {
            _syncReputationByStats(user, orderId, action);
        }

        _emitStatsUpdated(user, orderId, caseId, action);
    }

    /// @dev Calculate score by rules and sync to ReputationScore.
    function _syncReputationByStats(
        address user,
        bytes32 orderId,
        StatsAction action
    ) internal {
        if (reputationScore == address(0)) return;
        Stats storage s = statsOf[user];
        uint256 completedTrades = s.completed;
        uint256 totalTrades = s.created; // +1 on order creation
        uint256 disputesLost = s.disputesLost;
        IReputationScore(reputationScore).updateScoreWithStats(
            user,
            completedTrades,
            totalTrades,
            disputesLost,
            orderId,
            uint8(action)
        );
    }

    /// @notice Update on order creation.
    /// @param buyer Buyer.
    /// @param seller Seller.
    /// @param orderId Order ID.
    /// @dev Updater only; records creation counters and order indexes.
    function updateOnCreate(
        address buyer,
        address seller,
        bytes32 orderId
    ) external onlyUpdater {
        updateOnAction(
            buyer,
            orderId,
            bytes32(0),
            ROLE_BUYER,
            StatsAction.Create
        );
        updateOnAction(
            seller,
            orderId,
            bytes32(0),
            ROLE_SELLER,
            StatsAction.Create
        );
    }

    /// @notice Update on order completion.
    /// @param buyer Buyer.
    /// @param seller Seller.
    /// @dev Updater only; increments completion counters.
    function updateOnComplete(
        address buyer,
        address seller,
        bytes32 orderId
    ) external onlyUpdater {
        updateOnAction(
            buyer,
            orderId,
            bytes32(0),
            ROLE_BUYER,
            StatsAction.Complete
        );
        updateOnAction(
            seller,
            orderId,
            bytes32(0),
            ROLE_SELLER,
            StatsAction.Complete
        );
    }

    /// @notice Update on order cancel/expiry.
    /// @param buyer Buyer.
    /// @param seller Seller.
    /// @dev Updater only; increments cancellation counters.
    function updateOnCancel(
        address buyer,
        address seller,
        bytes32 orderId
    ) external onlyUpdater {
        updateOnAction(
            buyer,
            orderId,
            bytes32(0),
            ROLE_BUYER,
            StatsAction.Cancel
        );
        updateOnAction(
            seller,
            orderId,
            bytes32(0),
            ROLE_SELLER,
            StatsAction.Cancel
        );
    }

    /// @notice Update when dispute is initiated.
    /// @param buyer Buyer.
    /// @param seller Seller.
    /// @param initiator Initiator address.
    /// @param orderId Order ID.
    /// @param caseId Arbitration case ID.
    /// @dev Updater only; increments dispute-init count and records case index (deduplicated).
    function updateOnDispute(
        address buyer,
        address seller,
        address initiator,
        bytes32 orderId,
        bytes32 caseId
    ) external onlyUpdater {
        // Mark initiator with initiator role.
        updateOnAction(
            initiator,
            orderId,
            caseId,
            ROLE_INITIATOR | ROLE_PARTY,
            StatsAction.Dispute
        );

        // If the counterparty is not initiator, also update to disputed, but role is PARTY.
        address other = (initiator == buyer) ? seller : buyer;
        updateOnAction(other, orderId, caseId, ROLE_PARTY, StatsAction.Dispute);
    }

    /// @notice Update win/loss and case records on arbitration result.
    /// @param winner Winner.
    /// @param loser Loser.
    /// @param orderId Order ID.
    /// @param caseId Arbitration case ID.
    /// @dev Updater only; increments win/loss counters and records both-side case indexes (deduplicated).
    function updateOnResolve(
        address winner,
        address loser,
        bytes32 orderId,
        bytes32 caseId
    ) external onlyUpdater {
        updateOnAction(
            winner,
            orderId,
            caseId,
            ROLE_PARTY,
            StatsAction.ResolveWin
        );
        updateOnAction(
            loser,
            orderId,
            caseId,
            ROLE_PARTY,
            StatsAction.ResolveLose
        );
    }

    /// @notice Update when juror is assigned.
    /// @param juror Juror address.
    /// @param caseId Case ID.
    /// @param orderId Order ID.
    /// @dev Updater only; add to ongoing list.
    function updateOnJurorAssign(
        address juror,
        bytes32 caseId,
        bytes32 orderId,
        uint8 role
    ) external onlyUpdater {
        if (_ongoingJurorIndex[juror][caseId] > 0) return;
        // if (_jurorCaseRecorded[juror][caseId]) return;
        // _jurorCaseRecorded[juror][caseId] = true;

        // Record to full list
        _jurorCases[juror].push(CaseRecord(caseId, orderId, role));
        // Record to ongoing list
        _ongoingJurorCases[juror].push(CaseRecord(caseId, orderId, role));
        _ongoingJurorIndex[juror][caseId] = _ongoingJurorCases[juror].length;
    }

    /// @notice Update when juror case is finished.
    /// @param juror Juror address.
    /// @param caseId Case ID.
    /// @dev Updater only; remove from ongoing and add to completed.
    function updateOnJurorComplete(
        address juror,
        bytes32 caseId
    ) external onlyUpdater {
        // Try removing from ongoing list (normal juror flow).
        uint256 idxPlusOne = _ongoingJurorIndex[juror][caseId];
        if (idxPlusOne > 0) {
            CaseRecord memory rec = _ongoingJurorCases[juror][idxPlusOne - 1];
            _removeOngoingJuror(juror, caseId);
            _completedJurorCases[juror].push(rec);
            return;
        }
    }

    /// @dev Emit stats updated event (single-user snapshot).
    function _emitStatsUpdated(
        address user,
        bytes32 orderId,
        bytes32 caseId,
        StatsAction action
    ) internal {
        Stats storage s = statsOf[user];
        int256 currentScore = 0;
        if (reputationScore != address(0)) {
            currentScore = IReputationScore(reputationScore).scoreOf(user);
        }
        emit StatsUpdated(
            user,
            s.created,
            s.completed,
            s.cancelled,
            s.disputesRaised,
            s.disputesWon,
            s.disputesLost,
            currentScore,
            orderId,
            caseId,
            action,
            uint64(block.timestamp)
        );
    }

    /// @dev O(1) removal of ongoing juror case.
    function _removeOngoingJuror(address user, bytes32 caseId) internal {
        uint256 idxPlusOne = _ongoingJurorIndex[user][caseId];
        if (idxPlusOne == 0) return;

        uint256 idx = idxPlusOne - 1;
        CaseRecord[] storage list = _ongoingJurorCases[user];
        uint256 lastIdx = list.length - 1;

        if (idx != lastIdx) {
            CaseRecord memory lastRec = list[lastIdx];
            list[idx] = lastRec;
            _ongoingJurorIndex[user][lastRec.caseId] = idxPlusOne;
        }
        list.pop();
        delete _ongoingJurorIndex[user][caseId];
    }

    /// @dev Remove from ongoing list via O(1) index.
    function _removeOngoing(address user, bytes32 orderId) internal {
        uint256 idxPlusOne = _ongoingIndex[user][orderId];
        if (idxPlusOne == 0) return; // Not found

        uint256 idx = idxPlusOne - 1;
        OrderRecord[] storage list = _ongoingOrders[user];
        uint256 lastIdx = list.length - 1;

        if (idx != lastIdx) {
            OrderRecord memory lastRec = list[lastIdx];
            list[idx] = lastRec;
            // Update index of moved element
            _ongoingIndex[user][lastRec.orderId] = idxPlusOne; // index + 1 = (idx + 1)
        }

        list.pop();
        delete _ongoingIndex[user][orderId];
    }

    /// @dev Remove from disputed list via O(1) index.
    function _removeDisputed(address user, bytes32 orderId) private {
        uint256 idxPlusOne = _disputedIndex[user][orderId];
        if (idxPlusOne == 0) return; // Not found

        uint256 idx = idxPlusOne - 1;
        OrderRecord[] storage list = _disputedOrders[user];
        uint256 lastIdx = list.length - 1;

        if (idx != lastIdx) {
            OrderRecord memory lastRec = list[lastIdx];
            list[idx] = lastRec;
            // Update index of moved element
            _disputedIndex[user][lastRec.orderId] = idxPlusOne; // index + 1 = (idx + 1)
        }

        list.pop();
        delete _disputedIndex[user][orderId];
    }

    /// @notice Get stats for a user.
    /// @param user User address.
    /// @return Stats struct.
    function getStats(address user) external view returns (Stats memory) {
        return statsOf[user];
    }

    /// @notice Query the three core reputation metrics (completed/total/lost disputes).
    /// @dev totalTrades = created (+1 when order is created, including canceled/ongoing)
    function getReputationSummary(
        address user
    )
        external
        view
        returns (
            uint256 completedTrades,
            uint256 totalTrades,
        uint256 disputesLost
    )
    {
        Stats storage s = statsOf[user];
        completedTrades = s.completed;
        totalTrades = uint256(s.created);
        disputesLost = s.disputesLost;
    }

    /// @notice Get order count for a specific list.
    function getOrdersCount(
        address user,
        uint256 status
    ) external view returns (uint256) {
        if (status == 1) return _ongoingOrders[user].length;
        if (status == 2) return _completedOrders[user].length;
        if (status == 3) return _cancelledOrders[user].length;
        if (status == 4) return _disputedOrders[user].length;
        return _orders[user].length;
    }

    /// @notice Paginated query for orders by status.
    function getOrdersByStatus(
        address user,
        uint256 status,
        uint256 offset,
        uint256 limit
    ) external view returns (OrderRecord[] memory items, uint256 total) {
        OrderRecord[] storage list;
        if (status == 1) list = _ongoingOrders[user];
        else if (status == 2) list = _completedOrders[user];
        else if (status == 3) list = _cancelledOrders[user];
        else if (status == 4) list = _disputedOrders[user];
        else list = _orders[user];

        total = list.length;
        if (offset >= total || limit == 0) return (new OrderRecord[](0), total);
        uint256 end = offset + limit > total ? total : offset + limit;
        items = new OrderRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) items[i - offset] = list[i];
    }

    /// @notice Get arbitration case record count.
    /// @notice Get total arbitration case records for a user.
    /// @param user User address.
    /// @return Case record count.
    function getCaseCount(address user) external view returns (uint256) {
        return _cases[user].length;
    }

    /// @notice Get arbitration case record at specific index.
    /// @notice Get user arbitration case record by index.
    /// @param user User address.
    /// @param index Index (0-based).
    /// @return Single case record.
    function getCaseRecord(
        address user,
        uint256 index
    ) external view returns (CaseRecord memory) {
        if (index >= _cases[user].length) revert OmniErrors.CaseIndexOOB();
        return _cases[user][index];
    }

    /// @notice Paginated query for arbitration case records.
    function getCaseRecords(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (CaseRecord[] memory items, uint256 total) {
        CaseRecord[] storage list = _cases[user];
        total = list.length;
        if (offset >= total || limit == 0) return (new CaseRecord[](0), total);
        uint256 end = offset + limit > total ? total : offset + limit;
        items = new CaseRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) items[i - offset] = list[i];
    }

    /// @notice Get juror stats.
    function getJurorStats(
        address juror
    )
        external
        view
        returns (uint256 total, uint256 ongoing, uint256 completed)
    {
        total = _jurorCases[juror].length;
        ongoing = _ongoingJurorCases[juror].length;
        completed = _completedJurorCases[juror].length;
    }

    /// @notice Paginated query for juror case records.
    function getJurorCases(
        address juror,
        uint256 offset,
        uint256 limit,
        uint8 filter
    ) external view returns (CaseRecord[] memory items, uint256 total) {
        CaseRecord[] storage list;
        if (filter == 1) list = _ongoingJurorCases[juror];
        else if (filter == 2) list = _completedJurorCases[juror];
        else list = _jurorCases[juror];

        total = list.length;
        if (offset >= total || limit == 0) return (new CaseRecord[](0), total);
        uint256 end = offset + limit > total ? total : offset + limit;
        items = new CaseRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) items[i - offset] = list[i];
    }
    uint256[50] private __gap;
}
