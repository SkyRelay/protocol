// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";
import {CatalogRegistry} from "../src/CatalogRegistry.sol";

contract Vault {
    receive() external payable {}
}

/// @notice `verifyAndRecord` takes a set of attestations and a matching set of
///         signatures. A single-attester deployment is just the degenerate case
///         where the set has one member, so there is one code path to audit
///         rather than two.
contract SkyRelayBeaconTest is Test {
    uint256 internal constant PK_A = 0xA11CE;
    uint256 internal constant PK_B = 0xB0B;
    uint256 internal constant PK_C = 0xC0FFEE;
    uint256 internal constant PK_OUTSIDER = 0xDEAD;
    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant UNBONDING_PERIOD = 7 days;
    uint16 internal constant REPORTER_BOUNTY_BPS = 1000;

    address internal owner = makeAddr("owner");
    address internal opA = makeAddr("opA");
    address internal opB = makeAddr("opB");
    address internal opC = makeAddr("opC");

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
        a.telemetryHash = keccak256(abi.encodePacked("telemetry", operator));
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

    /// @dev Grow the attester set to three and require two of them.
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

    // ── the single-attester case ────────────────────────────────────────────

    function test_recordsABeacon() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        // NOTE: _sign makes an external call, which would consume vm.prank if
        // it were evaluated in argument position. Sign first, prank second.
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        uint256 id = beacon.verifyAndRecord(_one(a), sigs);
        assertEq(id, 1);
        assertEq(beacon.totalBeacons(), 1);
        assertEq(beacon.totalEnergy(), 8700);
        assertEq(beacon.userBeaconCount(opA), 1);
    }

    function test_forwardsValueToVault() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.deal(opA, 1 ether);
        vm.prank(opA);
        beacon.verifyAndRecord{value: 0.05 ether}(_one(a), sigs);
        assertEq(address(vault).balance, 0.05 ether);
    }

    function test_rejectsBadAsn() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        a.asn = 15169;
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.BadAsn.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    function test_acceptsIndonesiaAsn() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        a.asn = 45700;
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        assertEq(beacon.verifyAndRecord(_one(a), sigs), 1);
    }

    function test_rejectsBelowHorizon() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        a.elevationMilliDeg = 0;
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.BelowHorizon.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    function test_rejectsExpiredAndFuture() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        a.timestamp = uint64(block.timestamp - 121);
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.Expired.selector);
        beacon.verifyAndRecord(_one(a), sigs);

        a = _att(opA);
        a.timestamp = uint64(block.timestamp + 31);
        sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.Future.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    function test_rejectsReplay() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        beacon.verifyAndRecord(_one(a), sigs);
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.Replay.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    function test_rejectsUnregisteredSigner() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_OUTSIDER, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.BadSigner.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    function test_rejectsSignerWhoseBondIsBelowMinBond() public {
        vm.prank(owner);
        beacon.scheduleAttester(vm.addr(PK_B));
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(vm.addr(PK_B));
        // registered, but bonded = 0
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_B, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.NotBonded.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    function test_rejectsUnbondingSigner() public {
        vm.prank(vm.addr(PK_A));
        bonds.requestUnbond();
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.NotBonded.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    function test_rejectsUnregisteredCatalogHash() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        a.catalogHash = keccak256("never-registered");
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.UnregisteredCatalog.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    function test_rejectsSubmitterWhoIsNotAnOperator() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(makeAddr("frontRunner"));
        vm.expectRevert(SkyRelayBeacon.WrongOperator.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    /// @dev The front-runner cannot take the credit and cannot grief the
    ///      rightful operator by burning the digest first.
    function test_frontRunnerCannotStealOrGrief() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_A, a));
        address frontRunner = makeAddr("frontRunner");

        vm.prank(frontRunner);
        vm.expectRevert(SkyRelayBeacon.WrongOperator.selector);
        beacon.verifyAndRecord(_one(a), sigs);

        vm.prank(opA);
        assertEq(beacon.verifyAndRecord(_one(a), sigs), 1);
        assertEq(beacon.userBeaconCount(opA), 1);
        assertEq(beacon.userBeaconCount(frontRunner), 0);
    }

    function test_pausedContractAcceptsNothing() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(owner);
        beacon.pause();
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.IsPaused.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    // ── the quorum case ─────────────────────────────────────────────────────

    function _pair(address o1, address o2) internal view returns (SkyRelayBeacon.SkyRelayAttestation[] memory atts) {
        atts = new SkyRelayBeacon.SkyRelayAttestation[](2);
        atts[0] = _att(o1);
        atts[1] = _att(o2);
        // two stations see the same satellite at the same second from different
        // places, so the geometry they report legitimately differs
        atts[1].elevationMilliDeg = 31_804;
        atts[1].dopplerHz = 96_210;
        atts[1].snrMilliDb = 7100;
    }

    function _triple() internal view returns (SkyRelayBeacon.SkyRelayAttestation[] memory atts) {
        atts = new SkyRelayBeacon.SkyRelayAttestation[](3);
        atts[0] = _att(opA);
        atts[1] = _att(opB);
        atts[1].elevationMilliDeg = 31_804;
        atts[1].dopplerHz = 220_040;
        atts[1].snrMilliDb = 8100;
        atts[2] = _att(opC);
        atts[2].elevationMilliDeg = 25_210;
        atts[2].dopplerHz = 215_966;
        atts[2].snrMilliDb = 6900;
        atts[2].asn = 45700;
    }

    function test_quorumOfThreeIsRecordedOnce() public {
        _enableQuorumOfTwo();
        vm.prank(owner);
        beacon.setQuorumThreshold(3);

        SkyRelayBeacon.SkyRelayAttestation[] memory atts = _triple();
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);
        sigs[2] = _sign(PK_C, atts[2]);

        vm.prank(opA);
        uint256 id = beacon.verifyAndRecord(atts, sigs);
        assertEq(id, 1);
        assertEq(beacon.totalBeacons(), 1, "a quorum is one beacon, not three");
        assertEq(beacon.userBeaconCount(opA), 1);
        assertEq(beacon.userBeaconCount(opB), 1);
        assertEq(beacon.userBeaconCount(opC), 1);
    }

    function test_quorumOfTwoIsRecordedOnce() public {
        _enableQuorumOfTwo();
        SkyRelayBeacon.SkyRelayAttestation[] memory atts = _pair(opA, opB);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);

        vm.prank(opA);
        uint256 id = beacon.verifyAndRecord(atts, sigs);
        assertEq(id, 1);
        assertEq(beacon.totalBeacons(), 1, "a quorum is one beacon, not two");
        assertEq(beacon.userBeaconCount(opA), 1);
        assertEq(beacon.userBeaconCount(opB), 1, "every station in the quorum is credited");
        assertEq(beacon.totalEnergy(), 8700 + 7100);
    }

    function test_quorumRejectsTooFewAttestations() public {
        _enableQuorumOfTwo();
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.QuorumNotMet.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }

    /// @dev The whole point of a quorum: one key must not be able to fill it
    ///      alone by signing twice.
    function test_oneAttesterCannotFillTheQuorumAlone() public {
        _enableQuorumOfTwo();
        SkyRelayBeacon.SkyRelayAttestation[] memory atts = _pair(opA, opB);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_A, atts[1]);

        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.DuplicateSigner.selector);
        beacon.verifyAndRecord(atts, sigs);
    }

    function test_quorumRejectsARepeatedOperator() public {
        _enableQuorumOfTwo();
        SkyRelayBeacon.SkyRelayAttestation[] memory atts = _pair(opA, opA);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);

        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.DuplicateOperator.selector);
        beacon.verifyAndRecord(atts, sigs);
    }

    /// @dev Stations must be describing the same sighting. Disagreement on the
    ///      satellite, the second, or the element set is not a quorum.
    function test_quorumRejectsDisagreementOnWhatWasSeen() public {
        _enableQuorumOfTwo();

        SkyRelayBeacon.SkyRelayAttestation[] memory atts = _pair(opA, opB);
        atts[1].noradId = 46029;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.InconsistentQuorum.selector);
        beacon.verifyAndRecord(atts, sigs);

        atts = _pair(opA, opB);
        atts[1].timestamp = atts[0].timestamp - 1;
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.InconsistentQuorum.selector);
        beacon.verifyAndRecord(atts, sigs);

        atts = _pair(opA, opB);
        atts[1].catalogHash = keccak256("a different catalog");
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.InconsistentQuorum.selector);
        beacon.verifyAndRecord(atts, sigs);
    }

    function test_quorumSubmitterMustBeOneOfTheOperators() public {
        _enableQuorumOfTwo();
        SkyRelayBeacon.SkyRelayAttestation[] memory atts = _pair(opA, opB);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);

        vm.prank(opC);
        vm.expectRevert(SkyRelayBeacon.WrongOperator.selector);
        beacon.verifyAndRecord(atts, sigs);

        vm.prank(opB);
        assertEq(beacon.verifyAndRecord(atts, sigs), 1, "any member may relay");
    }

    function test_rejectsLengthMismatch() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.LengthMismatch.selector);
        beacon.verifyAndRecord(_one(a), new bytes[](2));
    }

    function test_rejectsEmptySet() public {
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.QuorumNotMet.selector);
        beacon.verifyAndRecord(new SkyRelayBeacon.SkyRelayAttestation[](0), new bytes[](0));
    }

    // ── digest ──────────────────────────────────────────────────────────────

    function test_digestIsBoundToEveryDomainField() public view {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes32 d = beacon.hashAttestation(a, 97, address(beacon));
        assertTrue(beacon.hashAttestation(a, 56, address(beacon)) != d, "chainId");
        assertTrue(beacon.hashAttestation(a, 97, address(1)) != d, "verifyingContract");
    }

    function test_catalogHashMovesTheDigest() public view {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes32 d = beacon.hashAttestation(a, block.chainid, address(beacon));
        a.catalogHash = keccak256("doctored elements");
        assertTrue(beacon.hashAttestation(a, block.chainid, address(beacon)) != d);
    }

    // ── fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_timestampInsideWindow(uint64 skew) public {
        skew = uint64(bound(skew, 0, 120));
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        a.timestamp = uint64(block.timestamp) - skew;
        bytes[] memory sigs = _one(_sign(PK_A, a));
        vm.prank(opA);
        assertEq(beacon.verifyAndRecord(_one(a), sigs), 1);
    }

    function testFuzz_onlyRegisteredKeysAreAccepted(uint256 pk) public {
        pk = bound(pk, 1, type(uint128).max);
        vm.assume(vm.addr(pk) != vm.addr(PK_A));
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        bytes[] memory sigs = _one(_sign(pk, a));
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.BadSigner.selector);
        beacon.verifyAndRecord(_one(a), sigs);
    }
}
