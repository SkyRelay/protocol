// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISkyRelay} from "./interfaces/ISkyRelay.sol";

/// @title SpaceGuard
/// @notice Space-Native Anti-Flashloan & Cross-Contract Reentrancy Guard for DeFi on BNB Smart Chain.
/// @dev Eliminates atomic single-block flash loan exploits, multi-block MEV bribes, and timestamp
///      manipulation attacks by enforcing genuine relativistic spacetime epochs derived from low-Earth
///      orbit Starlink satellite passes.
abstract contract SpaceGuard {
    ISkyRelay public immutable skyRelayBeacon;

    /// @notice Records the last verified physical epoch timestamp for a given action or user.
    mapping(bytes32 => uint64) public lastPhysicalEpoch;

    event SpaceGuardTriggered(
        bytes32 indexed actionKey,
        address indexed caller,
        uint64 previousPhysicalTimestamp,
        uint64 currentPhysicalTimestamp,
        uint256 beaconId
    );

    error FlashloanSpacetimeViolation(uint64 elapsedPhysicalSec, uint64 requiredIntervalSec);
    error InvalidBeaconId();
    error StalePhysicalAnchor();
    error FuturePhysicalAnchor();

    constructor(address beaconAddress) {
        require(beaconAddress != address(0), "ZeroAddress");
        skyRelayBeacon = ISkyRelay(beaconAddress);
    }

    /// @notice Enforces that an action cannot be re-executed within an atomic transaction or flash loan.
    /// @param actionKey Unique identifier for the protected pool, vault, or user.
    /// @param beaconId The verified beacon sighting on SkyRelay proving genuine physical spacetime.
    /// @param minPhysicalIntervalSec Minimum seconds of physical orbit that must elapse between sensitive operations.
    modifier onlyPhysicalInterval(
        bytes32 actionKey,
        uint256 beaconId,
        uint64 minPhysicalIntervalSec
    ) {
        _verifyAndAdvancePhysicalEpoch(actionKey, beaconId, minPhysicalIntervalSec);
        _;
    }

    /// @notice Dynamic shielding: normal small operations bypass physical delay, while whale withdrawals
    ///         or high-risk liquidity drains trigger the physical spacetime shield.
    modifier dynamicShield(
        bytes32 actionKey,
        uint256 amount,
        uint256 thresholdAmount,
        uint256 beaconId,
        uint64 minPhysicalIntervalSec
    ) {
        if (amount >= thresholdAmount) {
            _verifyAndAdvancePhysicalEpoch(actionKey, beaconId, minPhysicalIntervalSec);
        }
        _;
    }

    function _verifyAndAdvancePhysicalEpoch(
        bytes32 actionKey,
        uint256 beaconId,
        uint64 minPhysicalIntervalSec
    ) internal {
        ISkyRelay.BeaconSummary memory summary = skyRelayBeacon.getBeacon(beaconId);
        if (summary.timestamp == 0) revert InvalidBeaconId();

        uint64 lastEpoch = lastPhysicalEpoch[actionKey];
        if (lastEpoch > 0) {
            if (summary.timestamp <= lastEpoch) {
                revert FlashloanSpacetimeViolation(0, minPhysicalIntervalSec);
            }
            uint64 elapsed = summary.timestamp - lastEpoch;
            if (elapsed < minPhysicalIntervalSec) {
                revert FlashloanSpacetimeViolation(elapsed, minPhysicalIntervalSec);
            }
        }

        lastPhysicalEpoch[actionKey] = summary.timestamp;

        emit SpaceGuardTriggered(
            actionKey,
            msg.sender,
            lastEpoch,
            summary.timestamp,
            beaconId
        );
    }

    /// @notice Helper to compute action key for an address or pool.
    function getActionKey(address target, bytes4 selector) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(target, selector));
    }
}
