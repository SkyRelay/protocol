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

    /// @dev Gas of one `verifyAndRecord`, measured as a `gasleft()` delta
    ///      around the call. This is plain EVM arithmetic on purpose: it is
    ///      the execution of the call and excludes the 21,000 intrinsic cost
    ///      and calldata, so it does NOT match the transaction-level figures
    ///      in `docs/onchain.md`, which come from `--gas-report --isolate`.
    ///      An earlier version used `vm.lastCallGas().gasTotalUsed`. That
    ///      cheatcode changed accounting between forge 1.7 and 1.8 — the same
    ///      unchanged call measured 111,522 on one and 175,142 on the other —
    ///      which silently moved the ceilings below and broke CI. A ceiling is
    ///      only meaningful in a unit that the toolchain cannot redefine.
    function _gasOf(SkyRelayBeacon.SkyRelayAttestation memory a, uint256 pk) internal returns (uint256 gasUsed) {
        bytes[] memory sigs = _one(_sign(pk, a));
        SkyRelayBeacon.SkyRelayAttestation[] memory atts = _one(a);
        vm.prank(a.operator);
        uint256 before = gasleft();
        beacon.verifyAndRecord(atts, sigs);
        gasUsed = before - gasleft();
    }

    function _gasOfQuorum(SkyRelayBeacon.SkyRelayAttestation[] memory atts, uint256[3] memory pks)
        internal
        returns (uint256 gasUsed)
    {
        bytes[] memory sigs = new bytes[](atts.length);
        for (uint256 i = 0; i < atts.length; i++) {
            sigs[i] = _sign(pks[i], atts[i]);
        }
        vm.prank(atts[0].operator);
        uint256 before = gasleft();
        beacon.verifyAndRecord(atts, sigs);
        gasUsed = before - gasleft();
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

    /// @dev `_gasOf` on 2026-09-21, forge 1.7.1, measured 113_285. This sits
    ///      12_715 above it. Raising it means accepting that number.
    uint256 internal constant WARM_SINGLE_CEILING = 126_000;

    /// @dev Opening a day writes `beaconsByDay` from zero (a cold SSTORE).
    ///      The next sighting that day updates the slot and must cost
    ///      materially less — a fresh slot on the warm path closes the gap.
    function test_secondBeaconSameDayIsCheaper() public {
        uint64 ts = uint64(block.timestamp);
        SkyRelayBeacon.SkyRelayAttestation memory first = _att(opA);
        first.timestamp = ts;
        first.telemetryHash = keccak256("sighting-1");
        SkyRelayBeacon.SkyRelayAttestation memory second = _att(opA);
        second.timestamp = ts;
        second.telemetryHash = keccak256("sighting-2");

        uint256 cold = _gasOf(first, PK_A);
        uint256 warm = _gasOf(second, PK_A);

        assertEq(beacon.beaconsByDay(opA, uint32(ts / 86400)), 2);
        // A delta between two runs of the same build is blind to a cost both
        // runs pay, so the ceiling is the part that catches regressions and the
        // delta only proves the warm path is warm.
        assertLt(warm, cold - 60_000, "warm path is not actually warmer");
        assertLt(warm, WARM_SINGLE_CEILING, "warm-path cost regressed");
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

    /// @dev `_gasOfQuorum` on 2026-09-21, forge 1.7.1, measured 194_843. This
    ///      sits 13_157 above it. Raising it means accepting that number.
    uint256 internal constant WARM_QUORUM3_CEILING = 208_000;

    /// @dev Same split as `test_secondBeaconSameDayIsCheaper`, for a full quorum.
    function test_secondQuorumOfThreeSameDayIsCheaper() public {
        _enableQuorumOfTwo();
        vm.prank(owner);
        beacon.setQuorumThreshold(3);

        uint64 ts = uint64(block.timestamp);
        SkyRelayBeacon.SkyRelayAttestation[] memory first = _triple();
        SkyRelayBeacon.SkyRelayAttestation[] memory second = _triple();
        for (uint256 i = 0; i < 3; i++) {
            first[i].timestamp = ts;
            second[i].timestamp = ts;
            second[i].telemetryHash = keccak256(abi.encodePacked("sighting-2", second[i].operator));
        }

        uint256 cold = _gasOfQuorum(first, [PK_A, PK_B, PK_C]);
        uint256 warm = _gasOfQuorum(second, [PK_A, PK_B, PK_C]);

        assertEq(beacon.beaconsByDay(opA, uint32(ts / 86400)), 2);
        // A delta between two runs of the same build is blind to a cost both
        // runs pay, so the ceiling is the part that catches regressions and the
        // delta only proves the warm path is warm.
        assertLt(warm, cold - 60_000, "warm path is not actually warmer");
        assertLt(warm, WARM_QUORUM3_CEILING, "warm-path cost regressed");
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
