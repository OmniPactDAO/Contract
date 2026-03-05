// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {AssetType} from "../common/Types.sol";
import {IFeeManager} from "../interfaces/IFeeManager.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {OmniErrors} from "../common/OmniErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @dev ReputationScore only needs to expose `scoreOf(address)` read interface.
interface ReputationScoreReader {
    function scoreOf(address user) external view returns (int256);
}

/// @dev ERC20 only needs `balanceOf(address)` read interface.
interface ERC20Reader {
    function balanceOf(address user) external view returns (uint256);
}

/// @title FeeManager
/// @notice Unified management of "fees and whitelist" configuration within the protocol, and handles fee distribution.
/// @dev Points to current FeeManager via Registry.records(bytes32("feeManager")).
contract FeeManager is
    IFeeManager,
    IFeeDistributor,
    OwnableUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    /// @notice Manager whitelist: allows agents to adjust configuration on behalf of owner (usually granted to FactoryProxy/AdapterProxy).
    mapping(address => bool) public isManager;

    /// @notice Payment ERC20 whitelist.
    mapping(address => bool) public paymentTokenWhitelist;
    /// @notice Collateral ERC20 whitelist.
    mapping(address => bool) public collateralTokenWhitelist;

    /// @notice Payment token list.
    address[] private _paymentTokens;
    /// @notice Collateral token list.
    address[] private _collateralTokens;

    /// @notice Index + 1 of payment token in array.
    mapping(address => uint256) private _paymentTokenIndex;
    /// @notice Index + 1 of collateral token in array.
    mapping(address => uint256) private _collateralTokenIndex;

    /// @notice Whether native token is allowed as payment asset.
    bool public allowNativePayment;
    /// @notice Whether native token is allowed as collateral asset.
    bool public allowNativeCollateral;

    /// @notice Fixed fee for creating escrow (native token valuation, wei).
    uint256 public createEscrowFee;
    /// @notice Creation fee recipient address.
    address public createFeeRecipient;

    /// @notice Protocol fee recipient address (deducted from paymentAsset during settlement).
    address public protocolFeeRecipient;
    /// @notice Base protocol fee rate (bps).
    uint16 public protocolFeeBps;
    /// @notice Governance token payment discount fee rate (bps).
    uint16 public protocolFeeBpsGov;
    /// @notice Governance token address (used for protocol fee configuration).
    address public governanceToken;

    /// @notice Reputation score contract address (ReputationScore), used for score discount query.
    address public reputationScore;

    /// @notice Primary appeal fee (0 means free).
    uint256 public appealFeePrimary;
    /// @notice Final appeal fee (0 means free).
    uint256 public appealFeeFinal;
    /// @notice Appeal fee asset: address(0)=native, non-0=ERC20.
    address public appealFeeToken;
    /// @notice Appeal fee platform share (bps) and recipient address.
    uint16 public appealFeePlatformBps;
    address public appealFeeRecipient;

    /// @notice Arbitration reward fee rate (bps), deducted from payment asset to arbitrator.
    uint16 public arbRewardBps;
    /// @notice Seller default collateral payout ratio (bps).
    uint16 public collateralPenaltyBps;
    /// @notice Primary appeal fee rate (bps, 0-10000).
    uint16 public appealFeePrimaryBps;
    /// @notice Final appeal fee rate (bps, 0-10000).
    uint16 public appealFeeFinalBps;

    /// @notice Basis point denominator: 10000 bps = 100%.
    uint16 public constant BPS_DENOM = 10_000;
    /// @dev Placeholder to force bytecode update
    uint256 private __upgrade_patch_v2;
    /// @notice Protocol fee cap (bps): 5000 = 50% (prevent misconfiguration).
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 5000;
    /// @notice Initialization complete event
    /// Semantic: Record contract owner and initialization time for audit and frontend state sync
    event Initialized(address indexed owner, uint64 timestamp);
    /// @notice Set payment token whitelist event
    /// Semantic: Record whether an ERC20 token is included in the payment whitelist, with timestamp
    event PaymentTokenSet(
        address indexed token,
        bool allowed,
        uint64 timestamp
    );
    /// @notice Set collateral token whitelist event
    /// Semantic: Record whether an ERC20 token is included in the collateral whitelist, with timestamp
    event CollateralTokenSet(
        address indexed token,
        bool allowed,
        uint64 timestamp
    );
    /// @notice Native payment toggle update event
    /// Semantic: Toggle whether native token is allowed as payment asset
    event AllowNativePaymentUpdated(bool allowed, uint64 timestamp);
    /// @notice Native collateral toggle update event
    /// Semantic: Toggle whether native token is allowed as collateral asset
    event AllowNativeCollateralUpdated(bool allowed, uint64 timestamp);
    /// @notice Creation fee config update event
    /// Semantic: Record creation fee amount and recipient adjustment
    event CreateFeeConfigUpdated(
        uint256 fee,
        address indexed recipient,
        uint64 timestamp
    );
    /// @notice Protocol fee config update event
    /// Semantic: Record protocol fee recipient, base rate, governance token discount rate and governance token address
    event ProtocolFeeConfigUpdated(
        address indexed recipient,
        uint16 feeBps,
        uint16 feeBpsGov,
        address governanceToken,
        uint64 timestamp
    );
    /// @notice Reputation score contract address update event
    event ReputationScoreUpdated(address indexed score, uint64 timestamp);
    /// @notice Reputation score discount config update event
    /// Semantic: Record number of discount tiers for external tracking of config changes
    event ScoreFeeDiscountConfigUpdated(uint16 count, uint64 timestamp);
    /// @notice Appeal fee config update event
    /// Semantic: Record primary/final fees, fee asset, platform share and recipient
    event AppealFeeConfigUpdated(
        uint256 primaryFee,
        uint256 finalFee,
        address feeToken,
        uint16 platformBps,
        address indexed platformRecipient,
        uint64 timestamp
    );
    /// @notice Appeal fee rate config update event
    /// Semantic: Record primary/final rates and platform share and recipient
    event AppealFeeBpsConfigUpdated(
        uint16 primaryBps,
        uint16 finalBps,
        uint16 platformBps,
        address indexed platformRecipient,
        uint64 timestamp
    );
    /// @notice Arbitration reward rate update event
    /// Semantic: Record new rate for arbitration reward (bps)
    event ArbRewardBpsUpdated(uint16 arbRewardBps, uint64 timestamp);
    /// @notice Collateral penalty ratio update event
    /// Semantic: Record seller default collateral payout ratio (bps)
    event CollateralPenaltyBpsUpdated(
        uint16 collateralPenaltyBps,
        uint64 timestamp
    );
    /// @notice Manager whitelist update event
    /// Semantic: Record whether an address is granted/removed management rights
    event ManagerUpdated(
        address indexed account,
        bool allowed,
        uint64 timestamp
    );

    modifier onlyOwnerOrManager() {
        if (msg.sender != owner() && !isManager[msg.sender])
            revert OmniErrors.NotAuthorized();
        _;
    }

    /// @notice Initialize (recommended to call once even for non-proxy deployment to maintain consistent deployment habit).
    /// @param _owner Admin address.
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __Pausable_init();
        isManager[_owner] = true;
        createFeeRecipient = _owner;
        protocolFeeRecipient = _owner;
        appealFeeRecipient = _owner;
        collateralPenaltyBps = BPS_DENOM;
        allowNativePayment = true;
        allowNativeCollateral = true;
        emit Initialized(_owner, uint64(block.timestamp));
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

    /// @notice Set manager (can adjust configuration on behalf of owner, usually FactoryProxy/AdapterProxy).
    /// @param account Manager address.
    /// @param allowed Whether to allow.
    /// @dev Only owner can call; manager can execute some configuration adjustments.
    function setManager(
        address account,
        bool allowed
    ) external override onlyOwnerOrManager {
        if (account == address(0)) revert OmniErrors.ZeroAccount();
        isManager[account] = allowed;
        emit ManagerUpdated(account, allowed, uint64(block.timestamp));
    }

    /// @notice Whether native token is allowed as payment asset.
    /// @param allowed Whether to allow.
    /// @dev Only owner or manager can call.
    function setAllowNativePayment(
        bool allowed
    ) external override onlyOwnerOrManager {
        allowNativePayment = allowed;
        emit AllowNativePaymentUpdated(allowed, uint64(block.timestamp));
    }

    /// @notice Whether native token is allowed as collateral asset.
    /// @param allowed Whether to allow.
    /// @dev Only owner or manager can call.
    function setAllowNativeCollateral(
        bool allowed
    ) external override onlyOwnerOrManager {
        allowNativeCollateral = allowed;
        emit AllowNativeCollateralUpdated(allowed, uint64(block.timestamp));
    }

    /// @notice Set payment ERC20 whitelist.
    /// @param token Token address.
    /// @param allowed Whether to allow.
    /// @dev Only owner or manager can call.
    function setPaymentToken(
        address token,
        bool allowed
    ) external override onlyOwnerOrManager {
        if (token == address(0)) revert OmniErrors.ZeroToken();

        bool isAlreadyIn = paymentTokenWhitelist[token];
        if (allowed && !isAlreadyIn) {
            _paymentTokens.push(token);
            _paymentTokenIndex[token] = _paymentTokens.length;
        } else if (!allowed && isAlreadyIn) {
            uint256 indexPlusOne = _paymentTokenIndex[token];
            if (indexPlusOne > 0) {
                uint256 index = indexPlusOne - 1;
                uint256 lastIndex = _paymentTokens.length - 1;
                if (index != lastIndex) {
                    address lastToken = _paymentTokens[lastIndex];
                    _paymentTokens[index] = lastToken;
                    _paymentTokenIndex[lastToken] = index + 1;
                }
                _paymentTokens.pop();
                delete _paymentTokenIndex[token];
            }
        }

        paymentTokenWhitelist[token] = allowed;
        emit PaymentTokenSet(token, allowed, uint64(block.timestamp));
    }

    /// @notice Set collateral ERC20 whitelist.
    /// @param token Token address.
    /// @param allowed Whether to allow.
    /// @dev Only owner or manager can call.
    function setCollateralToken(
        address token,
        bool allowed
    ) external override onlyOwnerOrManager {
        if (token == address(0)) revert OmniErrors.ZeroToken();

        bool isAlreadyIn = collateralTokenWhitelist[token];
        if (allowed && !isAlreadyIn) {
            _collateralTokens.push(token);
            _collateralTokenIndex[token] = _collateralTokens.length;
        } else if (!allowed && isAlreadyIn) {
            uint256 indexPlusOne = _collateralTokenIndex[token];
            if (indexPlusOne > 0) {
                uint256 index = indexPlusOne - 1;
                uint256 lastIndex = _collateralTokens.length - 1;
                if (index != lastIndex) {
                    address lastToken = _collateralTokens[lastIndex];
                    _collateralTokens[index] = lastToken;
                    _collateralTokenIndex[lastToken] = index + 1;
                }
                _collateralTokens.pop();
                delete _collateralTokenIndex[token];
            }
        }

        collateralTokenWhitelist[token] = allowed;
        emit CollateralTokenSet(token, allowed, uint64(block.timestamp));
    }

    /// @notice Get payment ERC20 whitelist.
    function getPaymentTokens()
        external
        view
        override
        returns (address[] memory)
    {
        return _paymentTokens;
    }

    /// @notice Get collateral ERC20 whitelist.
    function getCollateralTokens()
        external
        view
        override
        returns (address[] memory)
    {
        return _collateralTokens;
    }

    /// @notice Set fixed fee and recipient for creating escrow.
    /// @param fee Creation fee (wei).
    /// @param recipient Recipient address.
    /// @dev Only owner or manager can call.
    function setCreateFeeConfig(
        uint256 fee,
        address recipient
    ) external override onlyOwnerOrManager {
        if (recipient == address(0)) revert OmniErrors.ZeroRecipient();
        createEscrowFee = fee;
        createFeeRecipient = recipient;
        emit CreateFeeConfigUpdated(fee, recipient, uint64(block.timestamp));
    }

    /// @notice Set base protocol fee and governance token discount.
    /// @param recipient Protocol fee recipient address.
    /// @param feeBps Base fee rate (bps).
    /// @param feeBpsGov Discount fee rate when paying with governance token (bps).
    /// @param governanceToken_ Governance token address.
    /// @dev Only owner or manager can call; feeBps must not exceed MAX_PROTOCOL_FEE_BPS.
    function setProtocolFeeConfig(
        address recipient,
        uint16 feeBps,
        uint16 feeBpsGov,
        address governanceToken_
    ) external override onlyOwnerOrManager {
        if (recipient == address(0)) revert OmniErrors.ZeroRecipient();
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert OmniErrors.FeeTooHigh();
        if (feeBpsGov > feeBps) revert OmniErrors.GovFeeTooHigh();
        protocolFeeRecipient = recipient;
        protocolFeeBps = feeBps;
        protocolFeeBpsGov = feeBpsGov;
        governanceToken = governanceToken_;
        emit ProtocolFeeConfigUpdated(
            recipient,
            feeBps,
            feeBpsGov,
            governanceToken_,
            uint64(block.timestamp)
        );
    }

    /// @notice Set reputation score contract address.
    function setReputationScore(
        address reputationScore_
    ) external onlyOwnerOrManager {
        reputationScore = reputationScore_;
        emit ReputationScoreUpdated(reputationScore_, uint64(block.timestamp));
    }

    /// @notice Set reputation score discount tiers (effective when score >= threshold).
    /// @param thresholds Score thresholds (ascending).
    /// @param rateBps Fee rate multiplier (bps, 10000=100%).
    /// @dev Thresholds must be ascending; rate multiplier must be <= 10000, and it is recommended not to increase (higher score should not be more expensive).
    function setScoreFeeDiscountConfig(
        uint16[] calldata thresholds,
        uint16[] calldata rateBps
    ) external onlyOwnerOrManager {
        if (thresholds.length != rateBps.length)
            revert OmniErrors.BadScoreDiscounts();
        if (thresholds.length > 0) {
            uint16 lastThreshold = thresholds[0];
            uint16 lastRate = rateBps[0];
            if (lastRate > BPS_DENOM) revert OmniErrors.BadMaxDiscount();
            for (uint256 i = 1; i < thresholds.length; i++) {
                if (thresholds[i] <= lastThreshold)
                    revert OmniErrors.BadScoreTiers();
                if (rateBps[i] > BPS_DENOM)
                    revert OmniErrors.BadMaxDiscount();
                // High score should not be more expensive: rate multiplier should be monotonically non-increasing
                if (rateBps[i] > lastRate)
                    revert OmniErrors.BadScoreDiscounts();
                lastThreshold = thresholds[i];
                lastRate = rateBps[i];
            }
        }

        delete scoreFeeThresholds;
        delete scoreFeeRateBps;
        for (uint256 i = 0; i < thresholds.length; i++) {
            scoreFeeThresholds.push(thresholds[i]);
            scoreFeeRateBps.push(rateBps[i]);
        }

        emit ScoreFeeDiscountConfigUpdated(
            uint16(thresholds.length),
            uint64(block.timestamp)
        );
    }

    /// @notice Get reputation score discount tier configuration.
    function getScoreFeeDiscountConfig()
        external
        view
        returns (uint16[] memory thresholds, uint16[] memory rateBps)
    {
        thresholds = scoreFeeThresholds;
        rateBps = scoreFeeRateBps;
    }

    /// @notice Set appeal fee config (including platform share).
    /// @param primaryFee Primary fee.
    /// @param finalFee Final fee.
    /// @param feeToken Fee asset (0 is native).
    /// @param platformBps Platform share (bps).
    /// @param platformRecipient Platform recipient address.
    /// @dev Only owner or manager; platformBps can be 0; when positive, recipient address must be provided.
    function setAppealFeeConfig(
        uint256 primaryFee,
        uint256 finalFee,
        address feeToken,
        uint16 platformBps,
        address platformRecipient
    ) external override onlyOwnerOrManager {
        if (platformBps > BPS_DENOM) revert OmniErrors.BadPlatformBps();
        if (platformBps > 0) {
            if (platformRecipient == address(0))
                revert OmniErrors.ZeroPlatformRecipient();
        }
        appealFeePrimary = primaryFee;
        appealFeeFinal = finalFee;
        appealFeeToken = feeToken;
        appealFeePlatformBps = platformBps;
        appealFeeRecipient = platformRecipient;
        emit AppealFeeConfigUpdated(
            primaryFee,
            finalFee,
            feeToken,
            platformBps,
            platformRecipient,
            uint64(block.timestamp)
        );
    }

    /// @notice Set appeal fee rate config (including platform share).
    /// @param primaryBps Primary fee rate (bps).
    /// @param finalBps Final fee rate (bps).
    /// @param platformBps Platform share (bps).
    /// @param platformRecipient Platform recipient address.
    /// @dev Only owner or manager; bps cannot exceed BPS_DENOM.
    function setAppealFeeBpsConfig(
        uint16 primaryBps,
        uint16 finalBps,
        uint16 platformBps,
        address platformRecipient
    ) external override onlyOwnerOrManager {
        if (primaryBps > BPS_DENOM || finalBps > BPS_DENOM)
            revert OmniErrors.BadBps();
        if (platformBps > BPS_DENOM) revert OmniErrors.BadPlatformBps();
        if (platformBps > 0) {
            if (platformRecipient == address(0))
                revert OmniErrors.ZeroPlatformRecipient();
        }
        appealFeePrimaryBps = primaryBps;
        appealFeeFinalBps = finalBps;
        appealFeePlatformBps = platformBps;
        appealFeeRecipient = platformRecipient;
        emit AppealFeeBpsConfigUpdated(
            primaryBps,
            finalBps,
            platformBps,
            platformRecipient,
            uint64(block.timestamp)
        );
    }

    /// @notice Get currently effective appeal fee rate config.
    function getAppealFeeBpsConfig()
        external
        view
        returns (
            uint16 primaryBps,
            uint16 finalBps,
            uint16 platformBps,
            address platformRecipient
        )
    {
        primaryBps = appealFeePrimaryBps;
        finalBps = appealFeeFinalBps;
        platformBps = appealFeePlatformBps;
        platformRecipient = appealFeeRecipient;
    }

    /// @notice Set arbitration reward fee rate (bps).
    /// @param arbRewardBps_ Reward fee rate (bps).
    /// @dev Allocates to arbitrator proportionally from payment asset; only owner or manager.
    function setArbRewardBps(
        uint16 arbRewardBps_
    ) external override onlyOwnerOrManager {
        if (arbRewardBps_ > BPS_DENOM) revert OmniErrors.BadArbRewardBps();
        arbRewardBps = arbRewardBps_;
        emit ArbRewardBpsUpdated(arbRewardBps_, uint64(block.timestamp));
    }

    /// @notice Set collateral penalty ratio (bps).
    /// @param collateralPenaltyBps_ Penalty ratio (bps).
    /// @dev Only owner or manager; snapshot is taken when order is created.
    function setCollateralPenaltyBps(
        uint16 collateralPenaltyBps_
    ) external override onlyOwnerOrManager {
        if (collateralPenaltyBps_ > BPS_DENOM)
            revert OmniErrors.BadCollateralBps();
        collateralPenaltyBps = collateralPenaltyBps_;
        emit CollateralPenaltyBpsUpdated(
            collateralPenaltyBps_,
            uint64(block.timestamp)
        );
    }

    /// @notice Return base protocol fee config (excluding dynamic discount by payer).
    /// @param assetType Payment asset type (Native/ERC20).
    /// @param token Payment asset address (pass address(0) for Native).
    /// @return recipient Protocol fee recipient address.
    /// @return bps Base protocol fee rate (bps).
    function quoteProtocolFee(
        AssetType assetType,
        address token
    ) external view override returns (address recipient, uint16 bps) {
        recipient = protocolFeeRecipient;
        bps = protocolFeeBps;
        // Note: This method only returns "base protocol fee config", does not include dynamic discount by user;
        // If you need the rate after discount by payer, please use `quoteProtocolFeeFor/previewProtocolFeeFor`.
        assetType;
        token;
    }

    /// @notice Return protocol fee config after dynamic discount by payer.
    /// @param payer Payer address.
    /// @param assetType Payment asset type (Native/ERC20).
    /// @param token Payment asset address (pass address(0) for Native).
    /// @return recipient Protocol fee recipient address.
    /// @return bps Rate after dynamic discount (bps).
    function quoteProtocolFeeFor(
        address payer,
        AssetType assetType,
        address token
    ) external view override returns (address recipient, uint16 bps) {
        (recipient, bps, , , , ) = this.previewProtocolFeeFor(
            payer,
            assetType,
            token
        );
    }

    /// @notice Preview protocol fee details with dynamic discount by payer.
    /// @param payer Payer address.
    /// @param assetType Payment asset type (Native/ERC20).
    /// @param token Payment asset address (pass address(0) for Native).
    /// @return recipient Protocol fee recipient address.
    /// @return appliedBps Actual effective rate (baseBps - discountBps).
    /// @return baseBps Base rate (bps).
    /// @return discountBps Discount (bps).
    /// @return score Payer's score (from ReputationScore).
    /// @return govBalance Reserved field (currently unused, always 0).
    function previewProtocolFeeFor(
        address payer,
        AssetType assetType,
        address token
    )
        external
        view
        override
        returns (
            address recipient,
            uint16 appliedBps,
            uint16 baseBps,
            uint16 discountBps,
            int256 score,
            uint256 govBalance
        )
    {
        // Currently discount is unrelated to payment asset type (protocol fee is deducted from paymentAsset, discount only depends on payer), but parameters are reserved for future extension.
        assetType;
        token;

        recipient = protocolFeeRecipient;
        baseBps = protocolFeeBps;
        if (reputationScore != address(0)) {
            score = ReputationScoreReader(reputationScore).scoreOf(payer);
        }
        uint16 rateBps = _scoreFeeRateBps(score);
        appliedBps = uint16((uint256(baseBps) * rateBps) / BPS_DENOM);
        discountBps = baseBps > appliedBps ? baseBps - appliedBps : 0;
        govBalance = 0;
    }

    /// @notice Preview protocol fee amount after reputation score discount (for frontend display).
    /// @param payer Payer address.
    /// @param amount Order amount (used to calculate fee amount).
    /// @return recipient Protocol fee recipient address.
    /// @return appliedBps Discounted rate (bps).
    /// @return baseBps Base rate (bps).
    /// @return rateBps Fee rate multiplier (bps, 10000=100%).
    /// @return score Payer's score.
    /// @return feeAmount Discounted fee amount.
    function previewProtocolFeeByScore(
        address payer,
        uint256 amount
    )
        external
        view
        returns (
            address recipient,
            uint16 appliedBps,
            uint16 baseBps,
            uint16 rateBps,
            int256 score,
            uint256 feeAmount
        )
    {
        recipient = protocolFeeRecipient;
        baseBps = protocolFeeBps;
        if (reputationScore != address(0)) {
            score = ReputationScoreReader(reputationScore).scoreOf(payer);
        }
        rateBps = _scoreFeeRateBps(score);
        appliedBps = uint16((uint256(baseBps) * rateBps) / BPS_DENOM);
        feeAmount = (amount * appliedBps) / BPS_DENOM;
    }

    /// @dev Return fee rate multiplier based on reputation score (bps).
    function _scoreFeeRateBps(int256 score) internal view returns (uint16) {
        if (scoreFeeThresholds.length == 0) return BPS_DENOM;
        uint256 s = score <= 0 ? 0 : uint256(score);
        uint16 rate = BPS_DENOM;
        for (uint256 i = 0; i < scoreFeeThresholds.length; i++) {
            if (s >= scoreFeeThresholds[i]) {
                rate = scoreFeeRateBps[i];
            } else {
                break;
            }
        }
        return rate;
    }

    // ========= IFeeDistributor Implementation =========

    /// @notice Distribute appeal fee.
    function distributeAppealFee(
        bytes32,
        uint8,
        address token,
        uint256 totalAmount,
        address platformRecipient,
        uint16 platformBps,
        address[] calldata recipients,
        address payer
    ) external payable override whenNotPaused onlyOwnerOrManager {
        if (totalAmount == 0) return;

        uint256 platformShare = (totalAmount * platformBps) / BPS_DENOM;
        uint256 remaining = totalAmount - platformShare;

        if (platformShare > 0) {
            _transfer(token, platformRecipient, platformShare);
        }

        uint256 distributed = 0;
        if (recipients.length > 0 && remaining > 0) {
            uint256 per = remaining / recipients.length;
            if (per > 0) {
                for (uint256 i = 0; i < recipients.length; i++) {
                    _transfer(token, recipients[i], per);
                    distributed += per;
                }
            }
        }

        uint256 leftover = remaining > distributed
            ? remaining - distributed
            : 0;
        if (leftover > 0 && payer != address(0)) {
            _transfer(token, payer, leftover);
        }
    }

    /// @notice Settle arbitration reward.
    function distributeArbitrationReward(
        bytes32,
        address token,
        uint256 amount,
        address[] calldata recipients
    ) external payable override whenNotPaused onlyOwnerOrManager {
        if (amount == 0 || recipients.length == 0) return;

        uint256 per = amount / recipients.length;
        if (per > 0) {
            for (uint256 i = 0; i < recipients.length; i++) {
                _transfer(token, recipients[i], per);
            }
        }
    }

    /// @notice Distribute losing party's collateral penalty.
    function distributeCollateralPenalty(
        bytes32,
        address token,
        uint256 totalAmount,
        uint16 penaltyBps,
        address winner,
        address loser
    ) external payable override whenNotPaused onlyOwnerOrManager {
        if (totalAmount == 0) return;

        uint256 penalty = (totalAmount * penaltyBps) / BPS_DENOM;
        uint256 remainder = totalAmount - penalty;

        if (penalty > 0 && winner != address(0)) {
            _transfer(token, winner, penalty);
        }

        if (remainder > 0 && loser != address(0)) {
            _transfer(token, loser, remainder);
        }
    }

    function _transfer(address token, address to, uint256 amount) internal {
        if (to == address(0) || amount == 0) return;
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Reputation score discount thresholds (ascending).
    uint16[] private scoreFeeThresholds;
    /// @notice Corresponding fee rate multiplier for reputation score (bps, 0-10000, 10000=100%).
    uint16[] private scoreFeeRateBps;

    uint256[50] private __gap;
}
