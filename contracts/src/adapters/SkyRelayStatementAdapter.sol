// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStatementAdapter} from "../interfaces/IStatementAdapter.sol";
import {SkyRelayBeacon} from "../SkyRelayBeacon.sol";

/// @title SkyRelayStatementAdapter
/// @notice Maps SkyRelay orbital radio attestations into the generic EquivocationBond engine.
contract SkyRelayStatementAdapter is IStatementAdapter {
    SkyRelayBeacon public immutable beacon;

    error ZeroAddress();

    constructor(address beaconAddress) {
        if (beaconAddress == address(0)) revert ZeroAddress();
        beacon = SkyRelayBeacon(beaconAddress);
    }

    /// @notice Decode raw SkyRelayAttestation payload.
    /// @dev subject: the ground station operator address.
    ///      slot: the attestation UTC second (operator can only observe 1 state per second).
    ///      digest: the canonical EIP-712 typed data digest computed against the beacon domain.
    function parseStatement(bytes calldata statement)
        external
        view
        override
        returns (address subject, bytes32 slot, bytes32 digest)
    {
        SkyRelayBeacon.SkyRelayAttestation memory att = abi.decode(
            statement,
            (SkyRelayBeacon.SkyRelayAttestation)
        );
        subject = att.operator;
        slot = bytes32(uint256(att.timestamp));
        digest = beacon.hashAttestation(att, block.chainid, address(beacon));
    }
}
