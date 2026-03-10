// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IReputationScore} from "../interfaces/IReputationScore.sol";
import {OmniErrors} from "../common/OmniErrors.sol";

/// @title ReputationScore
/// @notice Generic scoring system that computes and updates scores by metrics, with configurable bounds and rule params.
contract ReputationScore is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    IReputationScore
{
    /// @notice User score (stored only after first sync).
    mapping(address => int256) private _scoreOf;
    /// @notice Authorized callers that can update scores (usually escrow contracts).
    mapping(address => bool) public isUpdater;
    /// @notice Manager whitelist (can set updater/weights, etc.).
    mapping(address => bool) public isManager;

    /// @notice Minimum score (lower clamp).
    int256 public minScore;
    /// @notice Maximum score (upper clamp).
    int256 public maxScore;
    /// @notice Base score.
    uint16 public baseScore;
    /// @notice Completion reward: points per trade.
    uint16 public rewardPerTrade;
    /// @notice Completion reward cap.
    uint16 public rewardCap;
    /// @notice Dispute-loss penalty: points deducted per loss.
    uint16 public disputePenalty;
    /// @notice Completion-rate thresholds (bps, ascending, recommended to include 0).
    uint16[] private completionRateThresholds;
    /// @notice Completion-rate coefficients (bps, same length as thresholds).
    uint16[] private completionRateCoeffs;
    /// @notice Marks whether user has completed on-chain score sync.
    mapping(address => bool) private _isScoreSynced;
    uint256[49] private __gap;

    /// @notice Updater permission changed event
    event UpdaterSet(address indexed updater, bool allowed, uint64 timestamp);
    /// @notice Manager permission changed event
    event ManagerSet(address indexed manager, bool allowed, uint64 timestamp);
    /// @notice Score bounds updated event
    event ScoreBoundsUpdated(
        int256 minScore,
        int256 maxScore,
        uint64 timestamp
    );
    /// @notice Reputation rule config updated event
    event ScoreRuleConfigUpdated(
        uint16 baseScore,
        uint16 rewardPerTrade,
        uint16 rewardCap,
        uint16 disputePenalty,
        uint64 timestamp
    );
    /// @notice Completion-rate config updated event
    event CompletionRateConfigUpdated(uint16 count, uint64 timestamp);
    /// @notice User score updated event
    event ScoreUpdated(
        address indexed user,
        int256 delta,
        int256 newScore,
        bytes32 indexed businessId,
        uint8 actionType,
        uint64 timestamp
    );

    modifier onlyUpdater() {
        if (!isUpdater[msg.sender]) revert OmniErrors.NotUpdater();
        _;
    }

    modifier onlyOwnerOrManager() {
        if (msg.sender != owner() && !isManager[msg.sender])
            revert OmniErrors.NotAuthorized();
        _;
    }

    /// @notice Initialize, called once after proxy deployment.
    /// @param _owner Manager address.
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert OmniErrors.ZeroOwner();
        __Ownable_init(_owner);
        __Pausable_init();
        baseScore = 100;
        rewardPerTrade = 2;
        rewardCap = 1000;
        disputePenalty = 50;
        completionRateThresholds.push(0);
        completionRateThresholds.push(6000);
        completionRateThresholds.push(8000);
        completionRateCoeffs.push(5000);
        completionRateCoeffs.push(7000);
        completionRateCoeffs.push(10000);
        minScore = type(int256).min;
        maxScore = type(int256).max;
        isManager[_owner] = true;
    }

    /// @notice Pause contract (owner only).
    /// @dev Enter paused state, controlled by Pausable; owner only.
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /// @notice Unpause contract (owner only).
    /// @dev Exit paused state, controlled by Pausable; owner only.
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /// @notice Set score updater (e.g., escrow contract).
    /// @param upd Address to configure.
    /// @param allowed Whether allowed.
    /// @dev Only owner or manager can call. Grants/revokes score-update permission for an address.
    function setUpdater(address upd, bool allowed) external onlyOwnerOrManager {
        isUpdater[upd] = allowed;
        emit UpdaterSet(upd, allowed, uint64(block.timestamp));
    }

    /// @notice Set manager (can configure weights/updaters, etc.).
    /// @param manager Address to configure.
    /// @param allowed Whether allowed.
    /// @dev Only owner can call, grant/revoke manager permission.
    function setManager(address manager, bool allowed) external onlyOwner {
        isManager[manager] = allowed;
        emit ManagerSet(manager, allowed, uint64(block.timestamp));
    }

    /// @notice Query user score.
    /// @dev Unsynced addresses return base score by default (clamped by bounds).
    function scoreOf(address user) public view override returns (int256) {
        if (_isScoreSynced[user]) return _scoreOf[user];
        return _defaultScore();
    }

    /// @notice Set score bounds.
    /// @param minVal Minimum value.
    /// @param maxVal Maximum value.
    /// @dev Set score bounds for clamping; requires max >= min; owner only.
    function setScoreBounds(int256 minVal, int256 maxVal) external onlyOwner {
        if (maxVal < minVal) revert OmniErrors.BadBounds();
        minScore = minVal;
        maxScore = maxVal;
        emit ScoreBoundsUpdated(minVal, maxVal, uint64(block.timestamp));
    }

    /// @notice Set rule parameters (base/reward/penalty).
    function setScoreRuleConfig(
        uint16 baseScore_,
        uint16 rewardPerTrade_,
        uint16 rewardCap_,
        uint16 disputePenalty_
    ) external onlyOwner {
        baseScore = baseScore_;
        rewardPerTrade = rewardPerTrade_;
        rewardCap = rewardCap_;
        disputePenalty = disputePenalty_;
        emit ScoreRuleConfigUpdated(
            baseScore_,
            rewardPerTrade_,
            rewardCap_,
            disputePenalty_,
            uint64(block.timestamp)
        );
    }

    /// @notice Set completion-rate config (threshold and coefficient arrays must have same length).
    function setCompletionRateConfig(
        uint16[] calldata thresholds,
        uint16[] calldata coeffs
    ) external onlyOwner {
        if (thresholds.length == 0) revert OmniErrors.BadScoreTiers();
        if (thresholds.length != coeffs.length)
            revert OmniErrors.BadScoreDiscounts();
        if (thresholds[0] != 0) revert OmniErrors.BadScoreTiers();
        uint16 lastThreshold = thresholds[0];
        uint16 lastCoeff = coeffs[0];
        if (lastCoeff > 10000) revert OmniErrors.BadScoreDiscounts();
        for (uint256 i = 1; i < thresholds.length; i++) {
            if (thresholds[i] <= lastThreshold)
                revert OmniErrors.BadScoreTiers();
            if (coeffs[i] > 10000) revert OmniErrors.BadScoreDiscounts();
            if (coeffs[i] < lastCoeff) revert OmniErrors.BadScoreDiscounts();
            lastThreshold = thresholds[i];
            lastCoeff = coeffs[i];
        }
        delete completionRateThresholds;
        delete completionRateCoeffs;
        for (uint256 i = 0; i < thresholds.length; i++) {
            completionRateThresholds.push(thresholds[i]);
            completionRateCoeffs.push(coeffs[i]);
        }
        emit CompletionRateConfigUpdated(
            uint16(thresholds.length),
            uint64(block.timestamp)
        );
    }

    /// @notice Get completion-rate config.
    function getCompletionRateConfig()
        external
        view
        returns (
            uint16[] memory thresholds,
            uint16[] memory coeffs
        )
    {
        thresholds = completionRateThresholds;
        coeffs = completionRateCoeffs;
    }

    /// @notice Compute and sync score by three metrics (called by the stats contract).
    function updateScoreWithStats(
        address user,
        uint256 completedTrades,
        uint256 totalTrades,
        uint256 disputesLost,
        bytes32 businessId,
        uint8 actionType
    ) external override onlyUpdater {
        int256 score = _computeScoreFromStats(
            completedTrades,
            totalTrades,
            disputesLost
        );
        _setScoreInternal(user, score, businessId, actionType);
    }

    /// @notice Directly set user score (sync with business-side result).
    /// @dev Updater only; applies bounds clamping and emits ScoreUpdated.
    function setScore(
        address user,
        bytes32 businessId,
        uint8 actionType,
        int256 newScore
    ) external override onlyUpdater {
        _setScoreInternal(user, newScore, businessId, actionType);
    }

    function _setScoreInternal(
        address user,
        int256 newScore,
        bytes32 businessId,
        uint8 actionType
    ) internal {
        int256 clamped = _clampScore(newScore);
        bool wasSynced = _isScoreSynced[user];
        int256 oldScore = wasSynced ? _scoreOf[user] : _defaultScore();
        if (!wasSynced) {
            _isScoreSynced[user] = true;
        }
        int256 delta = clamped - oldScore;
        _scoreOf[user] = clamped;
        if (delta == 0) return;
        emit ScoreUpdated(
            user,
            delta,
            clamped,
            businessId,
            actionType,
            uint64(block.timestamp)
        );
    }

    function _computeScoreFromStats(
        uint256 completedTrades,
        uint256 totalTrades,
        uint256 disputesLost
    ) internal view returns (int256) {
        uint256 reward = completedTrades * rewardPerTrade;
        if (reward > rewardCap) reward = rewardCap;
        uint256 penalty = disputesLost * disputePenalty;
        int256 raw = int256(uint256(baseScore) + reward) - int256(penalty);
        uint16 coefBps = _completionCoefBps(
            completedTrades,
            totalTrades
        );
        return (raw * int256(uint256(coefBps))) / 10000;
    }

    function _completionCoefBps(
        uint256 completedTrades,
        uint256 totalTrades
    ) internal view returns (uint16) {
        if (completionRateThresholds.length == 0) return 10000;
        if (totalTrades == 0) return completionRateCoeffs[completionRateCoeffs.length - 1];
        uint256 rateBps = (completedTrades * 10000) / totalTrades;
        uint16 coeff = completionRateCoeffs[0];
        for (uint256 i = 0; i < completionRateThresholds.length; i++) {
            if (rateBps >= completionRateThresholds[i]) {
                coeff = completionRateCoeffs[i];
            } else {
                break;
            }
        }
        return coeff;
    }

    function _defaultScore() internal view returns (int256) {
        return _clampScore(int256(uint256(baseScore)));
    }

    function _clampScore(int256 value) internal view returns (int256) {
        if (value > maxScore) return maxScore;
        if (value < minScore) return minScore;
        return value;
    }

}
