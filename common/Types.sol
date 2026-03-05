// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice Asset type enum covering on-chain and off-chain mappings.
enum AssetType {
    Native, // Native coin
    ERC20, // ERC20 token
    ERC721, // ERC721 NFT
    ERC1155, // ERC1155 NFT
    ExternalProof // Off-chain asset/proof placeholder, not transferred on-chain
}

/// @notice Order state machine definition.
enum OrderState {
    None, // Default placeholder
    Initialized, // Created (not funded and not asset-locked)
    Funded, // Buyer funded
    AssetLocked, // Seller locked target/collateral asset
    AwaitDelivery, // Reserved placeholder (currently unused)
    Delivered, // Seller marked delivered
    Completed, // Completed normally (auto or buyer confirmation)
    Cancelled, // Canceled (refund directly if undelivered)
    Expired, // Timed out (auto-complete or cancel by state)
    Disputed, // In dispute (arbitration flow)
    Resolved // Arbitration resolved
}

/// @notice Arbitration case state machine (primary/final/expert tiebreak).
enum CaseState {
    None, // Not created
    Primary, // Primary round in progress
    PrimaryResolved, // Primary finished, waiting for appeal
    AppealPending, // Appeal requested, awaiting fee payment/selection
    Final, // Final round in progress
    FinalResolved, // Final resolved (terminal if no more appeal)
    Expert, // Expert tie-break round
    ExpertResolved // Expert tie-break resolved
}

/// @notice Arbitration case query filter type (for status filtering).
enum CaseQueryFilter {
    All, // No filter
    InProgress, // In progress (votable)
    Expired, // Timed out but not closed
    Completed // Closed or primary already resolved
}

/// @notice Arbitration vote enum.
enum Vote {
    None, // Not voted
    Buyer, // Vote for buyer
    Seller // Vote for seller
}

/// @notice User stats event action types.
enum StatsAction {
    None, // Placeholder
    Create, // Create
    Complete, // Complete
    Cancel, // Cancel/expire
    Dispute, // Initiate dispute
    ResolveWin, // Win arbitration
    ResolveLose // Lose arbitration
}

/// @notice User stats: counters and sets.
struct Stats {
    uint64 created; // Number of created escrow orders
    uint64 completed; // Number of completed escrow orders
    uint64 cancelled; // Number of canceled escrow orders
    uint64 disputesRaised; // Number of disputes initiated
    uint64 disputesWon; // Number of disputes won
    uint64 disputesLost; // Number of disputes lost
}

/// @notice Escrow record.
struct OrderRecord {
    bytes32 orderId;
    uint8 role; // 1=buyer, 2=seller
}

/// @notice Arbitration record.
struct CaseRecord {
    bytes32 caseId;
    bytes32 orderId;
    uint8 role; // 1=initiator, 2=party
}

/// @notice Arbitration evidence: submitter, CID, and timestamp.
struct Evidence {
    address submitter;
    bytes cid;
    uint64 timestamp;
}

/// @notice Single vote record: voter, vote option, and timestamp.
struct VoteRecord {
    address juror; // Voter
    Vote vote; // Vote option
    uint64 timestamp; // Vote timestamp
}

/// @notice Juror-case index record (for querying by juror address).
struct JurorCaseRef {
    bytes32 caseId; // Case ID
    uint8 round; // Assigned round: 1=Primary, 2=Final
    uint64 assignedAt; // Assignment timestamp
}

/// @notice Arbitration case summary (for batch query/list display).
struct CaseSummary {
    bytes32 caseId; // Case ID
    address escrow; // Related escrow contract
    bytes32 orderId; // Order ID
    uint8 state; // Case state (CaseState)
    uint8 round; // Current round: 1/2/3
    uint64 deadline; // Voting deadline
    uint64 evidenceDeadline; // Evidence deadline
    uint64 appealDeadline; // Appeal deadline
    bool resolved; // Whether closed
    address winner; // Winner address
    address requester; // Case requester
    address finalFeePayer; // Final-round fee payer
    uint256 yesCount; // Buyer votes
    uint256 noCount; // Seller votes
    address feeToken; // Fee asset
    uint256 feePrimary; // Primary fee balance
    uint256 feeFinal; // Final fee balance
}

/// @notice Arbitration case data structure including jurors, rounds, votes, and evidence.
struct Case {
    address escrow; // Related escrow contract
    bytes32 orderId; // Order ID
    bool resolved; // Whether closed
    uint8 round; // Current round: 1/2
    address winner; // Winner
    Evidence[] evidences; // Evidence list
    address[] jurors; // Jurors in current round
    mapping(address => Vote) votes; // Vote results
    uint256 yesCount; // Buyer votes
    uint256 noCount; // Seller votes
    uint64 deadline; // Voting deadline
    uint64 evidenceDeadline; // Evidence deadline
    CaseState state; // Case state machine
    uint64 appealDeadline; // Appeal deadline
    bool finalRequested; // Whether final round requested
    bool finalFeePaid; // Final-round fee paid
    address feeToken; // Fee asset
    uint256 feePrimary; // Primary fee balance
    uint256 feeFinal; // Final fee balance
    address requester; // Case requester
    address finalFeePayer; // Final-round fee payer
    bytes context; // Business context
    uint16 platformBps; // Platform share for this case appeal fee (bps)
    address platformRecipient; // Platform recipient for this case appeal fee
    address[] primaryJurors; // Primary juror list (historical)
    address[] finalJurors; // Final juror list (historical)
    address[] expertJurors; // Expert juror list (actual voters)
    VoteRecord[] primaryVotes; // Primary round vote records
    VoteRecord[] finalVotes; // Final round vote records
    VoteRecord[] expertVotes; // Expert round vote records
}

/// @notice Generic asset descriptor.
struct Asset {
    AssetType assetType;
    address token;
    uint256 id;
    uint256 amount;
}

/// @notice Core order data structure.
struct EscrowOrder {
    address buyer; // Buyer
    address seller; // Seller
    address arbitrator; // Arbitration adapter
    Asset paymentAsset; // Payment asset (native/ERC20)
    Asset targetAsset; // Target asset (ERC20/721/1155/external)
    Asset collateral; // Seller collateral (ERC20 only; must be >0 for off-chain target)
    uint256 price; // Price (must equal paymentAsset.amount)
    uint256 deadline; // Deadline
    uint256 feeBps; // Protocol fee rate (injected by factory)
    bytes32 metadataHash; // Metadata hash (description/terms CID)
    uint16 arbRewardBps; // Arbitration reward rate (deducted from payment asset to arbitrator)
    uint16 collateralPenaltyBps; // Seller default collateral payout ratio (bps, default 10000=100%)
    OrderState state; // Current state
}

/// @notice Create-order request struct (without arbitrator; contract reads and writes from Registry).
struct EscrowOrderReq {
    address buyer; // Buyer
    address seller; // Seller
    Asset paymentAsset; // Payment asset (native/ERC20)
    Asset targetAsset; // Target asset (ERC20/721/1155/external)
    Asset collateral; // Seller collateral (ERC20 only; must be >0 for off-chain target)
    uint256 price; // Price (must equal paymentAsset.amount)
    uint256 deadline; // Deadline
    bytes32 metadataHash; // Metadata hash (description/terms CID)
}
