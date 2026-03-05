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
import {IJurorManager} from "../interfaces/IJurorManager.sol";
import {OmniErrors} from "../common/OmniErrors.sol";

/// @title JurorManager
/// @notice Maintains juror pool and expert pool, and provides selection logic.
contract JurorManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    IJurorManager
{
    /// @notice Primary round juror whitelist.
    mapping(address => bool) public override isPrimaryJuror;
    /// @notice Final round juror whitelist.
    mapping(address => bool) public override isFinalJuror;
    /// @notice Expert ruling juror whitelist.
    mapping(address => bool) public override isExpertJuror;
    /// @notice Expert ruling whitelist count.
    uint256 public override expertCount;

    /// @notice Primary round selection pool.
    address[] public primaryJurorPool;
    /// @notice Final round selection pool.
    address[] public finalJurorPool;
    /// @notice Expert juror pool (for query).
    address[] public expertJurorPool;
    /// @notice Expert juror index (1-based, used for O(1) removal).
    mapping(address => uint256) private expertJurorIndex;

    /// @notice Primary juror count.
    uint8 public override jurorCountPrimary;
    /// @notice Final juror count.
    uint8 public override jurorCountFinal;

    /// @notice Add juror event.
    event JurorAdded(
        address indexed juror,
        bool isFinalRound,
        uint64 timestamp
    );
    /// @notice Remove juror event.
    event JurorRemoved(
        address indexed juror,
        bool isFinalRound,
        uint64 timestamp
    );
    /// @notice Add expert juror event.
    event ExpertJurorAdded(address indexed juror, uint64 timestamp);
    /// @notice Remove expert juror event.
    event ExpertJurorRemoved(address indexed juror, uint64 timestamp);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert OmniErrors.ZeroOwner();
        __Ownable_init(_owner);
        __Pausable_init();

        jurorCountPrimary = 3;
        jurorCountFinal = 3;
    }

    /// @notice Set primary juror count.
    function setJurorCountPrimary(uint8 count) external onlyOwner {
        if (count == 0) revert OmniErrors.CountZero();
        jurorCountPrimary = count;
    }

    /// @notice Set final juror count.
    function setJurorCountFinal(uint8 count) external onlyOwner {
        if (count == 0) revert OmniErrors.CountZero();
        jurorCountFinal = count;
    }

    /// @notice Add primary juror.
    function addJuror(address juror) external onlyOwner {
        if (juror == address(0)) revert OmniErrors.ZeroJuror();
        if (!isPrimaryJuror[juror]) {
            isPrimaryJuror[juror] = true;
            primaryJurorPool.push(juror);
            emit JurorAdded(juror, false, uint64(block.timestamp));
        }
    }

    /// @notice Add final juror.
    function addFinalJuror(address juror) external onlyOwner {
        if (juror == address(0)) revert OmniErrors.ZeroJuror();
        if (!isFinalJuror[juror]) {
            isFinalJuror[juror] = true;
            finalJurorPool.push(juror);
            emit JurorAdded(juror, true, uint64(block.timestamp));
        }
    }

    /// @notice Remove primary juror.
    function removeJuror(address juror) external onlyOwner {
        if (isPrimaryJuror[juror]) {
            isPrimaryJuror[juror] = false;
            emit JurorRemoved(juror, false, uint64(block.timestamp));
        }
    }

    /// @notice Remove final juror.
    function removeFinalJuror(address juror) external onlyOwner {
        if (isFinalJuror[juror]) {
            isFinalJuror[juror] = false;
            emit JurorRemoved(juror, true, uint64(block.timestamp));
        }
    }

    /// @notice Add expert juror.
    function addExpertJuror(address juror) external onlyOwner {
        if (juror == address(0)) revert OmniErrors.ZeroJuror();
        if (!isExpertJuror[juror]) {
            isExpertJuror[juror] = true;
            expertCount += 1;
            expertJurorPool.push(juror);
            expertJurorIndex[juror] = expertJurorPool.length;
            emit ExpertJurorAdded(juror, uint64(block.timestamp));
        }
    }

    /// @notice Remove expert juror.
    function removeExpertJuror(address juror) external onlyOwner {
        if (isExpertJuror[juror]) {
            isExpertJuror[juror] = false;
            if (expertCount > 0) {
                expertCount -= 1;
            }
            uint256 idx = expertJurorIndex[juror];
            if (idx > 0) {
                uint256 lastIndex = expertJurorPool.length;
                if (idx != lastIndex) {
                    address last = expertJurorPool[lastIndex - 1];
                    expertJurorPool[idx - 1] = last;
                    expertJurorIndex[last] = idx;
                }
                expertJurorPool.pop();
                expertJurorIndex[juror] = 0;
            }
            emit ExpertJurorRemoved(juror, uint64(block.timestamp));
        }
    }

    /// @notice Juror selection logic (moved from Adapter).
    function pickJurors(
        bytes32 orderId,
        bool isPrimary
    ) external view override returns (address[] memory selected) {
        address[] storage pool = isPrimary ? primaryJurorPool : finalJurorPool;
        uint8 count = isPrimary ? jurorCountPrimary : jurorCountFinal;
        if (pool.length < count) revert OmniErrors.NotEnoughJurors();

        selected = new address[](count);
        uint256 start = uint256(
            keccak256(
                abi.encodePacked(
                    orderId,
                    block.number,
                    block.prevrandao,
                    isPrimary
                )
            )
        ) % pool.length;

        uint256 picked = 0;
        uint256 idx = start;
        uint256 attempts = 0;
        uint256 poolLen = pool.length;

        while (picked < count && attempts < poolLen) {
            address juror = pool[idx];
            bool allowed = isPrimary
                ? isPrimaryJuror[juror]
                : isFinalJuror[juror];
            if (allowed && !_isAlreadySelected(selected, juror, picked)) {
                selected[picked] = juror;
                picked++;
            }
            idx = (idx + 1) % poolLen;
            attempts++;
        }
        if (picked < count) revert OmniErrors.NotEnoughJurors();
    }

    function _isAlreadySelected(
        address[] memory list,
        address account,
        uint256 limit
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < limit; i++) {
            if (list[i] == account) return true;
        }
        return false;
    }

    /// @notice Paginated query for experts.
    function getExpertJurors(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory items, uint256 total) {
        total = expertJurorPool.length;
        if (offset >= total || limit == 0) return (new address[](0), total);
        uint256 end = offset + limit > total ? total : offset + limit;
        items = new address[](end - offset);
        for (uint256 i = offset; i < end; i++)
            items[i - offset] = expertJurorPool[i];
    }

    /// @notice Paginated query for primary jurors (active).
    function getPrimaryJurors(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory items, uint256 total) {
        uint256 poolLen = primaryJurorPool.length;
        for (uint256 i = 0; i < poolLen; i++) {
            if (isPrimaryJuror[primaryJurorPool[i]]) total++;
        }
        if (offset >= total || limit == 0) return (new address[](0), total);
        uint256 end = offset + limit > total ? total : offset + limit;
        items = new address[](end - offset);
        uint256 idx = 0;
        uint256 out = 0;
        for (uint256 i = 0; i < poolLen && out < items.length; i++) {
            if (isPrimaryJuror[primaryJurorPool[i]]) {
                if (idx >= offset) {
                    items[out] = primaryJurorPool[i];
                    out++;
                }
                idx++;
            }
        }
    }

    /// @notice Paginated query for final jurors (active).
    function getFinalJurors(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory items, uint256 total) {
        uint256 poolLen = finalJurorPool.length;
        for (uint256 i = 0; i < poolLen; i++) {
            if (isFinalJuror[finalJurorPool[i]]) total++;
        }
        if (offset >= total || limit == 0) return (new address[](0), total);
        uint256 end = offset + limit > total ? total : offset + limit;
        items = new address[](end - offset);
        uint256 idx = 0;
        uint256 out = 0;
        for (uint256 i = 0; i < poolLen && out < items.length; i++) {
            if (isFinalJuror[finalJurorPool[i]]) {
                if (idx >= offset) {
                    items[out] = finalJurorPool[i];
                    out++;
                }
                idx++;
            }
        }
    }
}
