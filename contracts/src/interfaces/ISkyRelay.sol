// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISkyRelay
/// @notice Read surface for contracts that consume the SkyRelay beacon ledger.
/// @dev Views only. A consumer reads; it does not write beacons.
interface ISkyRelay {
    struct BeaconSummary {
        uint32 noradId;
        uint64 timestamp;
        bytes32 catalogHash;
        uint8 quorum;
        address submitter;
    }

    function totalBeacons() external view returns (uint256);

    function getBeacon(uint256 beaconId) external view returns (BeaconSummary memory);

    /// @notice Sum of verified sightings for `operator` whose attestation
    ///         timestamps fall in `[fromTs, toTs]`, bucketed by UTC day.
    /// @dev One SLOAD per day in the window, inclusive of both endpoints.
    ///      Reverts `BadWindow` if `toTs < fromTs`, `WindowTooLong` if the
    ///      inclusive day-bucket span exceeds 366.
    function beaconCountInWindow(address operator, uint64 fromTs, uint64 toTs) external view returns (uint256);

    /// @notice `claimed` being true means exactly: a bonded attester signed a
    ///         statement that this transaction was relayed during a sighting the
    ///         chain verified geometrically.
    /// @dev The chain verifies the sighting and the signature. It takes the
    ///      attester's word for the routing; a transaction hash carries no
    ///      route information.
    function wasClaimedSpaceRelayed(bytes32 txHash, uint256 beaconId, bytes32[] calldata proof)
        external
        view
        returns (bool claimed, address attester, uint64 claimedAt, uint32 noradId);
}
