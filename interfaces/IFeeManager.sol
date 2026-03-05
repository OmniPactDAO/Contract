// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {AssetType} from "../common/Types.sol";

/// @title IFeeManager
/// @notice Fee Manager Interface: Unified management of creation fees, protocol fees, appeal fees, and payment/collateral whitelists and native coin switches.
interface IFeeManager {
    // ========= Whitelist/Switch =========

    /// @notice Whether native token is allowed as payment asset.
    function allowNativePayment() external view returns (bool);

    /// @notice Whether native token is allowed as collateral asset.
    function allowNativeCollateral() external view returns (bool);

    /// @notice Payment ERC20 whitelist.
    function paymentTokenWhitelist(address token) external view returns (bool);

    /// @notice Get payment ERC20 whitelist.
    function getPaymentTokens() external view returns (address[] memory);

    /// @notice Collateral ERC20 whitelist.
    function collateralTokenWhitelist(
        address token
    ) external view returns (bool);

    /// @notice Get collateral ERC20 whitelist.
    function getCollateralTokens() external view returns (address[] memory);

    // ========= Creation Fee =========

    /// @notice Fixed fee for creating escrow (native token valuation, wei).
    function createEscrowFee() external view returns (uint256);

    /// @notice Creation fee recipient address.
    function createFeeRecipient() external view returns (address);

    // ========= Protocol Fee (deducted from paymentAsset upon settlement) =========

    /// @notice Protocol fee recipient address.
    function protocolFeeRecipient() external view returns (address);

    /// @notice Base protocol fee rate (bps).
    function protocolFeeBps() external view returns (uint16);

    /// @notice Discounted protocol fee rate when paying with governance token (bps).
    function protocolFeeBpsGov() external view returns (uint16);

    /// @notice Governance token address (used for discount).
    function governanceToken() external view returns (address);

    /// @notice Return "base protocol fee config" (excluding dynamic user discount).
    /// @param assetType Payment asset type (Native/ERC20).
    /// @param token Payment asset token address (pass address(0) for Native).
    /// @return recipient Protocol fee recipient address.
    /// @return bps Base protocol fee rate (bps).
    function quoteProtocolFee(
        AssetType assetType,
        address token
    ) external view returns (address recipient, uint16 bps);

    /// @notice Return "protocol fee config after dynamic payer discount".
    /// @dev Discount rules are configured internally in FeeManager: based on `ReputationScore.scoreOf(payer)`.
    /// @param payer Payer (usually buyer; if third-party payment is supported in the future, pass the actual payer here).
    /// @param assetType Payment asset type (Native/ERC20).
    /// @param token Payment asset token address (pass address(0) for Native).
    /// @return recipient Protocol fee recipient address.
    /// @return bps Discounted protocol fee rate (bps).
    function quoteProtocolFeeFor(
        address payer,
        AssetType assetType,
        address token
    ) external view returns (address recipient, uint16 bps);

    /// @notice Preview "protocol fee rate by payer" (including base rate, discount, score and holdings).
    /// @dev This method provides a more readable query entry for frontend/external systems.
    /// @param payer Payer.
    /// @param assetType Payment asset type (Native/ERC20).
    /// @param token Payment asset token address (pass address(0) for Native).
    /// @return recipient Protocol fee recipient address.
    /// @return appliedBps Discounted protocol fee rate (bps).
    /// @return baseBps Base protocol fee rate (bps).
    /// @return discountBps Actual effective discount (bps).
    /// @return score Payer's current score (from ReputationScore.scoreOf).
    /// @return govBalance Reserved field (currently unused).
    function previewProtocolFeeFor(
        address payer,
        AssetType assetType,
        address token
    )
        external
        view
        returns (
            address recipient,
            uint16 appliedBps,
            uint16 baseBps,
            uint16 discountBps,
            int256 score,
            uint256 govBalance
        );

