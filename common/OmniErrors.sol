// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title Errors
/// @notice Custom error set.
library OmniErrors {
    // common / ownership / registry
    error ZeroOwner();
    error ZeroAdmin();
    error ZeroRegistry();
    error ZeroVault();
    error ZeroAddress();
    error ZeroAccount();
    error ZeroToken();
    error ZeroImplementation();
    error ZeroEscrow();
    error ZeroValue();
    error ZeroRecipient();
    error ZeroJuror();
    error ZeroParty();
    error SameParty();
    error ZeroArbitrator();
    error ZeroPayToken();
    error ZeroCollateralToken();
    error ZeroCreateRecipient();
    error ZeroFeeRecipient();

    // permissions
    error NotOwner();
    error NotManager();
    error NotUpdater();
    error NotAuthorized();
    error NotBuyer();
    error NotSeller();
    error NotArbitrator();
    error NotParticipant();
    error NotJuror();
    error NotExpertJuror();
    error NotEscrow();

    // escrow manager - order/asset/state
    error BadOffchainRule();
    error BadBounds();
    error BonusOverflow();
    error BadCreateFee();
    error CreateFeeTransferFailed();
    error UnexpectedValue();
    error OrderExists();
    error OrderNotFound();
    error AlreadyFunded();
    error AssetRequired();
    error CollateralRequired();
    error AssetLocked();
    error CollateralLocked();
    error NoCollateral();
    error BuyerNotFunded();
    error AssetNotLocked();
    error BadState();
    error CannotCancel();
    error NotExpired();
    error Finalized();
    error UnknownOrder();
    error EmptyCid();
    error NotDisputed();
    error InvalidWinner();
    error BadMsgValue();
    error UnsupportedPayment();
    error UnsupportedTarget();
    error BadCollateralValue();
    error CollateralAssetNotAllowed();
    error FeeExceedsAmount();
    error ArbitratorNotAllowed();
    error BadDeadline();
    error ZeroPrice();
    error ZeroPayAmount();
    error BadArbRewardBps();
    error BadCollateralBps();
    error NativePayDisabled();
    error PayTokenNotAllowed();
    error UnsupportedPayAsset();
    error ZeroTargetAmount();
    error NativeCollateralDisabled();
    error CollateralNotAllowed();
    error OffchainCollateralTooLow();
    error OffchainPenaltyTooLow();
    error OffchainCollateralMismatch();
    error FeeManagerNotSet();
    error EscrowManagerNotSet();
    error EscrowAlreadySet();
    error UseResolveCase();
    error BatchTooLarge();

    // arbitration adapter - config
    error CountZero();
    error BadDuration();
    error BadWindow();
    error BadBps();
    error BadPlatformBps();
    error ZeroPlatformRecipient();

    // arbitration adapter - case flow
    error EmptyOrderId();
    error CaseExists();
    error BadPrimaryFee();
    error NoCase();
    error Resolved();
    error BadVote();
    error AlreadyVoted();
    error NotDue();
    error CannotAppeal();
    error AppealExpired();
    error FinalRequested();
    error BadFinalFee();
    error EmptyEvidence();
    error EvidenceNotActive();
    error EvidenceWindowClosed();
    error FinalFeePaid();
    error CannotFund();
    error UseVoteOrFinalize();
    error AppealPending();
    error NoExperts();
    error NotEnoughJurors();
    error BadRound();

    // fee manager - config
    error FeeTooHigh();
    error GovFeeTooHigh();
    error BadScoreTiers();
    error BadScoreDiscounts();
    error BadBalanceTiers();
    error BadBalanceDiscounts();
    error BadMaxDiscount();
    error EmptyCaseId();
    error OrderIndexOOB();
    error CaseIndexOOB();
}
