// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";
import {CatalogRegistry} from "../src/CatalogRegistry.sol";
import {ISkyRelay} from "../src/interfaces/ISkyRelay.sol";
import {MockCoverageEscrow} from "./mock/MockCoverageEscrow.sol";

contract Vault {
    receive() external payable {}
}

/// @notice Windowed counts, relay claims, Merkle inclusion, and the escrow
///         that consumes `ISkyRelay`. A claim is a bonded assertion: the chain
///         verifies the sighting and the signature, and takes the operator's
///         word for the routing.
contract ComposabilityTest is Test {
    uint256 internal constant PK_A = 0xA11CE;
    uint256 internal constant PK_B = 0xB0B;
    uint256 internal constant PK_C = 0xC0FFEE;
    uint256 internal constant PK_OUTSIDER = 0xDEAD;
    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant UNBONDING_PERIOD = 7 days;
    uint16 internal constant REPORTER_BOUNTY_BPS = 1000;
    uint64 internal constant DAY = 86400;

    address internal owner = makeAddr("owner");
    address internal opA = makeAddr("opA");
    address internal opB = makeAddr("opB");
    address internal opC = makeAddr("opC");
    address internal funder = makeAddr("funder");

    Vault internal vault;
    CatalogRegistry internal catalog;
    SkyRelayBond internal bonds;
    SkyRelayBeacon internal beacon;

    bytes32 internal constant CATALOG = keccak256("catalog-2026-263");

    function setUp() public {
        vault = new Vault();
        catalog = new CatalogRegistry(owner);
        uint64 nonce = vm.getNonce(address(this));
        address predictedBeacon = vm.computeCreateAddress(address(this), nonce + 1);
        bonds = new SkyRelayBond(MIN_BOND, UNBONDING_PERIOD, REPORTER_BOUNTY_BPS, address(vault), predictedBeacon);
        beacon = new SkyRelayBeacon(owner, vm.addr(PK_A), address(vault), address(catalog), address(bonds));
        assertEq(address(beacon), predictedBeacon);
        vm.warp(1_789_918_203);

        vm.prank(owner);
        catalog.register(CATALOG, "gnfd://skyrelay-catalog/test.tle");

        address attester = vm.addr(PK_A);
        vm.deal(attester, 10 ether);
        vm.prank(attester);
        bonds.bond{value: MIN_BOND}();
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _att(address operator) internal view returns (SkyRelayBeacon.SkyRelayAttestation memory a) {
        a.operator = operator;
        a.telemetryHash = keccak256(abi.encodePacked("telemetry", operator, block.timestamp));
        a.catalogHash = CATALOG;
        a.noradId = 44714;
        a.elevationMilliDeg = 48_229;
        a.dopplerHz = 171_617;
        a.snrMilliDb = 8700;
        a.asn = 14593;
        a.timestamp = uint64(block.timestamp);
    }

    function _sign(uint256 pk, SkyRelayBeacon.SkyRelayAttestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, beacon.hashAttestation(a, block.chainid, address(beacon)));
        return abi.encodePacked(r, s, v);
    }

    function _one(SkyRelayBeacon.SkyRelayAttestation memory a)
        internal
        pure
        returns (SkyRelayBeacon.SkyRelayAttestation[] memory out)
    {
        out = new SkyRelayBeacon.SkyRelayAttestation[](1);
        out[0] = a;
    }

    function _one(bytes memory sig) internal pure returns (bytes[] memory out) {
        out = new bytes[](1);
        out[0] = sig;
    }

    function _bond(address who) internal {
        vm.deal(who, 10 ether);
        vm.prank(who);
        bonds.bond{value: MIN_BOND}();
    }

    function _enableQuorumOfTwo() internal {
        vm.startPrank(owner);
        beacon.scheduleAttester(vm.addr(PK_B));
        beacon.scheduleAttester(vm.addr(PK_C));
        vm.stopPrank();
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(vm.addr(PK_B));
        beacon.activateAttester(vm.addr(PK_C));
        _bond(vm.addr(PK_B));
        _bond(vm.addr(PK_C));
        vm.prank(owner);
        beacon.setQuorumThreshold(2);
    }

    function _record(address operator, uint256 pk, uint64 ts) internal returns (uint256 id) {
        vm.warp(ts);
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(operator);
        a.timestamp = ts;
        bytes[] memory sigs = _one(_sign(pk, a));
        vm.prank(operator);
        id = beacon.verifyAndRecord(_one(a), sigs);
    }

    function _signClaim(uint256 pk, uint256 beaconId, bytes32 root, uint32 txCount, uint64 ts)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, beacon.hashRelayClaim(beaconId, root, txCount, ts));
        return abi.encodePacked(r, s, v);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Layer-by-layer sorted-pair tree. An unpaired node is promoted
    ///      unchanged, so a proof omits a sibling at that level.
    function _merkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 n = leaves.length;
        while (n > 1) {
            uint256 nextLen = (n + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLen);
            for (uint256 i = 0; i < nextLen; i++) {
                if (2 * i + 1 < n) {
                    next[i] = _hashPair(leaves[2 * i], leaves[2 * i + 1]);
                } else {
                    next[i] = leaves[2 * i];
                }
            }
            leaves = next;
            n = nextLen;
        }
        return leaves[0];
    }

    function _merkleProof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        uint256 n = leaves.length;
        uint256 idx = index;
        bytes32[] memory layer = leaves;
        bytes32[] memory acc = new bytes32[](32);
        uint256 nProof;
        while (n > 1) {
            if (idx % 2 == 1) {
                acc[nProof++] = layer[idx - 1];
            } else if (idx + 1 < n) {
                acc[nProof++] = layer[idx + 1];
            }
            uint256 nextLen = (n + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLen);
            for (uint256 i = 0; i < nextLen; i++) {
                if (2 * i + 1 < n) {
                    next[i] = _hashPair(layer[2 * i], layer[2 * i + 1]);
                } else {
                    next[i] = layer[2 * i];
                }
            }
            layer = next;
            n = nextLen;
            idx /= 2;
        }
        proof = new bytes32[](nProof);
        for (uint256 i = 0; i < nProof; i++) {
            proof[i] = acc[i];
        }
    }

    // ── windowed counts ─────────────────────────────────────────────────────

    function test_beaconCountInWindowSumsSeveralDays() public {
        uint64 d0 = 20_000 * DAY;
        _record(opA, PK_A, d0 + 100);
        _record(opA, PK_A, d0 + DAY + 100);
        _record(opA, PK_A, d0 + 2 * DAY + 100);
        _record(opA, PK_A, d0 + 2 * DAY + 200);

        assertEq(beacon.beaconsByDay(opA, 20_000), 1);
        assertEq(beacon.beaconsByDay(opA, 20_001), 1);
        assertEq(beacon.beaconsByDay(opA, 20_002), 2);
        assertEq(beacon.beaconCountInWindow(opA, d0, d0 + 2 * DAY + 200), 4);
        assertEq(beacon.beaconCountInWindow(opA, d0 + DAY, d0 + DAY + 100), 1);
        assertEq(beacon.userBeaconCount(opA), 4);
    }

    function test_beaconCountInWindowBoundariesAreInclusive() public {
        uint64 fromTs = 20_000 * DAY;
        uint64 toTs = 20_002 * DAY + 500;
        _record(opA, PK_A, fromTs);
        _record(opA, PK_A, toTs);
        _record(opA, PK_A, fromTs - 1);
        _record(opA, PK_A, uint64(uint256(toTs) / DAY + 1) * DAY);

        assertEq(beacon.beaconCountInWindow(opA, fromTs, toTs), 2, "from-day and to-day both count");
        assertEq(beacon.beaconsByDay(opA, 19_999), 1, "the second before fromTs is the previous day");
        assertEq(beacon.beaconsByDay(opA, 20_003), 1);
    }

    function test_beaconCountInWindowEmptyIsZero() public view {
        assertEq(beacon.beaconCountInWindow(opA, 1, 1), 0);
        assertEq(beacon.beaconCountInWindow(opA, 0, 30 * DAY), 0);
    }

    function test_beaconCountInWindowRevertsOnBadWindow() public {
        vm.expectRevert(SkyRelayBeacon.BadWindow.selector);
        beacon.beaconCountInWindow(opA, 10, 9);
    }

    function test_beaconCountInWindowRevertsWhenLongerThan366Days() public {
        uint64 fromTs = 100 * DAY;
        uint64 okTo = 465 * DAY; // days 100..465 inclusive = 366
        assertEq(beacon.beaconCountInWindow(opA, fromTs, okTo), 0);

        vm.expectRevert(SkyRelayBeacon.WindowTooLong.selector);
        beacon.beaconCountInWindow(opA, fromTs, okTo + DAY);
    }

    function test_bucketsByAttestationTimeNotBlockTime() public {
        uint64 midnight = 20_000 * DAY;
        vm.warp(midnight + 10);
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        a.timestamp = midnight - 50;
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        beacon.verifyAndRecord(_one(a), sigs);

        assertEq(beacon.beaconsByDay(opA, 19_999), 1);
        assertEq(beacon.beaconsByDay(opA, 20_000), 0);
        assertEq(beacon.beaconCountInWindow(opA, midnight - 50, midnight - 50), 1);
        assertEq(beacon.beaconCountInWindow(opA, midnight, midnight + 10), 0);
    }

    function test_getBeaconReturnsWhatWasRecorded() public {
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        ISkyRelay.BeaconSummary memory s = beacon.getBeacon(id);
        assertEq(s.noradId, 44714);
        assertEq(s.timestamp, uint64(block.timestamp));
        assertEq(s.catalogHash, CATALOG);
        assertEq(s.quorum, 1);
        assertEq(s.submitter, opA);
    }

    function test_getBeaconUnknownReverts() public {
        vm.expectRevert(SkyRelayBeacon.UnknownBeacon.selector);
        beacon.getBeacon(1);
        vm.expectRevert(SkyRelayBeacon.UnknownBeacon.selector);
        beacon.getBeacon(0);
    }

    function test_beaconCountInWindow_1day() public view {
        beacon.beaconCountInWindow(opA, 0, 0);
    }

    function test_beaconCountInWindow_30days() public view {
        beacon.beaconCountInWindow(opA, 0, 29 * DAY);
    }

    function test_beaconCountInWindow_366days() public view {
        beacon.beaconCountInWindow(opA, 0, 365 * DAY);
    }

    // ── relay claims ────────────────────────────────────────────────────────

    function test_relayClaimFromBeaconSignerSucceeds() public {
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        bytes32 txA = keccak256("tx-a");
        bytes32 txB = keccak256("tx-b");
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = txA;
        leaves[1] = txB;
        bytes32 root = _merkleRoot(leaves);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _signClaim(PK_A, id, root, 2, ts);

        vm.expectEmit(true, true, false, true);
        emit SkyRelayBeacon.RelayClaimed(id, vm.addr(PK_A), root, 2, ts);
        beacon.submitRelayClaim(id, root, 2, ts, sig);

        bytes32[] memory proof = _merkleProof(leaves, 0);
        (bool claimed, address attester, uint64 claimedAt, uint32 noradId) =
            beacon.wasClaimedSpaceRelayed(txA, id, proof);
        assertTrue(claimed);
        assertEq(attester, vm.addr(PK_A));
        assertEq(claimedAt, ts);
        assertEq(noradId, 44714);
    }

    function test_submitRelayClaim() public {
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        bytes32 root = keccak256("one-tx");
        uint64 ts = uint64(block.timestamp);
        beacon.submitRelayClaim(id, root, 1, ts, _signClaim(PK_A, id, root, 1, ts));
    }

    function test_relayClaimFromBondedNonSignerReverts() public {
        _enableQuorumOfTwo();
        SkyRelayBeacon.SkyRelayAttestation[] memory atts = new SkyRelayBeacon.SkyRelayAttestation[](2);
        atts[0] = _att(opA);
        atts[1] = _att(opB);
        atts[1].elevationMilliDeg = 31_804;
        atts[1].dopplerHz = 96_210;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);
        vm.prank(opA);
        uint256 id = beacon.verifyAndRecord(atts, sigs);

        bytes32 root = keccak256("root");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _signClaim(PK_C, id, root, 1, ts);
        vm.expectRevert(SkyRelayBeacon.NotBeaconSigner.selector);
        beacon.submitRelayClaim(id, root, 1, ts, sig);
    }

    function test_relayClaimFromUnbondedAddressReverts() public {
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        vm.prank(vm.addr(PK_A));
        bonds.requestUnbond();
        bytes32 root = keccak256("root");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _signClaim(PK_A, id, root, 1, ts);
        vm.expectRevert(SkyRelayBeacon.NotBonded.selector);
        beacon.submitRelayClaim(id, root, 1, ts, sig);
    }

    function test_relayClaimFromNeverBondedAddressReverts() public {
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        bytes32 root = keccak256("root");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _signClaim(PK_OUTSIDER, id, root, 1, ts);
        vm.expectRevert(SkyRelayBeacon.NotBonded.selector);
        beacon.submitRelayClaim(id, root, 1, ts, sig);
    }

    function test_duplicateRelayClaimReverts() public {
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        bytes32 root = keccak256("root");
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _signClaim(PK_A, id, root, 1, ts);
        beacon.submitRelayClaim(id, root, 1, ts, sig);
        vm.expectRevert(SkyRelayBeacon.AlreadyClaimed.selector);
        beacon.submitRelayClaim(id, root, 1, ts, sig);
    }

    function test_relayClaimUnknownBeaconReverts() public {
        bytes32 root = keccak256("root");
        vm.expectRevert(SkyRelayBeacon.UnknownBeacon.selector);
        beacon.submitRelayClaim(1, root, 1, uint64(block.timestamp), hex"00");
    }

    function test_wasClaimedSpaceRelayedTrueAndFalseReturnTheAttester() public {
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        bytes32 inside = keccak256("inside");
        bytes32 outside = keccak256("outside");
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = inside;
        leaves[1] = keccak256("other");
        bytes32 root = _merkleRoot(leaves);
        uint64 ts = uint64(block.timestamp);
        beacon.submitRelayClaim(id, root, 2, ts, _signClaim(PK_A, id, root, 2, ts));

        bytes32[] memory proof = _merkleProof(leaves, 0);
        _assertClaim(inside, id, proof, true, ts);
        _assertClaim(outside, id, proof, false, ts);
    }

    function _assertClaim(bytes32 leaf, uint256 beaconId, bytes32[] memory proof, bool expect, uint64 ts)
        internal
        view
    {
        (bool claimed, address attester, uint64 claimedAt, uint32 noradId) =
            beacon.wasClaimedSpaceRelayed(leaf, beaconId, proof);
        assertEq(claimed, expect);
        assertEq(attester, vm.addr(PK_A));
        assertEq(claimedAt, ts);
        assertEq(noradId, 44714);
    }

    function test_singleLeafClaimEmptyProof() public {
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        bytes32 leaf = keccak256("only");
        uint64 ts = uint64(block.timestamp);
        beacon.submitRelayClaim(id, leaf, 1, ts, _signClaim(PK_A, id, leaf, 1, ts));
        bytes32[] memory empty = new bytes32[](0);
        (bool claimed, address attester,,) = beacon.wasClaimedSpaceRelayed(leaf, id, empty);
        assertTrue(claimed);
        assertEq(attester, vm.addr(PK_A));
        (bool no,,,) = beacon.wasClaimedSpaceRelayed(keccak256("other"), id, empty);
        assertFalse(no);
    }

    function test_attestationTypehashUnchanged() public view {
        assertEq(
            beacon.ATTESTATION_TYPEHASH(),
            keccak256(
                "SkyRelayAttestation(address operator,bytes32 telemetryHash,bytes32 catalogHash,uint32 noradId,int32 elevationMilliDeg,int32 dopplerHz,uint32 snrMilliDb,uint32 asn,uint64 timestamp)"
            )
        );
    }

    function testFuzz_merkleProofVerifier(bytes32[8] memory raw, uint8 nRaw, uint8 indexRaw) public {
        uint256 n = bound(nRaw, 1, 8);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            leaves[i] = keccak256(abi.encode(raw[i], i));
        }
        _checkFuzzProof(leaves, bound(indexRaw, 0, n - 1));
    }

    function _checkFuzzProof(bytes32[] memory leaves, uint256 index) internal {
        bytes32 root = _merkleRoot(leaves);
        bytes32[] memory proof = _merkleProof(leaves, index);
        uint256 id = _record(opA, PK_A, uint64(block.timestamp));
        _submit(id, root, uint32(leaves.length));
        (bool claimed, address attester,,) = beacon.wasClaimedSpaceRelayed(leaves[index], id, proof);
        assertTrue(claimed, "reference proof must verify");
        assertEq(attester, vm.addr(PK_A));
        (bool no, address attNo,,) =
            beacon.wasClaimedSpaceRelayed(keccak256(abi.encode(leaves[index], "absent")), id, proof);
        assertFalse(no, "a hash outside the tree must not verify");
        assertEq(attNo, vm.addr(PK_A));
    }

    function _submit(uint256 id, bytes32 root, uint32 txCount) internal {
        uint64 ts = uint64(block.timestamp);
        beacon.submitRelayClaim(id, root, txCount, ts, _signClaim(PK_A, id, root, txCount, ts));
    }

    // ── coverage escrow ─────────────────────────────────────────────────────

    function test_coverageEscrowPaysWhenWindowIsFilled() public {
        uint64 fromTs = uint64(block.timestamp);
        uint64 toTs = fromTs + 2 * DAY;
        MockCoverageEscrow escrow = new MockCoverageEscrow(ISkyRelay(address(beacon)));
        vm.deal(funder, 2 ether);
        vm.prank(funder);
        uint256 escrowId = escrow.fund{value: 1 ether}(opA, fromTs, toTs, 3);

        _record(opA, PK_A, fromTs);
        _record(opA, PK_A, fromTs + DAY);
        _record(opA, PK_A, fromTs + 2 * DAY);

        vm.warp(uint256(toTs) + 1);
        uint256 before = opA.balance;
        vm.prank(opA);
        escrow.claim(escrowId);
        assertEq(opA.balance, before + 1 ether);
        assertEq(address(escrow).balance, 0);

        vm.prank(opA);
        vm.expectRevert(MockCoverageEscrow.AlreadySettled.selector);
        escrow.claim(escrowId);
    }

    function test_coverageEscrowRefundsWhenWindowClosesShort() public {
        uint64 fromTs = uint64(block.timestamp);
        uint64 toTs = fromTs + 2 * DAY;
        MockCoverageEscrow escrow = new MockCoverageEscrow(ISkyRelay(address(beacon)));
        vm.deal(funder, 2 ether);
        vm.prank(funder);
        uint256 escrowId = escrow.fund{value: 1 ether}(opA, fromTs, toTs, 3);

        _record(opA, PK_A, fromTs);

        vm.warp(uint256(toTs) + 1);
        vm.prank(opA);
        vm.expectRevert(MockCoverageEscrow.CoverageShort.selector);
        escrow.claim(escrowId);

        uint256 before = funder.balance;
        vm.prank(funder);
        escrow.refund(escrowId);
        assertEq(funder.balance, before + 1 ether);

        vm.prank(funder);
        vm.expectRevert(MockCoverageEscrow.AlreadySettled.selector);
        escrow.refund(escrowId);
    }

    function test_coverageEscrowRejectsClaimBeforeWindowCloses() public {
        uint64 fromTs = uint64(block.timestamp);
        uint64 toTs = fromTs + DAY;
        MockCoverageEscrow escrow = new MockCoverageEscrow(ISkyRelay(address(beacon)));
        vm.deal(funder, 1 ether);
        vm.prank(funder);
        uint256 escrowId = escrow.fund{value: 1 ether}(opA, fromTs, toTs, 1);
        _record(opA, PK_A, fromTs);
        vm.prank(opA);
        vm.expectRevert(MockCoverageEscrow.WindowOpen.selector);
        escrow.claim(escrowId);
    }
}
