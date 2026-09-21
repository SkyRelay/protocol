// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISkyRelay
/// @notice Read surface for contracts that consume the SkyRelay beacon ledger.
/// @dev Views only. A consumer reads; it does not write beacons.
interface ISkyRelay {
    /// @notice One verified sighting. Three slots: `noradId`, `timestamp` and
    ///         `quorum` share the first (13 bytes); each hash takes a slot.
    /// @dev `submitter` is not stored. Nothing on chain read it — an indexer
    ///      gets the address from `BeaconBroadcast`. It is 20 bytes, and with
    ///      the three small fields that is 33, so putting it back spills a
    ///      fourth slot and a cold SSTORE onto every sighting.
    struct BeaconSummary {
        uint32 noradId;
        uint64 timestamp;
        uint8 quorum;
        bytes32 catalogHash;
        /// @notice `keccak256(abi.encodePacked(signers))` over the recovered
        ///         signers, in the order they appeared in the submitted set.
        /// @dev Order-sensitive. The hot path stores this one hash instead of
        ///      one slot per member; `submitRelayClaim` re-supplies the array.
        bytes32 signersHash;
    }

    function totalBeacons() external view returns (uint256);

    function getBeacon(uint256 beaconId) external view returns (BeaconSummary memory);

    /// @notice Sum of verified sightings for `operator` whose attestation
    ///         timestamps fall in `[fromTs, toTs]`, bucketed by UTC day.
    /// @dev One SLOAD per day in the window, inclusive of both endpoints.
    ///      Reverts `BadWindow` if `toTs < fromTs`, `WindowTooLong` if the
    ///      inclusive day-bucket span exceeds 366. On-chain settlement should
    ///      prefer ~30 days and split longer periods into several claims.
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

/// @title ISkyRelayEntropy
/// @notice Request surface for the commit-reveal beacon.
/// @dev A verified sighting is an admission ticket, not entropy: the satellite
///      contributes none. The beacon is secure if at least one participant is
///      honest and reveals. This is not a VRF. If a consumer needs randomness
///      with stronger guarantees than one honest participant, Chainlink VRF
///      exists on BSC and is the appropriate tool.
interface ISkyRelayEntropy {
    /// @notice Ask for `numWords` from the round after the current one.
    /// @dev A call during round R is served by round R+1. Commits for R+1
    ///      closed when R began, before this request; reveals for R+1 happen
    ///      after it.
    function requestRandomness(uint32 numWords) external returns (bytes32 requestId, uint64 servingRound);

    /// @notice Words for a request whose serving round has finalized with a seed.
    /// @dev `words[i] = uint256(keccak256(abi.encode(seed, requestId, i)))`.
    ///      Reverts if that round is not finalized or finalized with no reveals.
    function randomWords(bytes32 requestId) external view returns (uint256[] memory words);

    /// @notice Seed of a finalized round that had at least one reveal.
    /// @dev Reverts `NoSeed` when the round finalized with no reveals. The zero
    ///      word is not a seed.
    function seedOf(uint64 round) external view returns (bytes32 seed, uint32 contributors);

    /// @notice Point `requestId` at a later round after its serving round
    ///         finalized with no reveals.
    function reservice(bytes32 requestId) external returns (uint64 servingRound);
}
