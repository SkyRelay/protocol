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
        beacon = new SkyRelayBeacon(makeAddr("attester"), makeAddr("vault"));
    }

    function _at(uint256 i) internal view returns (SkyRelayBeacon.SkyRelayAttestation memory a) {
        string memory k = string.concat(".attestations[", vm.toString(i), "]");
        a.operator = vm.parseJsonAddress(json, string.concat(k, ".operator"));
        a.telemetryHash = vm.parseJsonBytes32(json, string.concat(k, ".telemetryHash"));
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
                "SkyRelayAttestation(address operator,bytes32 telemetryHash,uint32 noradId,int32 elevationMilliDeg,int32 dopplerHz,uint32 snrMilliDb,uint32 asn,uint64 timestamp)"
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
