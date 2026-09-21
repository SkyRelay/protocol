// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";

/// @title Cross-implementation EIP-712 vectors
/// @notice The digests in vectors/eip712/attestations.json are produced by the
///         dependency-free Keccak-256 and ABI encoder in
///         packages/core/src/crypto. Here solc recomputes them from the same
///         fields. The two implementations share no code, so a divergence in
///         the type string, the field order, the int32 sign extension, or the
///         domain separator fails here rather than on chain.
/// @dev Regenerate the file with `pnpm run vectors`.
contract Eip712VectorsTest is Test {
    SkyRelayBeacon internal beacon;
    string internal json;
    uint256 internal chainId;
    address internal verifyingContract;

    function setUp() public {
        json = vm.readFile("../vectors/eip712/attestations.json");
        chainId = vm.parseJsonUint(json, ".domain.chainId");
        verifyingContract = vm.parseJsonAddress(json, ".domain.verifyingContract");
        beacon = new SkyRelayBeacon(
            makeAddr("owner"), makeAddr("attester"), makeAddr("vault"), makeAddr("catalog"), makeAddr("bond")
        );
    }

    function _at(uint256 i) internal view returns (SkyRelayBeacon.SkyRelayAttestation memory a) {
        string memory k = string.concat(".attestations[", vm.toString(i), "]");
        a.operator = vm.parseJsonAddress(json, string.concat(k, ".operator"));
        a.telemetryHash = vm.parseJsonBytes32(json, string.concat(k, ".telemetryHash"));
        a.catalogHash = vm.parseJsonBytes32(json, string.concat(k, ".catalogHash"));
        a.noradId = uint32(vm.parseJsonUint(json, string.concat(k, ".noradId")));
        a.elevationMilliDeg = int32(vm.parseJsonInt(json, string.concat(k, ".elevationMilliDeg")));
        a.dopplerHz = int32(vm.parseJsonInt(json, string.concat(k, ".dopplerHz")));
        a.snrMilliDb = uint32(vm.parseJsonUint(json, string.concat(k, ".snrMilliDb")));
        a.asn = uint32(vm.parseJsonUint(json, string.concat(k, ".asn")));
        a.timestamp = uint64(vm.parseJsonUint(json, string.concat(k, ".timestamp")));
    }

    function test_solidityReproducesEveryTypescriptDigest() public view {
        uint256 count = vm.parseJsonUint(json, ".count");
        assertGt(count, 0, "no digest vectors");
        for (uint256 i = 0; i < count; i++) {
            string memory k = string.concat(".attestations[", vm.toString(i), "]");
            bytes32 expected = vm.parseJsonBytes32(json, string.concat(k, ".digest"));
            bytes32 actual = beacon.hashAttestation(_at(i), chainId, verifyingContract);
            assertEq(actual, expected, vm.parseJsonString(json, string.concat(k, ".id")));
        }
    }

    function test_typehashMatchesTheCommittedTypeString() public view {
        assertEq(
            beacon.ATTESTATION_TYPEHASH(),
            keccak256(
                "SkyRelayAttestation(address operator,bytes32 telemetryHash,bytes32 catalogHash,uint32 noradId,int32 elevationMilliDeg,int32 dopplerHz,uint32 snrMilliDb,uint32 asn,uint64 timestamp)"
            )
        );
    }

    /// @dev Guards against an encoder that silently drops a field: every member
    ///      of the struct must move the digest.
    function test_everyFieldIsCommitted() public view {
        SkyRelayBeacon.SkyRelayAttestation memory base = _at(0);
        bytes32 d = beacon.hashAttestation(base, chainId, verifyingContract);

        SkyRelayBeacon.SkyRelayAttestation memory m = base;
        m.operator = address(uint160(base.operator) ^ 1);
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "operator");

        m = base;
        m.telemetryHash = base.telemetryHash ^ bytes32(uint256(1));
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "telemetryHash");

        m = base;
        m.catalogHash = base.catalogHash ^ bytes32(uint256(1));
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "catalogHash");

        m = base;
        m.noradId = base.noradId + 1;
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "noradId");

        m = base;
        m.elevationMilliDeg = base.elevationMilliDeg + 1;
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "elevationMilliDeg");

        m = base;
        m.dopplerHz = base.dopplerHz + 1;
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "dopplerHz");

        m = base;
        m.snrMilliDb = base.snrMilliDb + 1;
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "snrMilliDb");

        m = base;
        m.asn = base.asn + 1;
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "asn");

        m = base;
        m.timestamp = base.timestamp + 1;
        assertTrue(beacon.hashAttestation(m, chainId, verifyingContract) != d, "timestamp");
    }

    /// @notice The committed quorum must satisfy on chain exactly what
    ///         `verifyAndRecord` demands of it: every member agreeing on the
    ///         satellite, the second and the element set, while reporting its
    ///         own geometry. A fixture that could not pass InconsistentQuorum
    ///         would be documenting something the contract does not accept.
    function test_committedQuorumWouldSatisfyTheOnChainAgreementCheck() public view {
        string[] memory ids = vm.parseJsonStringArray(json, ".quorum.members");
        assertGe(ids.length, 2, "a quorum needs at least two stations");

        uint32 noradId = uint32(vm.parseJsonUint(json, ".quorum.noradId"));
        uint64 timestamp = uint64(vm.parseJsonUint(json, ".quorum.timestamp"));
        bytes32 catalog = vm.parseJsonBytes32(json, ".quorum.catalogHash");

        uint256 count = vm.parseJsonUint(json, ".count");
        uint256 seen;
        int32[] memory elevations = new int32[](ids.length);

        for (uint256 m = 0; m < ids.length; m++) {
            for (uint256 i = 0; i < count; i++) {
                string memory k = string.concat(".attestations[", vm.toString(i), "]");
                if (keccak256(bytes(vm.parseJsonString(json, string.concat(k, ".id")))) != keccak256(bytes(ids[m]))) {
                    continue;
                }

                SkyRelayBeacon.SkyRelayAttestation memory a = _at(i);
                assertEq(a.noradId, noradId, ids[m]);
                assertEq(a.timestamp, timestamp, ids[m]);
                assertEq(a.catalogHash, catalog, ids[m]);
                assertGt(a.elevationMilliDeg, 0, ids[m]);
                elevations[m] = a.elevationMilliDeg;
                seen++;
                break;
            }
        }
        assertEq(seen, ids.length, "every quorum member must be a committed vector");

        // Different places see the same satellite at different elevations; a set
        // that agreed on everything would not be independent observation.
        bool differs;
        for (uint256 i = 1; i < elevations.length; i++) {
            if (elevations[i] != elevations[0]) differs = true;
        }
        assertTrue(differs, "stations must report distinct geometry");
    }

    /// @dev Negative Doppler is the case where a wrong int32 sign extension shows up.
    function test_negativeDopplerVectorIsPresent() public view {
        uint256 count = vm.parseJsonUint(json, ".count");
        bool sawNegative;
        for (uint256 i = 0; i < count; i++) {
            if (_at(i).dopplerHz < 0) sawNegative = true;
        }
        assertTrue(sawNegative, "vectors must cover a receding satellite");
    }
}
