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
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    IArbitrationAdapterExtended
} from "../interfaces/IArbitrationAdapterExtended.sol";
import {IArbitrable} from "../interfaces/IArbitrable.sol";
import {IJurorManager} from "../interfaces/IJurorManager.sol";
import {
    AssetType,
    CaseState,
    CaseQueryFilter,
    Vote,
    Evidence,
    JurorCaseRef,
    VoteRecord,
    CaseSummary,
    Case
} from "../common/Types.sol";
import {OmniErrors} from "../common/OmniErrors.sol";
import {IFeeManager} from "../interfaces/IFeeManager.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {IRegistry} from "../interfaces/IRegistry.sol";

interface IUserStats {
    function updateOnJurorAssign(
        address juror,
        bytes32 caseId,
        bytes32 orderId,
        uint8 role
    ) external;

    function updateOnJurorComplete(address juror, bytes32 caseId) external;

    function getJurorStats(
        address juror
    ) external view returns (uint256 total, uint256 ongoing, uint256 completed);
}

interface IEscrowRegistry {
    function registry() external view returns (address);
}

/// @title ArbitrationAdapter
/// @notice Arbitration Adapter
contract ArbitrationAdapter is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IArbitrationAdapterExtended
{
    using SafeERC20 for IERC20;

    /// @notice Registry address (used to read FeeManager and other configs).
    /// @dev Compatibility: If not set, it will fall back to reading from Escrow.registry().
    address public registry;

    /// @notice Case storage mapping: caseId -> Case details.
    mapping(bytes32 => Case) private cases; // caseId => Case details (including rounds)
    /// @notice Primary round vote duration.
    uint64 public voteDurationPrimary; // Primary round vote duration
    /// @notice Final round vote duration.
    uint64 public voteDurationFinal; // Final round vote duration
    /// @notice Primary round evidence window duration.
    uint64 public evidenceWindowPrimary; // Primary round evidence window
    /// @notice Final round evidence window duration.
    uint64 public evidenceWindowFinal; // Final round evidence window
    /// @notice Expert ruling vote duration (default same as final, can be shortened as needed).
    uint64 public voteDurationExpert;
    /// @notice Expert ruling evidence window duration (default same as final, can be shortened as needed).
    uint64 public evidenceWindowExpert;
    /// @notice Appeal period after primary round.
    uint64 public appealWindow;
    /// @notice Recently created case ID, convenient for frontend reading.
    bytes32 public lastCaseId;
    /// @notice Expert round case index (any expert can vote).
    bytes32[] private expertCases;
    /// @notice Juror management contract address.
    address public jurorManager;

    /// @dev Registry key: feeManager
    bytes32 private constant _FEE_MANAGER_KEY = bytes32("feeManager");
    /// @dev Registry key: userStats
    bytes32 private constant _USER_STATS_KEY = bytes32("userStats");

    /// @notice Primary round started, includes juror list and deadline.
    event PrimaryRoundStarted(
        bytes32 indexed caseId,
        bytes32 indexed orderId,
        address[] jurors,
        uint64 deadline,
        uint64 timestamp
    );
    /// @notice Final round started, includes juror list and deadline.
    event FinalRoundStarted(
        bytes32 indexed caseId,
        bytes32 indexed orderId,
        address[] jurors,
        uint64 deadline,
        uint64 timestamp
    );
    /// @notice Expert ruling started (triggered by tie), includes expert juror list and deadline.
    event ExpertRoundStarted(
        bytes32 indexed caseId,
        bytes32 indexed orderId,
        address[] jurors,
        uint64 deadline,
        uint64 timestamp
    );
    /// @notice Expert ruling extended (automatically extended window when no one votes).
    event ExpertRoundExtended(
        bytes32 indexed caseId,
        uint64 newDeadline,
        uint64 timestamp
    );
    /// @notice Case created (when Escrow requests arbitration).
    event CaseCreated(
        bytes32 indexed caseId,
        bytes32 indexed orderId,
        address indexed escrow,
        address requester,
        bytes evidenceCid,
        uint64 timestamp
    );
    /// @notice Evidence appended.
    event EvidenceSubmitted(
        bytes32 indexed caseId,
        address indexed submitter,
        bytes evidenceCid,
        uint64 timestamp
    );
    /// @notice Vote recorded.
    event Voted(
        bytes32 indexed caseId,
        address indexed juror,
        Vote vote,
        uint64 timestamp
    );
    /// @notice Case closed, includes round, winner, whether tie fallback.
    event CaseFinalized(
        bytes32 indexed caseId,
        bytes32 indexed orderId,
        uint8 round,
        address winner,
        bool isTie,
        uint64 timestamp
    );
    /// @notice Appeal opened (final round started) and fee paid.
    event AppealOpened(
        bytes32 indexed caseId,
        uint64 deadline,
        uint256 feePaid,
        address feeToken,
        uint64 timestamp
    );
    /// @notice Appeal fee distributed.
    event AppealFeeDistributed(
        bytes32 indexed caseId,
        uint8 round,
        uint256 platformShare,
        uint256 jurorShare,
        address feeToken,
        uint64 timestamp
    );

    /// @notice Initialize.
    /// @param _owner Admin address.
    /// @dev Called once after proxy deployment, initialize default parameters.
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert OmniErrors.ZeroOwner();
        __Ownable_init(_owner);
        __Pausable_init();
        __ReentrancyGuard_init();

        jurorManager = address(this);

        // Unified default xx minutes to avoid waiting too long for testing/demo
        voteDurationPrimary = 5 minutes;
        voteDurationFinal = 5 minutes;
        voteDurationExpert = 5 minutes;
        evidenceWindowPrimary = 5 minutes;
        evidenceWindowFinal = 5 minutes;
        evidenceWindowExpert = 5 minutes;
        appealWindow = 5 minutes;
    }

    /// @notice Set juror management contract.
    function setJurorManager(address _jurorManager) external onlyOwner {
        if (_jurorManager == address(0)) revert OmniErrors.ZeroJuror();
        jurorManager = _jurorManager;
    }

    /// @notice Pause contract (only owner).
    /// @dev Enter paused state; only owner can call.
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /// @notice Unpause contract (only owner).
    /// @dev Exit paused state; only owner can call.
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /// @notice Set Registry address (used to read FeeManager and other configs).
    /// @param registry_ Registry contract address.
    /// @dev Only owner can call; used to read FeeManager and other configs.
    function setRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert OmniErrors.ZeroRegistry();
        registry = registry_;
    }

    /// @notice Set primary/final round vote duration (seconds).
    /// @param primaryDuration Primary duration (seconds).
    /// @param finalDuration Final duration (seconds).
    /// @dev Only owner can call; both must be greater than 0.
    function setVoteDuration(
        uint64 primaryDuration,
        uint64 finalDuration
    ) external onlyOwner {
        if (primaryDuration == 0 || finalDuration == 0)
            revert OmniErrors.BadDuration();
        voteDurationPrimary = primaryDuration;
        voteDurationFinal = finalDuration;
    }

    /// @notice Set expert ruling vote duration (seconds).
    /// @param duration Expert ruling vote duration (seconds).
    /// @dev Only owner can call; must be greater than 0.
    function setVoteDurationExpert(uint64 duration) external onlyOwner {
        if (duration == 0) revert OmniErrors.BadDuration();
        voteDurationExpert = duration;
    }

    /// @notice Set primary/final round evidence window (seconds).
    /// @param primaryWindow Primary evidence window (seconds).
    /// @param finalWindow Final evidence window (seconds).
    /// @dev Only owner can call; both must be greater than 0.
    function setEvidenceWindow(
        uint64 primaryWindow,
        uint64 finalWindow
    ) external onlyOwner {
        if (primaryWindow == 0 || finalWindow == 0)
            revert OmniErrors.BadWindow();
        evidenceWindowPrimary = primaryWindow;
        evidenceWindowFinal = finalWindow;
    }

    /// @notice Set expert ruling evidence window (seconds).
    /// @param window Expert evidence window (seconds).
    /// @dev Only owner can call; must be greater than 0.
    function setEvidenceWindowExpert(uint64 window) external onlyOwner {
        if (window == 0) revert OmniErrors.BadWindow();
        evidenceWindowExpert = window;
    }

    /// @notice Set appeal period (seconds).
    /// @param window Appeal period (seconds).
    /// @dev Only owner can call; must be greater than 0.
    function setAppealWindow(uint64 window) external onlyOwner {
        if (window == 0) revert OmniErrors.BadWindow();
        appealWindow = window;
    }

    /// @notice Escrow contract requests arbitration, initialize as primary round.
    /// @param orderId Order ID.
    /// @param requester Requester (party initiating arbitration).
    /// @param evidence Evidence CID/data.
    /// @param context Business context.
    /// @return caseId New case ID.
    /// @dev Verify and start primary round (no primary appeal fee), randomly select jurors, emit event.
    function requestArbitration(
        bytes32 orderId,
        address requester,
        bytes calldata evidence,
        bytes calldata context
    ) external override returns (bytes32 caseId) {
        if (orderId == bytes32(0)) revert OmniErrors.EmptyOrderId();
        caseId = keccak256(
            abi.encodePacked(orderId, msg.sender, block.timestamp, requester)
        );
        lastCaseId = caseId;
        Case storage c = cases[caseId];
        if (c.escrow != address(0)) revert OmniErrors.CaseExists();
        c.escrow = msg.sender;
        c.orderId = orderId;
        c.round = 1;
        c.state = CaseState.Primary;
        c.requester = requester;
        c.context = context;

        // Fee config: appeal fee token matches business order payment token
        (, address feeToken, , , ) = IArbitrable(msg.sender)
            .getArbitrationValue(orderId);

        IFeeManager fm = _getFeeManager(msg.sender);
        uint16 platformBps = fm.appealFeePlatformBps();
        address platformRecipient = fm.appealFeeRecipient();
        c.feeToken = feeToken;
        c.platformBps = platformBps;
        c.platformRecipient = platformRecipient;
        c.deadline = uint64(block.timestamp + voteDurationPrimary);
        c.evidenceDeadline = uint64(block.timestamp + evidenceWindowPrimary);
        if (evidence.length > 0) {
            c.evidences.push(
                Evidence({
                    submitter: requester,
                    cid: evidence,
                    timestamp: uint64(block.timestamp)
                })
            );
        }
        c.jurors = IJurorManager(jurorManager).pickJurors(orderId, true);
        _setJurors(c.primaryJurors, c.jurors);
        _syncJurorsToStats(caseId, orderId, c.jurors, c.round);

        emit ArbitrationRequested(
            orderId,
            msg.sender,
            requester,
            evidence,
            context,
            uint64(block.timestamp)
        );
        emit CaseCreated(
            caseId,
            orderId,
            msg.sender,
            requester,
            evidence,
            uint64(block.timestamp)
        );
        emit PrimaryRoundStarted(
            caseId,
            orderId,
            c.jurors,
            c.deadline,
            uint64(block.timestamp)
        );
    }

    /// @notice Juror votes.
    /// @param caseId Case ID.
    /// @param v Vote option (Buyer/Seller).
    /// @dev Check eligibility and window; record and finalize/resolve when votes are gathered.
    function vote(bytes32 caseId, Vote v) external override {
        Case storage c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();
        if (c.resolved) revert OmniErrors.Resolved();

        CaseState state = c.state; // Cache state to save gas
        if (
            state != CaseState.Primary &&
            state != CaseState.Final &&
            state != CaseState.Expert
        ) {
            revert OmniErrors.BadState();
        }
        if (state == CaseState.Expert) {
            if (!IJurorManager(jurorManager).isExpertJuror(msg.sender))
                revert OmniErrors.NotExpertJuror();
            // Expert round: To ensure fee sharing covers the expert, add the first voting expert to the current round's juror list (if not already in the list).
            // This allows _distributeFee to distribute rewards to "current round valid voters (original jurors + experts)" equally based on vote count.
            if (!_isJurorInStorage(c.jurors, msg.sender)) {
                c.jurors.push(msg.sender);
                // Sync to current round's juror history to ensure getCaseJurors can find results
                if (c.round == 1) {
                    c.primaryJurors.push(msg.sender);
                } else if (c.round == 2) {
                    c.finalJurors.push(msg.sender);
                }
                // Expert claim: Immediately record participation status
                address statsAddr = _tryGetUserStats();
                if (statsAddr != address(0)) {
                    IUserStats(statsAddr).updateOnJurorAssign(
                        msg.sender,
                        caseId,
                        c.orderId,
                        3 // Role: Expert
                    );
                }
            }
        } else {
            if (!_isJurorInStorage(c.jurors, msg.sender))
                revert OmniErrors.NotJuror();
        }
        if (v != Vote.Buyer && v != Vote.Seller) revert OmniErrors.BadVote();
        if (c.votes[msg.sender] != Vote.None) revert OmniErrors.AlreadyVoted();

        c.votes[msg.sender] = v;
        if (v == Vote.Buyer) c.yesCount += 1;
        else c.noCount += 1;
        _recordVote(c, msg.sender, v);
        emit Voted(caseId, msg.sender, v, uint64(block.timestamp));

        if (state == CaseState.Expert) {
            // Expert round: any whitelisted expert can vote first; first vote decides.
            _resolve(caseId, c, false);
        } else if (c.yesCount + c.noCount == c.jurors.length) {
            _finalize(caseId, c, false);
        }
    }

    /// @notice Anyone can trigger settlement after deadline (if not all voted).
    /// @param caseId Case ID.
    /// @dev Handle timeout or enter final state; if no appeal and expired, directly FinalResolved.
    function finalize(bytes32 caseId) external {
        Case storage c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();
        if (c.resolved) revert OmniErrors.Resolved();
        if (block.timestamp < c.deadline) revert OmniErrors.NotDue();
        if (
            c.state == CaseState.PrimaryResolved &&
            !c.finalRequested &&
            block.timestamp >= c.appealDeadline
        ) {
            // Primary round concluded and no appeal, confirm result after expiration
            c.resolved = true;
            c.state = CaseState.FinalResolved;
            _callbackToArbitrable(caseId, c, true);
            emit CaseFinalized(
                caseId,
                c.orderId,
                c.round,
                c.winner,
                false,
                uint64(block.timestamp)
            );
        } else {
            _finalize(caseId, c, true);
        }
    }

    /// @notice Pay final round fee within appeal period and start final round.
    /// @param caseId Case ID.
    /// @dev Verify appeal period, pay final round fee, reset ticket and start final round.
    function appeal(bytes32 caseId) external payable override nonReentrant {
        Case storage c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();
        if (
            c.state != CaseState.PrimaryResolved &&
            c.state != CaseState.AppealPending
        ) revert OmniErrors.CannotAppeal();
        if (block.timestamp > c.appealDeadline)
            revert OmniErrors.AppealExpired();
        if (c.finalRequested) revert OmniErrors.FinalRequested();
        // Collect final round fee (native or ERC20), if already pre-deposited, do not charge again
        if (!c.finalFeePaid) {
            // Final round fee amount: order payment amount * rate (bps)
            (uint256 finalFee, address feeToken) = calcAppealFee(
                c.escrow,
                c.orderId
            );
            if (c.feeToken != feeToken) revert OmniErrors.UnsupportedPayment();
            if (finalFee > 0) {
                if (feeToken == address(0)) {
                    if (msg.value != finalFee) revert OmniErrors.BadFinalFee();
                    c.feeFinal += msg.value;
                } else {
                    if (msg.value != 0) revert OmniErrors.UnexpectedValue();
                    c.feeFinal += finalFee;
                    IERC20(feeToken).safeTransferFrom(
                        msg.sender,
                        address(this),
                        finalFee
                    );
                }
            } else {
                if (msg.value != 0) revert OmniErrors.UnexpectedValue();
            }
            c.finalFeePaid = true;
            c.finalFeePayer = msg.sender;
        } else {
            if (msg.value != 0) revert OmniErrors.UnexpectedValue();
        }
        c.finalRequested = true;
        c.round = 2;
        c.state = CaseState.Final;
        c.yesCount = 0;
        c.noCount = 0;
        _resetVotes(c);
        c.jurors = IJurorManager(jurorManager).pickJurors(c.orderId, false);
        _setJurors(c.finalJurors, c.jurors);
        _syncJurorsToStats(caseId, c.orderId, c.jurors, c.round);
        c.deadline = uint64(block.timestamp + voteDurationFinal);
        c.evidenceDeadline = uint64(block.timestamp + evidenceWindowFinal);
        emit FinalRoundStarted(
            caseId,
            c.orderId,
            c.jurors,
            c.deadline,
            uint64(block.timestamp)
        );
        emit AppealOpened(
            caseId,
            c.deadline,
            c.feeFinal,
            c.feeToken,
            uint64(block.timestamp)
        );
    }

    /// @notice Append evidence CID, off-chain storage IPFS/Arweave.
    /// @param caseId Case ID.
    /// @param evidenceCid Evidence CID/data.
    /// @dev Verify window and append to evidences.
    function submitEvidence(
        bytes32 caseId,
        bytes calldata evidenceCid
    ) external override {
        Case storage c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();
        if (c.resolved) revert OmniErrors.Resolved();
        if (evidenceCid.length == 0) revert OmniErrors.EmptyEvidence();
        if (
            c.state != CaseState.Primary &&
            c.state != CaseState.Final &&
            c.state != CaseState.Expert
        ) {
            revert OmniErrors.EvidenceNotActive();
        }
        if (block.timestamp > c.evidenceDeadline)
            revert OmniErrors.EvidenceWindowClosed();
        c.evidences.push(
            Evidence({
                submitter: msg.sender,
                cid: evidenceCid,
                timestamp: uint64(block.timestamp)
            })
        );
        emit EvidenceSubmitted(
            caseId,
            msg.sender,
            evidenceCid,
            uint64(block.timestamp)
        );
    }

    /// @notice Deposit arbitration reward and distribute.
    function depositReward(
        bytes32 caseId
    ) external payable override nonReentrant {
        Case storage c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();

        uint256 amount = 0;
        if (msg.value > 0) {
            amount = msg.value;
        } else {
            // ERC20 reward: Need to authorize first or transfer from business contract directly then call this method (assumed already transferred)
            // Here we adopt "transfer first then trigger" mode, or business contract transfers directly
            // For simplicity, assume business contract has transferred corresponding tokens to this contract, or we pull from msg.sender.
            // Actually in Escrow logic, it is safeTransfer to arbitrator.
            // So we should check the balance increase of this contract.
            // But for generality, if msg.value is 0, we try to get token from escrow's getArbitrationValue.
            (, address token, , , ) = IArbitrable(msg.sender)
                .getArbitrationValue(c.orderId);
            if (token != address(0)) {
                // Currently do not handle ERC20 depositReward auto-trigger, recommend business contract transfers directly to FeeManager and let FM distribute.
                // Or pull here.
            }
        }

        if (amount > 0) {
            _distributeReward(caseId, c, amount, c.feeToken);
        }
    }

    function _distributeReward(
        bytes32,
        Case storage c,
        uint256 amount,
        address token
    ) internal {
        address fm = address(_getFeeManager(c.escrow));
        IFeeDistributor distributor = IFeeDistributor(fm);

        // Get current round valid voters
        uint256 voterCount = 0;
        for (uint256 i = 0; i < c.jurors.length; i++) {
            if (c.votes[c.jurors[i]] != Vote.None) voterCount++;
        }

        address[] memory voters = new address[](voterCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < c.jurors.length; i++) {
            if (c.votes[c.jurors[i]] != Vote.None) {
                voters[idx] = c.jurors[i];
                idx++;
            }
        }

        if (token == address(0)) {
            distributor.distributeArbitrationReward{value: amount}(
                c.orderId,
                token,
                amount,
                voters
            );
        } else {
            IERC20(token).safeTransfer(fm, amount);
            distributor.distributeArbitrationReward(
                c.orderId,
                token,
                amount,
                voters
            );
        }
    }

    /// @notice Pre-pay final round fee.
    /// @param caseId Case ID.
    /// @dev Pay final round fee in allowed state and record final payer.
    function fundFinalAppeal(
        bytes32 caseId
    ) external payable override nonReentrant {
        Case storage c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();
        if (c.resolved) revert OmniErrors.Resolved();
        if (c.finalFeePaid) revert OmniErrors.FinalFeePaid();
        if (
            c.state != CaseState.PrimaryResolved &&
            c.state != CaseState.AppealPending
        ) revert OmniErrors.CannotFund();
        (uint256 finalFee, address feeToken) = calcAppealFee(
            c.escrow,
            c.orderId
        );
        if (c.feeToken != feeToken) revert OmniErrors.UnsupportedPayment();
        if (finalFee > 0) {
            if (feeToken == address(0)) {
                if (msg.value != finalFee) revert OmniErrors.BadFinalFee();
                c.feeFinal += msg.value;
            } else {
                if (msg.value != 0) revert OmniErrors.UnexpectedValue();
                c.feeFinal += finalFee;
                IERC20(feeToken).safeTransferFrom(
                    msg.sender,
                    address(this),
                    finalFee
                );
            }
        } else {
            if (msg.value != 0) revert OmniErrors.UnexpectedValue();
        }
        c.finalFeePaid = true;
        c.finalFeePayer = msg.sender;
    }

    /// @notice Get currently effective appeal fee config.
    /// @return primaryFee Primary fee.
    /// @return finalFee Final fee.
    /// @return feeToken Fee asset.
    /// @return platformBps Platform share (bps).
    /// @return platformRecipient Platform recipient address.
    function getAppealFeeConfig()
        external
        view
        returns (
            uint256 primaryFee,
            uint256 finalFee,
            address feeToken,
            uint16 platformBps,
            address platformRecipient
        )
    {
        IFeeManager fm = _getFeeManagerFromRegistry();
        primaryFee = fm.appealFeePrimary();
        finalFee = fm.appealFeeFinal();
        feeToken = fm.appealFeeToken();
        platformBps = fm.appealFeePlatformBps();
        platformRecipient = fm.appealFeeRecipient();
    }

    /// @dev Settle current round: handle expiration, vote count result or tie branch.
    /// @param caseId Case ID.
    /// @param c Case storage reference.
    /// @param isTimeout Whether triggered by timeout.
    function _finalize(
        bytes32 caseId,
        Case storage c,
        bool isTimeout
    ) internal {
        // AppealPending timeout fallback
        if (c.state == CaseState.AppealPending) {
            if (block.timestamp < c.appealDeadline)
                revert OmniErrors.AppealPending();
            _resolveTieAsCancel(caseId, c);
            return;
        }
        if (
            c.state != CaseState.Primary &&
            c.state != CaseState.Final &&
            c.state != CaseState.Expert
        ) {
            revert OmniErrors.BadState();
        }
        if (c.yesCount + c.noCount == 0 && isTimeout) {
            // Expired with no votes, considered tie
            if (c.state == CaseState.Expert) {
                // If experts don't vote, automatically extend window to avoid forced fallback
                c.deadline = uint64(block.timestamp + voteDurationExpert);
                c.evidenceDeadline = uint64(
                    block.timestamp + evidenceWindowExpert
                );
                emit ExpertRoundExtended(
                    caseId,
                    c.deadline,
                    uint64(block.timestamp)
                );
            } else {
                _handleTie(caseId, c);
            }
            return;
        }
        if (c.yesCount > c.noCount) {
            _resolve(caseId, c, false);
        } else if (c.noCount > c.yesCount) {
            _resolve(caseId, c, false);
        } else {
            _handleTie(caseId, c);
        }
    }

    /// @dev Handle tie: Enter expert ruling (any expert whitelist member can vote to decide), avoid no result.
    /// @param caseId Case ID.
    /// @param c Case storage reference.
    function _handleTie(bytes32 caseId, Case storage c) internal {
        _startExpertRound(caseId, c);
    }

    /// @dev Start expert ruling round, allow any expert whitelist member to preemptively vote to determine outcome.
    /// @dev Note: We do not clear the original juror list and original vote counts because:
    /// 1) Fee distribution needs to know "current round valid voters" (including original jurors and expert tie-breaker);
    /// 2) Experts only cast a "tie-breaker" vote, keeping the original vote count base is more intuitive;
    /// 3) Jurors who did not vote will not receive rewards during fee distribution (filtered by votes[j] == Vote.None).
    function _startExpertRound(bytes32 caseId, Case storage c) internal {
        if (IJurorManager(jurorManager).expertCount() == 0)
            revert OmniErrors.NoExperts();
        c.state = CaseState.Expert;
        c.deadline = uint64(block.timestamp + voteDurationExpert);
        c.evidenceDeadline = uint64(block.timestamp + evidenceWindowExpert);
        expertCases.push(caseId);
        emit ExpertRoundStarted(
            caseId,
            c.orderId,
            c.jurors,
            c.deadline,
            uint64(block.timestamp)
        );
    }

    /// @dev Clean up previous round juror's voting status.
    function _resetVotes(Case storage c) internal {
        for (uint256 i = 0; i < c.jurors.length; i++) {
            if (c.jurors[i] != address(0)) {
                c.votes[c.jurors[i]] = Vote.None;
            }
        }
    }

    /// @dev Record vote details (by round).
    function _recordVote(Case storage c, address juror, Vote v) internal {
        uint64 ts = uint64(block.timestamp);
        if (c.state == CaseState.Expert) {
            if (!_isJurorInStorage(c.expertJurors, juror)) {
                c.expertJurors.push(juror);
            }
            c.expertVotes.push(
                VoteRecord({juror: juror, vote: v, timestamp: ts})
            );
        }
        if (c.round == 1) {
            c.primaryVotes.push(
                VoteRecord({juror: juror, vote: v, timestamp: ts})
            );
        } else if (c.round == 2) {
            c.finalVotes.push(
                VoteRecord({juror: juror, vote: v, timestamp: ts})
            );
        }
    }

    /// @dev Actually close case: update status, emit event, and callback escrow contract.
    function _resolve(bytes32 caseId, Case storage c, bool isTie) internal {
        (, , , address partyA, address partyB) = IArbitrable(c.escrow)
            .getArbitrationValue(c.orderId);
        c.winner = c.yesCount >= c.noCount ? partyA : partyB;

        _syncJurorCompletion(caseId, partyA, partyB, c.jurors);

        if (c.round == 1) {
            c.state = CaseState.PrimaryResolved;
            c.appealDeadline = uint64(block.timestamp + appealWindow);
            c.deadline = c.appealDeadline;
            _distributeFee(caseId, c, c.feePrimary, c.requester);
            c.feePrimary = 0;
            // After primary round result, enter appeal period: only record result, do not immediately callback business contract;
            // If no appeal during appeal period, finalize triggers result; if appeal, enter final round.
            c.resolved = false;
        } else {
            c.resolved = true;
            c.state = CaseState.FinalResolved;
            _distributeFee(
                caseId,
                c,
                c.feeFinal,
                c.finalFeePayer == address(0) ? c.requester : c.finalFeePayer
            );
            c.feeFinal = 0;
            _callbackToArbitrable(caseId, c, true);
        }
        emit CaseFinalized(
            caseId,
            c.orderId,
            c.round,
            c.winner,
            isTie,
            uint64(block.timestamp)
        );
    }

    /// @dev Final round tie fallback: considered buyer win (refund and return).
    /// @param caseId Case ID.
    /// @param c Case storage reference.
    function _resolveTieAsCancel(bytes32 caseId, Case storage c) internal {
        c.resolved = true;
        c.state = CaseState.FinalResolved;

        // Considered buyer (Party A) win, trigger refund and return
        (, , , address partyA, address partyB) = IArbitrable(c.escrow)
            .getArbitrationValue(c.orderId);
        c.winner = partyA;

        _syncJurorCompletion(caseId, partyA, partyB, c.jurors);

        _distributeFee(
            caseId,
            c,
            c.feeFinal,
            c.finalFeePayer == address(0) ? c.requester : c.finalFeePayer
        );
        c.feeFinal = 0;
        _callbackToArbitrable(caseId, c, true);
        emit CaseFinalized(
            caseId,
            c.orderId,
            c.round,
            c.winner,
            true,
            uint64(block.timestamp)
        );
    }

    /// @dev Distribute appeal fee: via FeeManager (IFeeDistributor).
    /// @param caseId Case ID.
    /// @param c Case storage reference.
    /// @param amount Total fee amount to distribute.
    /// @param payer Address to refund remaining fee (if any).
    function _distributeFee(
        bytes32 caseId,
        Case storage c,
        uint256 amount,
        address payer
    ) internal {
        if (amount == 0) return;

        address fm = address(_getFeeManager(c.escrow));
        IFeeDistributor distributor = IFeeDistributor(fm);

        // Get list of jurors participating in this round's voting
        uint256 voterCount = 0;
        for (uint256 i = 0; i < c.jurors.length; i++) {
            if (c.votes[c.jurors[i]] != Vote.None) {
                voterCount++;
            }
        }

        address[] memory voters = new address[](voterCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < c.jurors.length; i++) {
            if (c.votes[c.jurors[i]] != Vote.None) {
                voters[idx] = c.jurors[i];
                idx++;
            }
        }

        // Transfer funds to distributor and execute distribution
        if (c.feeToken == address(0)) {
            distributor.distributeAppealFee{value: amount}(
                caseId,
                c.round,
                c.feeToken,
                amount,
                c.platformRecipient,
                c.platformBps,
                voters,
                payer
            );
        } else {
            IERC20(c.feeToken).safeTransfer(fm, amount);
            distributor.distributeAppealFee(
                caseId,
                c.round,
                c.feeToken,
                amount,
                c.platformRecipient,
                c.platformBps,
                voters,
                payer
            );
        }

        emit AppealFeeDistributed(
            caseId,
            c.round,
            (amount * c.platformBps) / 10_000,
            voterCount > 0
                ? (amount * (10_000 - c.platformBps)) / 10_000 / voterCount
                : 0,
            c.feeToken,
            uint64(block.timestamp)
        );
    }

    /// @dev Read FeeManager from associated Escrow contract or local registry.
    /// @param escrow Escrow contract address.
    /// @return FeeManager interface reference.
    function _getFeeManager(
        address escrow
    ) internal view returns (IFeeManager) {
        address reg = registry;
        if (reg == address(0)) {
            reg = IEscrowRegistry(escrow).registry();
        }
        if (reg == address(0)) revert OmniErrors.ZeroRegistry();
        address fm = IRegistry(reg).records(_FEE_MANAGER_KEY);
        if (fm == address(0)) revert OmniErrors.FeeManagerNotSet();
        return IFeeManager(fm);
    }

    /// @dev Read FeeManager from Registry; throw error if not configured.
    /// @return FeeManager interface reference.
    function _getFeeManagerFromRegistry() internal view returns (IFeeManager) {
        if (registry == address(0)) revert OmniErrors.ZeroRegistry();
        address fm = IRegistry(registry).records(_FEE_MANAGER_KEY);
        if (fm == address(0)) revert OmniErrors.FeeManagerNotSet();
        return IFeeManager(fm);
    }

    /// @notice Calculate appeal fee based on order payment amount (final round).
    /// @param client Escrow contract address.
    /// @param orderId Order ID.
    /// @return fee Appeal fee amount.
    /// @return token Appeal fee asset address.
    function calcAppealFee(
        address client,
        bytes32 orderId
    ) public view override returns (uint256 fee, address token) {
        uint16 bps = _getFeeManagerFromRegistry().appealFeeFinalBps();

        (uint256 amount, address token_, , , ) = IArbitrable(client)
            .getArbitrationValue(orderId);
        token = token_;
        if (bps == 0) return (0, token);
        fee = (amount * uint256(bps)) / 10_000;
    }

    /// @dev Callback business contract (IArbitrable) to finalize arbitration result.
    /// @param caseId Case ID.
    /// @param c Case storage reference.
    function _callbackToArbitrable(
        bytes32 caseId,
        Case storage c,
        bool
    ) internal {
        IArbitrable(c.escrow).onArbitrationResolved(
            caseId,
            c.orderId,
            c.winner
        );
        emit ArbitrationResolved(
            c.orderId,
            c.escrow,
            c.winner,
            "",
            uint64(block.timestamp)
        );
    }

    /// @dev Check if address is in storage array.
    /// @param list Storage juror array.
    /// @param account Query address.
    /// @return Whether exists.
    function _isJurorInStorage(
        address[] storage list,
        address account
    ) internal view returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == account) return true;
        }
        return false;
    }

    /// @dev Write memory juror array to storage array (overwrite).
    /// @param dst Storage destination.
    /// @param src Memory source.
    function _setJurors(address[] storage dst, address[] memory src) internal {
        while (dst.length > 0) {
            dst.pop();
        }
        for (uint256 i = 0; i < src.length; i++) {
            dst.push(src[i]);
        }
    }

    function _syncJurorsToStats(
        bytes32 caseId,
        bytes32 orderId,
        address[] memory jurors,
        uint8 round
    ) internal {
        address stats = _tryGetUserStats();
        if (stats == address(0)) return;
        for (uint256 i = 0; i < jurors.length; i++) {
            if (jurors[i] != address(0)) {
                IUserStats(stats).updateOnJurorAssign(
                    jurors[i],
                    caseId,
                    orderId,
                    round
                );
            }
        }
    }

    function _syncJurorCompletion(
        bytes32 caseId,
        address partyA,
        address partyB,
        address[] memory jurors
    ) internal {
        address stats = _tryGetUserStats();
        if (stats == address(0)) return;
        IUserStats(stats).updateOnJurorComplete(partyA, caseId);
        IUserStats(stats).updateOnJurorComplete(partyB, caseId);
        for (uint256 i = 0; i < jurors.length; i++) {
            if (jurors[i] != address(0)) {
                IUserStats(stats).updateOnJurorComplete(jurors[i], caseId);
            }
        }
    }

    function _tryGetUserStats() internal view returns (address) {
        if (registry == address(0)) return address(0);
        return IRegistry(registry).records(_USER_STATS_KEY);
    }

    function getCase(
        bytes32 caseId
    )
        external
        view
        override
        returns (
            address escrow,
            bytes32 orderId,
            bool resolved,
            address winner,
            address[] memory jurors,
            bytes[] memory evidences
        )
    {
        Case storage c = cases[caseId];
        escrow = c.escrow;
        orderId = c.orderId;
        resolved = c.resolved;
        winner = c.winner;
        jurors = c.jurors;
        evidences = new bytes[](c.evidences.length);
        for (uint256 i = 0; i < c.evidences.length; i++) {
            evidences[i] = c.evidences[i].cid;
        }
    }

    /// @notice Batch query case summaries (for list display).
    function getCases(
        bytes32[] calldata caseIds
    ) external view override returns (CaseSummary[] memory items) {
        uint256 count = caseIds.length;
        if (count > 50) revert OmniErrors.BatchTooLarge();
        items = new CaseSummary[](count);
        for (uint256 i = 0; i < count; i++) {
            bytes32 caseId = caseIds[i];
            Case storage c = cases[caseId];
            items[i] = CaseSummary({
                caseId: caseId,
                escrow: c.escrow,
                orderId: c.orderId,
                state: uint8(c.state),
                round: c.round,
                deadline: c.deadline,
                evidenceDeadline: c.evidenceDeadline,
                appealDeadline: c.appealDeadline,
                resolved: c.resolved,
                winner: c.winner,
                requester: c.requester,
                finalFeePayer: c.finalFeePayer,
                yesCount: c.yesCount,
                noCount: c.noCount,
                feeToken: c.feeToken,
                feePrimary: c.feePrimary,
                feeFinal: c.feeFinal
            });
        }
    }

    /// @notice Convenient query for appeal deadline.
    function appealDeadline(
        bytes32 caseId
    ) external view override returns (uint64) {
        return cases[caseId].appealDeadline;
    }

    /// @notice Get case details (including status/fee/deadline, etc.).
    function getCaseDetail(
        bytes32 caseId
    )
        external
        view
        override
        returns (
            address escrow,
            bytes32 orderId,
            uint8 state,
            uint8 round,
            uint64 deadline,
            uint64 evidenceDeadline,
            uint64 appealDeadlineTs,
            uint256 feePrimary,
            uint256 feeFinal,
            address feeToken,
            bool resolved,
            address winner,
            address requester,
            address finalFeePayer,
            uint256 yesCount,
            uint256 noCount,
            address[] memory jurors,
            bytes memory context,
            bytes[] memory evidences
        )
    {
        Case storage c = cases[caseId];
        escrow = c.escrow;
        orderId = c.orderId;
        state = uint8(c.state);
        round = c.round;
        deadline = c.deadline;
        evidenceDeadline = c.evidenceDeadline;
        appealDeadlineTs = c.appealDeadline;
        feePrimary = c.feePrimary;
        feeFinal = c.feeFinal;
        feeToken = c.feeToken;
        resolved = c.resolved;
        winner = c.winner;
        requester = c.requester;
        finalFeePayer = c.finalFeePayer;
        yesCount = c.yesCount;
        noCount = c.noCount;
        jurors = c.jurors;
        context = c.context;
        evidences = new bytes[](c.evidences.length);
        for (uint256 i = 0; i < c.evidences.length; i++) {
            evidences[i] = c.evidences[i].cid;
        }
    }

    /// @notice Paginated query juror list for a case.
    function getCaseJurors(
        bytes32 caseId,
        uint8 round,
        uint256 offset,
        uint256 limit
    ) external view override returns (address[] memory items, uint256 total) {
        Case storage c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();
        address[] storage list;
        if (round == 1) {
            list = c.primaryJurors;
        } else if (round == 2) {
            list = c.finalJurors;
        } else if (round == 3) {
            list = c.expertJurors;
        } else {
            revert OmniErrors.BadRound();
        }
        total = list.length;
        if (offset >= total || limit == 0) {
            return (new address[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        items = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            items[i - offset] = list[i];
        }
    }

    /// @notice Paginated query vote details for a case.
    function getCaseVotes(
        bytes32 caseId,
        uint8 round,
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (VoteRecord[] memory items, uint256 total)
    {
        Case storage c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();
        VoteRecord[] storage list;
        if (round == 1) {
            list = c.primaryVotes;
        } else if (round == 2) {
            list = c.finalVotes;
        } else if (round == 3) {
            list = c.expertVotes;
        } else {
            revert OmniErrors.BadRound();
        }
        total = list.length;
        if (offset >= total || limit == 0) {
            return (new VoteRecord[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        items = new VoteRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            items[i - offset] = list[i];
        }
    }

    function _requireCase(
        bytes32 caseId
    ) internal view returns (Case storage c) {
        c = cases[caseId];
        if (c.escrow == address(0)) revert OmniErrors.NoCase();
    }

    /// @notice Get evidence list for a case.
    function getCaseEvidences(
        bytes32 caseId
    ) external view returns (bytes[] memory items) {
        Case storage c = _requireCase(caseId);
        uint256 len = c.evidences.length;
        items = new bytes[](len);
        for (uint256 i = 0; i < len; i++) {
            items[i] = c.evidences[i].cid;
        }
    }

    uint256[50] private __gap;

    receive() external payable {}
}
