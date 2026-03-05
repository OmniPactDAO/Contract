// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {
    EscrowOrder,
    EscrowOrderReq,
    OrderState,
    AssetType,
    Asset
} from "../common/Types.sol";
import {OmniErrors} from "../common/OmniErrors.sol";
import {IArbitrable} from "../interfaces/IArbitrable.sol";
import {IArbitrationAdapter} from "../interfaces/IArbitrationAdapter.sol";
import {IRegistry} from "../interfaces/IRegistry.sol";
import {IFeeManager} from "../interfaces/IFeeManager.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {IEscrowManager} from "../interfaces/IEscrowManager.sol";
import {EscrowVault} from "./EscrowVault.sol";
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

/// @title EscrowManager
contract EscrowManager is
    Initializable,
    IEscrowManager,
    IArbitrable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    /// @notice Order data (including state and escrow flag).
    struct OrderData {
        EscrowOrder order; // Order snapshot (buyer, seller, asset, price, deadline, etc.)
        bool fundEscrowed; // Whether buyer's funds have been escrowed (into the vault)
        bool assetEscrowed; // Whether seller's target asset has been escrowed (into the vault/recorded)
        bool collateralEscrowed; // Whether seller's deposit has been escrowed (into the vault)
        bytes32 disputeCaseId; // Arbitration case ID (returned by the adapter after dispute initiation)
        address feeRecipient; // Protocol fee recipient address (snapped when buyer pays)
    }

    /// @notice Registry address (used to read FeeManager and other configs).
    address public registry;
    /// @notice Fund/Asset escrow vault (only callable by EscrowManager).
    EscrowVault public vault;
    /// @notice User stats contract address, can be zero to disable.
    address public userStats;
    /// @notice Number of orders created (used to generate orderId).
    uint256 public totalOrders;
    /// @notice Arbitration adapter whitelist.
    mapping(address => bool) public arbitratorWhitelist;
    /// @notice Minimum collateral ratio for off-chain assets (ExternalProof), default 100%, based on price.
    uint16 public minOffchainCollateralBps;
    /// @notice Minimum penalty ratio for off-chain assets (default 100%, full penalty).
    uint16 public minOffchainPenaltyBps;

    /// @notice Order data storage: orderId -> OrderData.
    mapping(bytes32 => OrderData) private orders;

    /// @notice Storage for all order ID list.
    bytes32[] private _allOrderIds;

    /// @notice Maximum fee rate limit (basis points, bps): 5000 = 50%, used to prevent misconfiguration leading to excessive rates.
    uint16 public constant MAX_FEE_BPS = 5000;
    /// @notice Basis point denominator: 10000 bps = 100%.
    uint16 public constant BPS_DENOM = 10_000;

    /// @dev Registry key: feeManager (unified fee and whitelist config source).
    bytes32 private constant _FEE_MANAGER_KEY = bytes32("feeManager");

    // Event definitions are provided by IEscrowEvents.

    modifier onlyBuyer(bytes32 orderId) {
        OrderData storage data = _requireOrder(orderId);
        if (msg.sender != data.order.buyer) revert OmniErrors.NotBuyer();
        _;
    }

    modifier onlySeller(bytes32 orderId) {
        OrderData storage data = _requireOrder(orderId);
        if (msg.sender != data.order.seller) revert OmniErrors.NotSeller();
        _;
    }

    modifier onlyArbitrator(bytes32 orderId) {
        OrderData storage data = _requireOrder(orderId);
        if (msg.sender != data.order.arbitrator && msg.sender != owner())
            revert OmniErrors.NotArbitrator();
        _;
    }

    /// @notice Initialize the contract (single contract manages multiple orders).
    /// @param admin Contract admin.
    /// @param registry_ Registry address.
    /// @param userStats_ User stats contract address.
    /// @param vault_ Fund vault address.
    function initialize(
        address admin,
        address registry_,
        address,
        address userStats_,
        address vault_
    ) external initializer {
        if (admin == address(0)) revert OmniErrors.ZeroAdmin();
        if (registry_ == address(0)) revert OmniErrors.ZeroRegistry();
        if (vault_ == address(0)) revert OmniErrors.ZeroVault();
        __Ownable_init(admin);
        __Pausable_init();
        __ReentrancyGuard_init();
        registry = registry_;
        userStats = userStats_;
        vault = EscrowVault(vault_);
        minOffchainCollateralBps = BPS_DENOM;
        minOffchainPenaltyBps = BPS_DENOM;
    }

    /// @notice Pause the contract (only owner).
    /// @dev Enter paused state; only owner can call.
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /// @notice Unpause the contract (only owner).
    /// @dev Exit paused state; only owner can call.
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /// @notice Set Registry address (used to read FeeManager).
    /// @param registry_ Registry contract address.
    /// @dev Only owner can call.
    function setRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert OmniErrors.ZeroRegistry();
        registry = registry_;
    }

    /// @notice Set user stats contract address, 0 means disable user data recording.
    /// @param stats User stats contract address.
    /// @dev Only owner can call.
    function setUserStats(address stats) external onlyOwner {
        userStats = stats;
    }

    /// @notice Set arbitration adapter whitelist.
    /// @param arbitrator Arbitration adapter address.
    /// @param allowed Whether to allow.
    /// @dev Only owner can call.
    function setArbitrator(
        address arbitrator,
        bool allowed
    ) external onlyOwner {
        arbitratorWhitelist[arbitrator] = allowed;
    }

    /// @notice Set minimum collateral ratio and minimum penalty ratio for off-chain assets.
    function setOffchainCollateralRule(
        uint16 minCollateralBps,
        uint16 minPenaltyBps
    ) external onlyOwner {
        if (minCollateralBps > BPS_DENOM || minPenaltyBps > BPS_DENOM)
            revert OmniErrors.BadOffchainRule();
        minOffchainCollateralBps = minCollateralBps;
        minOffchainPenaltyBps = minPenaltyBps;
    }

    /// @notice Create a new escrow order (single contract management).
    /// @param order Order data (buyer, seller, asset, deadline, etc.).
    /// @return orderId Generated order ID.
    /// @dev Validate whitelist and rules, charge creation fee, write to storage and emit event.
    function createEscrow(
        EscrowOrderReq calldata order
    )
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (bytes32 orderId)
    {
        IFeeManager fm = _getFeeManager();
        uint16 arbRewardBps = fm.arbRewardBps();
        uint16 collateralPenaltyBps = fm.collateralPenaltyBps();
        if (arbRewardBps > BPS_DENOM) revert OmniErrors.BadArbRewardBps();
        if (collateralPenaltyBps > BPS_DENOM)
            revert OmniErrors.BadCollateralBps();
        _validateOrder(order, collateralPenaltyBps);
        if (msg.sender != order.buyer && msg.sender != order.seller)
            revert OmniErrors.NotParticipant();
        address arbitrator = _resolveArbitrator();
        (uint256 createFee, address createRecipient) = _getCreateFeeConfig();
        if (createFee > 0) {
            if (msg.value != createFee) revert OmniErrors.BadCreateFee();
            (bool ok, ) = createRecipient.call{value: createFee}("");
            if (!ok) revert OmniErrors.CreateFeeTransferFailed();
        } else {
            if (msg.value != 0) revert OmniErrors.UnexpectedValue();
        }

        orderId = keccak256(
            abi.encodePacked(
                address(this),
                msg.sender,
                totalOrders,
                block.chainid
            )
        );
        if (orders[orderId].order.state != OrderState.None)
            revert OmniErrors.OrderExists();

        OrderData storage data = orders[orderId];
        data.order = EscrowOrder({
            buyer: order.buyer,
            seller: order.seller,
            arbitrator: arbitrator,
            paymentAsset: order.paymentAsset,
            targetAsset: order.targetAsset,
            collateral: order.collateral,
            price: order.price,
            deadline: order.deadline,
            feeBps: 0,
            metadataHash: order.metadataHash,
            arbRewardBps: arbRewardBps,
            collateralPenaltyBps: collateralPenaltyBps,
            state: OrderState.Initialized
        });

        _allOrderIds.push(orderId);
        totalOrders += 1;
        emit OrderCreated(
            orderId,
            order.buyer,
            order.seller,
            arbitrator,
            order.paymentAsset,
            order.targetAsset,
            order.collateral,
            order.price,
            order.deadline,
            0,
            order.metadataHash,
            arbRewardBps,
            collateralPenaltyBps,
            OrderState.Initialized,
            uint64(block.timestamp)
        );

        if (userStats != address(0)) {
            UserStatsLikeV2(userStats).updateOnCreate(
                order.buyer,
                order.seller,
                orderId
            );
        }
    }

    /// @notice Buyer locks payment funds into escrow contract.
    /// @param orderId Order ID.
    /// @dev Snapshot discount first, then execute escrow; state becomes Funded/AssetLocked.
    function markFunded(
        bytes32 orderId
    ) external payable whenNotPaused onlyBuyer(orderId) nonReentrant {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (data.fundEscrowed) revert OmniErrors.AlreadyFunded();
        if (
            order.state != OrderState.Initialized &&
            order.state != OrderState.AssetLocked
        ) revert OmniErrors.BadState();
        if (block.timestamp >= order.deadline) revert OmniErrors.BadDeadline();
        if (order.targetAsset.assetType != AssetType.ExternalProof) {
            if (!data.assetEscrowed) revert OmniErrors.AssetRequired();
        }
        if (
            order.targetAsset.assetType == AssetType.ExternalProof &&
            order.collateral.amount > 0
        ) {
            if (!data.collateralEscrowed)
                revert OmniErrors.CollateralRequired();
        }
        _snapshotProtocolFeeOnFund(data);
        _escrowPayment(order);
        if (data.assetEscrowed) {
            order.state = OrderState.AssetLocked;
        } else {
            order.state = OrderState.Funded;
        }
        data.fundEscrowed = true;
        emit OrderFunded(
            orderId,
            msg.sender,
            order.price,
            uint64(block.timestamp)
        );
        _autoDeliverIfOnchainReady(orderId, data);
    }

    /// @notice Seller locks target asset into escrow contract.
    /// @param orderId Order ID.
    /// @dev Success changes state to AssetLocked and may trigger auto-delivery.
    function lockAsset(
        bytes32 orderId
    ) external whenNotPaused onlySeller(orderId) nonReentrant {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (
            order.state != OrderState.Initialized &&
            order.state != OrderState.Funded
        ) revert OmniErrors.BadState();
        if (data.assetEscrowed) revert OmniErrors.AssetLocked();
        _escrowTargetAsset(order);
        order.state = OrderState.AssetLocked;
        data.assetEscrowed = true;
        emit AssetLocked(orderId, msg.sender, uint64(block.timestamp));
        _autoDeliverIfOnchainReady(orderId, data);
    }

    /// @notice Seller locks deposit (supports native or ERC20).
    /// @param orderId Order ID.
    /// @dev Success emits CollateralLocked event and may trigger auto-delivery.
    function lockCollateral(
        bytes32 orderId
    ) external payable whenNotPaused onlySeller(orderId) nonReentrant {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (order.collateral.amount == 0) revert OmniErrors.NoCollateral();
        if (data.collateralEscrowed) revert OmniErrors.CollateralLocked();
        _escrowCollateral(order);
        data.collateralEscrowed = true;
        emit CollateralLocked(
            orderId,
            msg.sender,
            order.collateral.amount,
            order.collateral.token,
            uint64(block.timestamp)
        );
        _autoDeliverIfOnchainReady(orderId, data);
    }

    /// @notice Seller one-click lock deposit and target (if any), reducing multiple interactions.
    /// @param orderId Order ID.
    /// @dev Locks deposit and target respectively if needed, and emits events.
    function lockSellerAssets(
        bytes32 orderId
    ) external payable whenNotPaused onlySeller(orderId) nonReentrant {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (order.collateral.amount > 0 && !data.collateralEscrowed) {
            _escrowCollateral(order);
            data.collateralEscrowed = true;
            emit CollateralLocked(
                orderId,
                msg.sender,
                order.collateral.amount,
                order.collateral.token,
                uint64(block.timestamp)
            );
        }
        if (!data.assetEscrowed) {
            if (order.targetAsset.assetType == AssetType.ExternalProof) {
                data.assetEscrowed = true;
            } else {
                if (
                    order.state != OrderState.Initialized &&
                    order.state != OrderState.Funded
                ) revert OmniErrors.BadState();
                _escrowTargetAsset(order);
                data.assetEscrowed = true;
            }
            order.state = OrderState.AssetLocked;
            emit AssetLocked(orderId, msg.sender, uint64(block.timestamp));
        }
        _autoDeliverIfOnchainReady(orderId, data);
    }

    /// @notice Seller marks as delivered (off-chain delivery still requires buyer confirmation).
    /// @param orderId Order ID.
    /// @dev Success changes state to Delivered.
    function markDelivered(
        bytes32 orderId
    ) external whenNotPaused onlySeller(orderId) {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (!data.fundEscrowed) revert OmniErrors.BuyerNotFunded();
        if (
            order.state != OrderState.AssetLocked &&
            order.targetAsset.assetType != AssetType.ExternalProof
        ) revert OmniErrors.BadState();
        if (
            order.targetAsset.assetType == AssetType.ExternalProof &&
            order.collateral.amount > 0
        ) {
            if (!data.collateralEscrowed)
                revert OmniErrors.CollateralRequired();
        }
        order.state = OrderState.Delivered;
        emit Delivered(orderId, msg.sender, uint64(block.timestamp));
    }

    /// @notice Buyer confirms receipt/performance and executes settlement.
    /// @param orderId Order ID.
    /// @dev Success changes state to Completed and executes settlement and score/stats update.
    function confirmCompletion(
        bytes32 orderId
    ) external whenNotPaused onlyBuyer(orderId) nonReentrant {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (!data.fundEscrowed) revert OmniErrors.BuyerNotFunded();
        if (
            order.state != OrderState.Delivered &&
            !(order.targetAsset.assetType == AssetType.ExternalProof &&
                (order.state == OrderState.Funded ||
                    order.state == OrderState.AssetLocked))
        ) {
            revert OmniErrors.BadState();
        }
        if (order.targetAsset.assetType != AssetType.ExternalProof) {
            if (!data.assetEscrowed) revert OmniErrors.AssetNotLocked();
        }
        if (
            order.targetAsset.assetType == AssetType.ExternalProof &&
            order.collateral.amount > 0
        ) {
            if (!data.collateralEscrowed)
                revert OmniErrors.CollateralRequired();
        }
        order.state = OrderState.Completed;
        _payoutOnSuccess(orderId, data, false);
        _updateStatsOnComplete(order, orderId);
        emit Completed(
            orderId,
            order.buyer,
            order.seller,
            uint64(block.timestamp)
        );
    }

    /// @notice Cancel order before performance, refund funds and return target.
    /// @param orderId Order ID.
    /// @dev Success changes state to Cancelled, executes refund and return.
    function cancel(bytes32 orderId) external whenNotPaused nonReentrant {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (msg.sender != order.buyer && msg.sender != order.seller)
            revert OmniErrors.NotParticipant();
        if (
            order.state != OrderState.Initialized &&
            order.state != OrderState.Funded &&
            order.state != OrderState.AssetLocked
        ) {
            revert OmniErrors.CannotCancel();
        }
        order.state = OrderState.Cancelled;
        _refundBuyer(data);
        _returnAssetToSeller(data);
        _returnCollateralToSeller(orderId, data);
        _updateStatsOnCancelOrExpire(order, orderId);
        emit Cancelled(orderId, msg.sender, uint64(block.timestamp));
    }

    /// @notice Timeout handling, auto cancel or complete if performance not done.
    /// @param orderId Order ID.
    /// @dev If delivered and paid, auto complete; otherwise treat as cancel.
    function expire(bytes32 orderId) external whenNotPaused nonReentrant {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (block.timestamp < order.deadline) revert OmniErrors.NotExpired();
        if (
            order.state == OrderState.Completed ||
            order.state == OrderState.Resolved
        ) revert OmniErrors.Finalized();

        if (order.state == OrderState.Delivered && data.fundEscrowed) {
            order.state = OrderState.Completed;
            _payoutOnSuccess(orderId, data, false);
            _updateStatsOnComplete(order, orderId);
            emit Completed(
                orderId,
                order.buyer,
                order.seller,
                uint64(block.timestamp)
            );
        } else {
            if (
                order.state != OrderState.Initialized &&
                order.state != OrderState.Funded &&
                order.state != OrderState.AssetLocked
            ) {
                revert OmniErrors.BadState();
            }
            order.state = OrderState.Expired;
            _refundBuyer(data);
            _returnAssetToSeller(data);
            _returnCollateralToSeller(orderId, data);
            _updateStatsOnCancelOrExpire(order, orderId);
            emit Cancelled(orderId, msg.sender, uint64(block.timestamp));
        }
    }

    /// @notice Either party can initiate a dispute and enter arbitration process.
    /// @param orderId Order ID.
    /// @param evidence Evidence CID/raw data (off-chain storage).
    /// @dev Validate state and deposit requirements, enter arbitration, record caseId and event.
    function raiseDispute(
        bytes32 orderId,
        bytes calldata evidence
    ) external override whenNotPaused {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (msg.sender != order.buyer && msg.sender != order.seller)
            revert OmniErrors.NotParticipant();
        if (
            order.state != OrderState.Funded &&
            order.state != OrderState.AssetLocked &&
            order.state != OrderState.Delivered
        ) {
            revert OmniErrors.BadState();
        }
        if (
            order.targetAsset.assetType == AssetType.ExternalProof &&
            order.collateral.amount > 0
        ) {
            if (!data.collateralEscrowed)
                revert OmniErrors.CollateralRequired();
        }
        order.state = OrderState.Disputed;
        if (order.arbitrator != address(0)) {
            bytes memory context = abi.encode(
                order.buyer,
                order.seller,
                order.price,
                order.paymentAsset.token
            );
            bytes32 caseId = IArbitrationAdapter(order.arbitrator)
                .requestArbitration(orderId, msg.sender, evidence, context);
            data.disputeCaseId = caseId;
            emit ArbitrationRequested(
                orderId,
                caseId,
                order.arbitrator,
                uint64(block.timestamp)
            );
        }
        if (data.disputeCaseId != bytes32(0)) {
            _updateStatsOnDispute(orderId, data, msg.sender);
        }
        emit Disputed(
            orderId,
            msg.sender,
            order.arbitrator,
            uint64(block.timestamp)
        );
    }

    /// @notice Arbitrator rules the winner, default seller win is considered performance completed, buyer win is considered transaction cancelled.
    /// @param orderId Order ID.
    /// @param winner Winner address from arbitration result (buyer or seller).
    /// @dev Only arbitrator can call; finalize ruling and update state and rewards.
    function resolveDispute(
        bytes32 orderId,
        address winner
    ) external whenNotPaused onlyArbitrator(orderId) nonReentrant {
        _finalizeDispute(orderId, _requireOrder(orderId), winner);
    }

    /// @notice Arbitration decoupling callback.
    function onArbitrationResolved(
        bytes32 caseId,
        bytes32 orderId,
        address winner
    )
        external
        override(IEscrowManager, IArbitrable)
        whenNotPaused
        nonReentrant
    {
        OrderData storage data = _requireOrder(orderId);
        if (msg.sender != data.order.arbitrator)
            revert OmniErrors.NotArbitrator();
        data.disputeCaseId = caseId;
        _finalizeDispute(orderId, data, winner);
    }

    /// @notice Query order details.
    /// @param orderId Order ID.
    /// @return Order details struct.
    function getOrder(
        bytes32 orderId
    ) external view returns (EscrowOrder memory) {
        OrderData storage data = _requireOrder(orderId);
        return data.order;
    }

    /// @notice Get business order value information (used to calculate appeal fee).
    /// @param orderId Business-side identifier (e.g., Order ID).
    /// @return amount Order amount.
    /// @return token Order asset address (native token is address(0)).
    /// @return assetType Asset type.
    /// @return partyA Party A (usually buyer/initiator).
    /// @return partyB Party B (usually seller/responder).
    function getArbitrationValue(
        bytes32 orderId
    )
        external
        view
        override
        returns (
            uint256 amount,
            address token,
            AssetType assetType,
            address partyA,
            address partyB
        )
    {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        amount = order.paymentAsset.amount;
        token = order.paymentAsset.token;
        assetType = order.paymentAsset.assetType;
        partyA = order.buyer;
        partyB = order.seller;
    }

    /// @notice Batch query order details (only for off-chain reading).
    /// @param orderIds List of order IDs.
    /// @return orderList Corresponding list of order data (one-to-one with orderIds).
    function getOrders(
        bytes32[] calldata orderIds
    ) external view override returns (EscrowOrder[] memory orderList) {
        uint256 len = orderIds.length;
        if (len > 50) revert OmniErrors.BatchTooLarge();
        orderList = new EscrowOrder[](len);
        for (uint256 i = 0; i < len; i++) {
            OrderData storage data = _requireOrder(orderIds[i]);
            orderList[i] = data.order;
        }
    }

    /// @notice Query whether buyer's funds are locked.
    /// @param orderId Order ID.
    /// @return Whether locked.
    function isFunded(bytes32 orderId) external view returns (bool) {
        OrderData storage data = _requireOrder(orderId);
        return data.fundEscrowed;
    }

    /// @notice Query whether seller's target asset is locked.
    /// @param orderId Order ID.
    /// @return Whether locked.
    function isAssetLocked(bytes32 orderId) external view returns (bool) {
        OrderData storage data = _requireOrder(orderId);
        return data.assetEscrowed;
    }

    /// @notice Query whether seller's deposit is locked.
    /// @param orderId Order ID.
    /// @return Whether locked.
    function isCollateralLocked(bytes32 orderId) external view returns (bool) {
        OrderData storage data = _requireOrder(orderId);
        return data.collateralEscrowed;
    }

    /// @notice Return arbitration context (buyer/seller/price/payment asset address).
    /// @param orderId Order ID.
    /// @return Encoded arbitration context.
    function getContext(bytes32 orderId) external view returns (bytes memory) {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        return
            abi.encode(
                order.buyer,
                order.seller,
                order.price,
                order.paymentAsset.token
            );
    }

    /// @notice Query arbitration caseId corresponding to the order.
    /// @param orderId Order ID.
    /// @return Arbitration case ID.
    function getDisputeCaseId(bytes32 orderId) external view returns (bytes32) {
        OrderData storage data = _requireOrder(orderId);
        return data.disputeCaseId;
    }

    /// @notice Query protocol fee configuration for order snapshot.
    /// @param orderId Order ID.
    /// @return recipient Protocol fee recipient address.
    /// @return feeBps Fee rate after dynamic discount (bps).
    function getFeeSnapshot(
        bytes32 orderId
    ) external view returns (address recipient, uint16 feeBps) {
        OrderData storage data = _requireOrder(orderId);
        return (data.feeRecipient, uint16(data.order.feeBps));
    }

    /// @notice Update order metadata (title/description/image, etc.), only seller can update before buyer pays.
    /// @param orderId Order ID.
    /// @param metadataCid Off-chain metadata CID/locator.
    function updateMetadata(
        bytes32 orderId,
        bytes calldata metadataCid
    ) external whenNotPaused onlySeller(orderId) {
        OrderData storage data = _requireOrder(orderId);
        EscrowOrder storage order = data.order;
        if (data.fundEscrowed) revert OmniErrors.AlreadyFunded();
        if (
            order.state != OrderState.Initialized &&
            order.state != OrderState.AssetLocked
        ) revert OmniErrors.BadState();
        if (metadataCid.length == 0) revert OmniErrors.EmptyCid();
        bytes32 h = keccak256(metadataCid);
        order.metadataHash = h;
        emit MetadataUpdated(
            orderId,
            msg.sender,
            metadataCid,
            h,
            uint64(block.timestamp)
        );
    }

    /// @dev Read and verify order existence.
    /// @param orderId Order ID.
    /// @return data Order data reference (storage).
    function _requireOrder(
        bytes32 orderId
    ) internal view returns (OrderData storage data) {
        data = orders[orderId];
        if (data.order.state == OrderState.None)
            revert OmniErrors.UnknownOrder();
    }

    /// @dev Auto advance to Delivered when on-chain target is ready, reducing one interaction for seller.
    /// Conditions:
    /// - Not ExternalProof;
    /// - Buyer paid;
    /// - Seller locked target;
    /// - If collateral configured, collateral locked;
    /// - Currently in AssetLocked.
    /// @param orderId Order ID.
    /// @param data Order data.
    function _autoDeliverIfOnchainReady(
        bytes32 orderId,
        OrderData storage data
    ) internal {
        EscrowOrder storage order = data.order;
        if (order.targetAsset.assetType == AssetType.ExternalProof) return;
        if (!data.fundEscrowed || !data.assetEscrowed) return;
        if (order.collateral.amount > 0 && !data.collateralEscrowed) return;
        if (order.state != OrderState.AssetLocked) return;

        order.state = OrderState.Delivered;
        emit Delivered(orderId, order.seller, uint64(block.timestamp));
    }

    /// @dev Unified exit for arbitration result: update state, distribute assets and scores/stats.
    /// @param orderId Order ID.
    /// @param data Order data.
    /// @param winner Winner address (buyer or seller).
    function _finalizeDispute(
        bytes32 orderId,
        OrderData storage data,
        address winner
    ) internal {
        EscrowOrder storage order = data.order;
        if (order.state != OrderState.Disputed) revert OmniErrors.NotDisputed();
        if (winner != order.buyer && winner != order.seller)
            revert OmniErrors.InvalidWinner();
        order.state = OrderState.Resolved;
        address loser = winner == order.buyer ? order.seller : order.buyer;
        if (winner == order.seller) {
            _payoutOnSuccess(orderId, data, true);
        } else {
            _payoutFunds(data, order.buyer, true);
            _returnAssetToSeller(data);
            _payoutCollateralToBuyer(orderId, data);
        }
        _updateStatsOnResolve(orderId, data, winner, loser);
        emit Resolved(
            orderId,
            winner,
            order.arbitrator,
            uint64(block.timestamp)
        );
    }

    /// @dev Execute escrow of payment asset (native or ERC20), enter vault.
    /// @param order Order struct (read payment asset info).
    function _escrowPayment(EscrowOrder storage order) internal {
        if (order.paymentAsset.assetType == AssetType.Native) {
            if (msg.value != order.paymentAsset.amount)
                revert OmniErrors.BadMsgValue();
            vault.depositNative{value: order.paymentAsset.amount}();
        } else if (order.paymentAsset.assetType == AssetType.ERC20) {
            if (msg.value != 0) revert OmniErrors.UnexpectedValue();
            vault.pullERC20(
                msg.sender,
                order.paymentAsset.token,
                order.paymentAsset.amount
            );
        } else {
            revert OmniErrors.UnsupportedPayment();
        }
    }

    /// @dev Escrow target asset (ERC20/ERC721/ERC1155), off-chain proof is not transferred.
    /// @param order Order struct (read target asset info).
    function _escrowTargetAsset(EscrowOrder storage order) internal {
        if (order.targetAsset.assetType == AssetType.ERC20) {
            vault.pullERC20(
                msg.sender,
                order.targetAsset.token,
                order.targetAsset.amount
            );
        } else if (order.targetAsset.assetType == AssetType.ERC721) {
            vault.pullERC721(
                msg.sender,
                order.targetAsset.token,
                order.targetAsset.id
            );
        } else if (order.targetAsset.assetType == AssetType.ERC1155) {
            vault.pullERC1155(
                msg.sender,
                order.targetAsset.token,
                order.targetAsset.id,
                order.targetAsset.amount
            );
        } else if (order.targetAsset.assetType == AssetType.ExternalProof) {
            return;
        } else {
            revert OmniErrors.UnsupportedTarget();
        }
    }

    /// @dev Normal transaction distribution: funds to seller, target to buyer, and return deposit.
    /// @param orderId Order ID.
    /// @param data Order data.
    /// @param withArbReward Whether to distribute arbitration reward (when arbitrator wins).
    function _payoutOnSuccess(
        bytes32 orderId,
        OrderData storage data,
        bool withArbReward
    ) internal {
        EscrowOrder storage order = data.order;
        _payoutFunds(data, order.seller, withArbReward);

        if (data.assetEscrowed) {
            _releaseAssetToBuyer(order, data);
            data.assetEscrowed = false;
        }
        _returnCollateralToSeller(orderId, data);
    }

    /// @dev Refund buyer (if funds are escrowed).
    /// @param data Order data.
    function _refundBuyer(OrderData storage data) internal {
        if (!data.fundEscrowed) return;
        EscrowOrder storage order = data.order;
        if (order.paymentAsset.assetType == AssetType.Native) {
            vault.pushNative(order.buyer, order.paymentAsset.amount);
        } else if (order.paymentAsset.assetType == AssetType.ERC20) {
            vault.pushERC20(
                order.buyer,
                order.paymentAsset.token,
                order.paymentAsset.amount
            );
        }
        data.fundEscrowed = false;
    }

    /// @dev Return target to seller (if escrowed).
    /// @param data Order data.
    function _returnAssetToSeller(OrderData storage data) internal {
        if (!data.assetEscrowed) return;
        EscrowOrder storage order = data.order;
        if (order.targetAsset.assetType == AssetType.ERC20) {
            vault.pushERC20(
                order.seller,
                order.targetAsset.token,
                order.targetAsset.amount
            );
        } else if (order.targetAsset.assetType == AssetType.ERC721) {
            vault.pushERC721(
                order.seller,
                order.targetAsset.token,
                order.targetAsset.id
            );
        } else if (order.targetAsset.assetType == AssetType.ERC1155) {
            vault.pushERC1155(
                order.seller,
                order.targetAsset.token,
                order.targetAsset.id,
                order.targetAsset.amount
            );
        }
        data.assetEscrowed = false;
    }

    /// @dev Escrow collateral asset (native or ERC20), enter vault.
    /// @param order Order struct (read collateral asset info).
    function _escrowCollateral(EscrowOrder storage order) internal {
        if (order.collateral.assetType == AssetType.Native) {
            if (msg.value != order.collateral.amount)
                revert OmniErrors.BadCollateralValue();
            vault.depositNative{value: order.collateral.amount}();
        } else if (order.collateral.assetType == AssetType.ERC20) {
            if (msg.value != 0) revert OmniErrors.UnexpectedValue();
            vault.pullERC20(
                msg.sender,
                order.collateral.token,
                order.collateral.amount
            );
        } else {
            revert OmniErrors.CollateralAssetNotAllowed();
        }
    }

    /// @dev Release target asset to buyer; off-chain proof only updates flag.
    /// @param order Order struct (read target asset info).
    /// @param data Order data.
    function _releaseAssetToBuyer(
        EscrowOrder storage order,
        OrderData storage data
    ) internal {
        if (order.targetAsset.assetType == AssetType.ERC20) {
            vault.pushERC20(
                order.buyer,
                order.targetAsset.token,
                order.targetAsset.amount
            );
        } else if (order.targetAsset.assetType == AssetType.ERC721) {
            vault.pushERC721(
                order.buyer,
                order.targetAsset.token,
                order.targetAsset.id
            );
        } else if (order.targetAsset.assetType == AssetType.ERC1155) {
            vault.pushERC1155(
                order.buyer,
                order.targetAsset.token,
                order.targetAsset.id,
                order.targetAsset.amount
            );
        } else if (order.targetAsset.assetType == AssetType.ExternalProof) {
            data.assetEscrowed = false;
        }
    }

    /// @dev Return deposit to seller (non-arbitration payout scenario).
    /// @param orderId Order ID.
    /// @param data Order data.
    function _returnCollateralToSeller(
        bytes32 orderId,
        OrderData storage data
    ) internal {
        if (!data.collateralEscrowed) return;
        EscrowOrder storage order = data.order;
        if (order.collateral.assetType == AssetType.Native) {
            vault.pushNative(order.seller, order.collateral.amount);
        } else {
            vault.pushERC20(
                order.seller,
                order.collateral.token,
                order.collateral.amount
            );
        }
        data.collateralEscrowed = false;
        emit CollateralReleased(
            orderId,
            order.seller,
            order.collateral.amount,
            order.collateral.token,
            uint64(block.timestamp)
        );
    }

    /// @dev Payout collateral to buyer according to penalty ratio, and return remainder to seller.
    /// @param orderId Order ID.
    /// @param data Order data.
    function _payoutCollateralToBuyer(
        bytes32 orderId,
        OrderData storage data
    ) internal {
        if (!data.collateralEscrowed) return;
        EscrowOrder storage order = data.order;

        IFeeManager fm = _getFeeManager();
        address fmAddr = address(fm);

        uint256 amount = order.collateral.amount;
        address token = order.collateral.token;

        if (order.collateral.assetType == AssetType.Native) {
            vault.pushNative(address(this), amount);
            IFeeDistributor(fmAddr).distributeCollateralPenalty{value: amount}(
                orderId,
                token,
                amount,
                order.collateralPenaltyBps,
                order.buyer,
                order.seller
            );
        } else {
            vault.pushERC20(fmAddr, token, amount);
            IFeeDistributor(fmAddr).distributeCollateralPenalty(
                orderId,
                token,
                amount,
                order.collateralPenaltyBps,
                order.buyer,
                order.seller
            );
        }

        data.collateralEscrowed = false;

        uint256 payout = (amount * order.collateralPenaltyBps) / BPS_DENOM;
        uint256 remainder = amount - payout;

        emit CollateralReleased(
            orderId,
            order.buyer,
            payout,
            token,
            uint64(block.timestamp)
        );
        if (remainder > 0) {
            emit CollateralReleased(
                orderId,
                order.seller,
                remainder,
                token,
                uint64(block.timestamp)
            );
        }
    }

    /// @dev Execute fund settlement and protocol fee/arbitration reward distribution.
    /// @param data Order data.
    /// @param payee Fund receiver.
    /// @param withArbReward Whether to distribute arbitration reward.
    function _payoutFunds(
        OrderData storage data,
        address payee,
        bool withArbReward
    ) internal {
        if (!data.fundEscrowed) return;
        EscrowOrder storage order = data.order;
        uint256 amount = order.paymentAsset.amount;
        uint16 appliedFee = uint16(order.feeBps);
        uint256 fee = (amount * appliedFee) / BPS_DENOM;
        if (amount < fee) revert OmniErrors.FeeExceedsAmount();
        if (fee > 0) {
            if (data.feeRecipient == address(0))
                revert OmniErrors.ZeroFeeRecipient();
        }

        uint256 remaining = amount - fee;
        uint256 arbReward = 0;
        if (withArbReward && order.arbRewardBps > 0) {
            arbReward = (remaining * order.arbRewardBps) / BPS_DENOM;
            remaining -= arbReward;
        }

        if (fee > 0) {
            if (order.paymentAsset.assetType == AssetType.Native) {
                vault.pushNative(data.feeRecipient, fee);
            } else {
                vault.pushERC20(
                    data.feeRecipient,
                    order.paymentAsset.token,
                    fee
                );
            }
        }

        if (arbReward > 0) {
            if (order.paymentAsset.assetType == AssetType.Native) {
                vault.pushNative(address(this), arbReward);
                IArbitrationAdapter(order.arbitrator).depositReward{
                    value: arbReward
                }(data.disputeCaseId);
            } else {
                vault.pushERC20(
                    order.arbitrator,
                    order.paymentAsset.token,
                    arbReward
                );
                IArbitrationAdapter(order.arbitrator).depositReward(
                    data.disputeCaseId
                );
            }
        }

        if (order.paymentAsset.assetType == AssetType.Native) {
            vault.pushNative(payee, remaining);
        } else {
            vault.pushERC20(payee, order.paymentAsset.token, remaining);
        }
        data.fundEscrowed = false;
    }

    /// @dev Snapshot protocol fee config before payment (dynamic discount by payer).
    /// @param data Order data.
    function _snapshotProtocolFeeOnFund(OrderData storage data) internal {
        IFeeManager fm = _getFeeManager();
        (address recipient, uint16 appliedBps, , , , ) = fm
            .previewProtocolFeeFor(
                msg.sender,
                data.order.paymentAsset.assetType,
                data.order.paymentAsset.token
            );

        data.order.feeBps = appliedBps;
        data.feeRecipient = recipient;
    }

    /// @dev Update user stats: Order completed.
    function _updateStatsOnComplete(
        EscrowOrder storage order,
        bytes32 orderId
    ) internal {
        if (userStats == address(0)) return;
        UserStatsLikeV2(userStats).updateOnComplete(
            order.buyer,
            order.seller,
            orderId
        );
    }

    /// @dev Update user stats: Order cancelled or expired.
    function _updateStatsOnCancelOrExpire(
        EscrowOrder storage order,
        bytes32 orderId
    ) internal {
        if (userStats == address(0)) return;
        UserStatsLikeV2(userStats).updateOnCancel(
            order.buyer,
            order.seller,
            orderId
        );
    }

    /// @dev Update user stats: Dispute initiated.
    function _updateStatsOnDispute(
        bytes32 orderId,
        OrderData storage data,
        address initiator
    ) internal {
        if (userStats == address(0)) return;
        UserStatsLikeV2(userStats).updateOnDispute(
            data.order.buyer,
            data.order.seller,
            initiator,
            orderId,
            data.disputeCaseId
        );
    }

    /// @dev Update user stats: Arbitration closed.
    function _updateStatsOnResolve(
        bytes32 orderId,
        OrderData storage data,
        address winner,
        address loser
    ) internal {
        if (userStats == address(0)) return;
        UserStatsLikeV2(userStats).updateOnResolve(
            winner,
            loser,
            orderId,
            data.disputeCaseId
        );
    }

    /// @dev Validate order creation parameters (roles, asset whitelist, collateral rules, etc.).
    /// @param order Order request parameters.
    /// @param collateralPenaltyBps Collateral penalty ratio (bps).
    function _validateOrder(
        EscrowOrderReq calldata order,
        uint16 collateralPenaltyBps
    ) internal view {
        if (order.buyer == address(0) || order.seller == address(0))
            revert OmniErrors.ZeroParty();
        if (order.buyer == order.seller) revert OmniErrors.SameParty();
        if (order.deadline <= block.timestamp) revert OmniErrors.BadDeadline();
        if (order.price == 0) revert OmniErrors.ZeroPrice();
        if (order.paymentAsset.amount == 0) revert OmniErrors.ZeroPayAmount();
        IFeeManager fm = _getFeeManager();
        if (order.paymentAsset.assetType == AssetType.Native) {
            bool allowed = fm.allowNativePayment();
            if (!allowed) revert OmniErrors.NativePayDisabled();
        } else if (order.paymentAsset.assetType == AssetType.ERC20) {
            if (order.paymentAsset.token == address(0))
                revert OmniErrors.ZeroPayToken();
            bool allowed = fm.paymentTokenWhitelist(order.paymentAsset.token);
            if (!allowed) revert OmniErrors.PayTokenNotAllowed();
        } else {
            revert OmniErrors.UnsupportedPayAsset();
        }
        if (order.targetAsset.assetType == AssetType.Native) {
            if (order.targetAsset.amount == 0)
                revert OmniErrors.ZeroTargetAmount();
        }
        if (order.collateral.amount > 0) {
            if (order.collateral.assetType == AssetType.Native) {
                bool allowed = fm.allowNativeCollateral();
                if (!allowed) revert OmniErrors.NativeCollateralDisabled();
            } else if (order.collateral.assetType == AssetType.ERC20) {
                if (order.collateral.token == address(0))
                    revert OmniErrors.ZeroCollateralToken();
                bool allowed = fm.collateralTokenWhitelist(
                    order.collateral.token
                );
                if (!allowed) revert OmniErrors.CollateralNotAllowed();
            } else {
                revert OmniErrors.CollateralAssetNotAllowed();
            }
        }
        if (order.targetAsset.assetType == AssetType.ExternalProof) {
            if (order.collateral.amount == 0)
                revert OmniErrors.CollateralRequired();
            // Off-chain asset scenario: collateral asset must be exactly the same as payment asset (type and token address)
            if (order.collateral.token != order.paymentAsset.token)
                revert OmniErrors.OffchainCollateralMismatch();

            uint256 minRequired = (uint256(order.price) *
                minOffchainCollateralBps) / BPS_DENOM;
            if (order.collateral.amount < minRequired)
                revert OmniErrors.OffchainCollateralTooLow();
            if (collateralPenaltyBps < minOffchainPenaltyBps)
                revert OmniErrors.OffchainPenaltyTooLow();
        }
    }

    /// @dev Resolve arbitration adapter, must be in whitelist and configured in Registry.
    /// @return arbitrator Arbitration adapter address.
    function _resolveArbitrator() internal view returns (address arbitrator) {
        arbitrator = IRegistry(registry).records(bytes32("arbitrationAdapter"));
        if (arbitrator == address(0)) revert OmniErrors.ZeroArbitrator();
        if (!arbitratorWhitelist[arbitrator])
            revert OmniErrors.ArbitratorNotAllowed();
    }

    /// @dev Get FeeManager reference (via Registry).
    /// @return FeeManager interface.
    function _getFeeManager() internal view returns (IFeeManager) {
        if (registry == address(0)) revert OmniErrors.ZeroRegistry();
        address fmAddr = IRegistry(registry).records(_FEE_MANAGER_KEY);
        if (fmAddr == address(0)) revert OmniErrors.FeeManagerNotSet();
        return IFeeManager(fmAddr);
    }

    /// @dev Get creation fee config (from FeeManager).
    /// @return fee Creation fee (wei).
    /// @return recipient Creation fee recipient.
    function _getCreateFeeConfig()
        internal
        view
        returns (uint256 fee, address recipient)
    {
        IFeeManager fm = _getFeeManager();
        fee = fm.createEscrowFee();
        recipient = fm.createFeeRecipient();
        if (fee > 0 && recipient == address(0))
            revert OmniErrors.ZeroCreateRecipient();
    }

    /// @notice Get order status.
    /// @param orderId Order ID.
    /// @return Current order status.
    function getOrderState(bytes32 orderId) external view returns (OrderState) {
        OrderData storage data = _requireOrder(orderId);
        return data.order.state;
    }

    /// @notice Get all order IDs (paginated).
    /// @param offset Start index (from 0).
    /// @param limit Max number of returns (0 means no return).
    /// @return orderIds List of order IDs.
    /// @return total Total number of orders.
    function getOrders(
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory orderIds, uint256 total) {
        total = totalOrders;
        if (offset >= total || limit == 0) {
            return (new bytes32[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        orderIds = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            orderIds[i - offset] = _allOrderIds[i];
        }
    }

    uint256[50] private __gap;

    receive() external payable {}
}

interface UserStatsLikeV2 {
    function updateOnCreate(
        address buyer,
        address seller,
        bytes32 orderId
    ) external;

    function updateOnComplete(
        address buyer,
        address seller,
        bytes32 orderId
    ) external;

    function updateOnCancel(
        address buyer,
        address seller,
        bytes32 orderId
    ) external;

    function updateOnDispute(
        address buyer,
        address seller,
        address initiator,
        bytes32 orderId,
        bytes32 caseId
    ) external;

    function updateOnResolve(
        address winner,
        address loser,
        bytes32 orderId,
        bytes32 caseId
    ) external;
}
