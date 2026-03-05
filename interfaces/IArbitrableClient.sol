// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {AssetType} from "../common/Types.sol";

/// @title IArbitrableClient
/// @notice Arbitration Client Interface. Any Escrow/Escrow contract wishing to integrate with ArbitrationAdapter must implement this interface.
/// @dev Through this interface, the arbitration system can generally retrieve case value and callback arbitration results.
interface IArbitrableClient {
    /// @notice Get case associated order value information (used to calculate appeal fee).
    /// @param orderId Order ID.
    /// @return amount Order amount.
    /// @return token Order asset address (native token is address(0)).
    /// @return assetType Asset type.
    function getArbitrationValue(
        bytes32 orderId
    ) external view returns (uint256 amount, address token, AssetType assetType);

    /// @notice Arbitration result callback.
    /// @param orderId Order ID.
    /// @param winner Winner address (ruled by arbitration system).
    function onArbitrationResolved(bytes32 orderId, address winner) external;
}