    /// @notice Preview protocol fee amount after reputation score discount (for frontend display).
    /// @param payer Payer address.
    /// @param amount Order amount (used to calculate fee amount).
    /// @return recipient Protocol fee recipient address.
    /// @return appliedBps Discounted rate (bps).
    /// @return baseBps Base rate (bps).
    /// @return rateBps Fee rate multiplier (bps, 10000=100%).
    /// @return score Payer score.
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
        );

    /// @notice Get reputation score discount tier config.
    function getScoreFeeDiscountConfig()
        external
        view
        returns (uint16[] memory thresholds, uint16[] memory rateBps);

    /// @notice Set reputation score contract address (for discount query).
    function setReputationScore(address reputationScore) external;

    // ========= Appeal Fee (Arbitration System) =========

    /// @notice Primary appeal fee (0 means free).
    function appealFeePrimary() external view returns (uint256);

    /// @notice Final appeal fee (0 means free).
    function appealFeeFinal() external view returns (uint256);

    /// @notice Primary appeal fee rate (bps, 0-10000).
    function appealFeePrimaryBps() external view returns (uint16);

    /// @notice Final appeal fee rate (bps, 0-10000).
    function appealFeeFinalBps() external view returns (uint16);

    /// @notice Appeal fee asset: address(0)=native, non-0=ERC20.
    function appealFeeToken() external view returns (address);

    /// @notice Appeal fee platform share (bps, percentage of total).
    function appealFeePlatformBps() external view returns (uint16);

    /// @notice Appeal fee platform recipient address.
    function appealFeeRecipient() external view returns (address);

    // ========= Arbitration Reward / Penalty (snapshot at order creation) =========

    /// @notice Arbitration reward fee rate (bps), deducted from payment asset to arbitrator.
    function arbRewardBps() external view returns (uint16);

    /// @notice Seller default collateral payout ratio (bps).
    function collateralPenaltyBps() external view returns (uint16);

    // ========= Management Interface (owner) =========

    /// @notice Set manager (can adjust config on behalf of owner).
    function setManager(address account, bool allowed) external;

    /// @notice Manager whitelist.
    function isManager(address account) external view returns (bool);

    function setAllowNativePayment(bool allowed) external;

    function setAllowNativeCollateral(bool allowed) external;

    function setPaymentToken(address token, bool allowed) external;

    function setCollateralToken(address token, bool allowed) external;

    /// @notice Set creation fee and recipient.
    function setCreateFeeConfig(uint256 fee, address recipient) external;

    /// @notice Set protocol fee config (including governance token parameters).
    function setProtocolFeeConfig(
        address recipient,
        uint16 feeBps,
        uint16 feeBpsGov,
        address governanceToken_
    ) external;

    /// @notice Set reputation score discount tiers (effective when score >= threshold).
    function setScoreFeeDiscountConfig(
        uint16[] calldata thresholds,
        uint16[] calldata rateBps
    ) external;

    /// @notice Set appeal fee config (including platform share).
    function setAppealFeeConfig(
        uint256 primaryFee,
        uint256 finalFee,
        address feeToken,
        uint16 platformBps,
        address platformRecipient
    ) external;

    /// @notice Set appeal fee rate config (including platform share).
    function setAppealFeeBpsConfig(
        uint16 primaryBps,
        uint16 finalBps,
        uint16 platformBps,
        address platformRecipient
    ) external;

    /// @notice Get currently effective appeal fee rate config.
    function getAppealFeeBpsConfig()
        external
        view
        returns (
            uint16 primaryBps,
            uint16 finalBps,
            uint16 platformBps,
            address platformRecipient
        );

    /// @notice Set arbitration reward fee rate (snapshot at order creation).
    function setArbRewardBps(uint16 arbRewardBps) external;

    /// @notice Set collateral penalty ratio (snapshot at order creation).
    function setCollateralPenaltyBps(uint16 collateralPenaltyBps) external;
}
