// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";
import {CatalogRegistry} from "../src/CatalogRegistry.sol";

contract Vault {
    receive() external payable {}
}

contract SkyRelayBondTest is Test {
    uint256 internal constant PK_A = 0xA11CE;
    uint256 internal constant PK_B = 0xB0B;
    uint256 internal constant PK_C = 0xC0FFEE;
    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant UNBONDING_PERIOD = 7 days;
    uint16 internal constant REPORTER_BOUNTY_BPS = 1000;

    address internal owner = makeAddr("owner");
    address internal opA = makeAddr("opA");
    address internal opB = makeAddr("opB");
    address internal opC = makeAddr("opC");
    address internal attesterA;
    address internal attesterB;
    address internal attesterC;

    Vault internal vault;
    CatalogRegistry internal catalog;
    SkyRelayBond internal bonds;
    SkyRelayBeacon internal beacon;

    bytes32 internal constant CATALOG = keccak256("catalog-2026-263");

    function setUp() public {
        attesterA = vm.addr(PK_A);
        attesterB = vm.addr(PK_B);
        attesterC = vm.addr(PK_C);

        vault = new Vault();
        catalog = new CatalogRegistry(owner);
        uint64 nonce = vm.getNonce(address(this));
        address predictedBeacon = vm.computeCreateAddress(address(this), nonce + 1);
        bonds = new SkyRelayBond(MIN_BOND, UNBONDING_PERIOD, REPORTER_BOUNTY_BPS, address(vault), predictedBeacon);
        beacon = new SkyRelayBeacon(owner, attesterA, address(vault), address(catalog), address(bonds));
        assertEq(address(beacon), predictedBeacon);
        assertEq(address(bonds.beacon()), address(beacon));

        vm.warp(1_789_918_203);

        vm.prank(owner);
        catalog.register(CATALOG, "gnfd://skyrelay-catalog/test.tle");

        vm.deal(attesterA, 10 ether);
        vm.prank(attesterA);
        bonds.bond{value: MIN_BOND}();
    }

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

    function _admitAndBond(uint256 pk) internal {
        address who = vm.addr(pk);
        vm.prank(owner);
        beacon.scheduleAttester(who);
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(who);
        vm.deal(who, 10 ether);
        vm.prank(who);
        bonds.bond{value: MIN_BOND}();
    }

    // ── bonding / unbonding ─────────────────────────────────────────────────

    function test_bondActivatesAtMinBond() public view {
        assertTrue(bonds.isActive(attesterA));
        assertEq(bonds.bonded(attesterA), MIN_BOND);
    }

    function test_bondBelowMinBondReverts() public {
        vm.deal(attesterB, 10 ether);
        vm.prank(attesterB);
        vm.expectRevert(SkyRelayBond.BelowMinBond.selector);
        bonds.bond{value: MIN_BOND - 1}();
        assertFalse(bonds.isActive(attesterB));
    }

    function test_requestUnbondDeactivatesImmediately() public {
        assertTrue(bonds.isActive(attesterA));
        vm.prank(attesterA);
        bonds.requestUnbond();
        assertFalse(bonds.isActive(attesterA), "must deactivate in the same transaction");
        assertEq(bonds.unbondingAt(attesterA), uint64(block.timestamp));
        assertEq(bonds.bonded(attesterA), MIN_BOND, "funds stay locked");
    }

    function test_withdrawWaitsOutTheUnbondingPeriod() public {
        uint256 before = attesterA.balance;
        vm.prank(attesterA);
        bonds.requestUnbond();

        vm.prank(attesterA);
        vm.expectRevert(SkyRelayBond.TooEarly.selector);
        bonds.withdraw();

        vm.warp(block.timestamp + UNBONDING_PERIOD);
        vm.prank(attesterA);
        bonds.withdraw();
        assertEq(attesterA.balance, before + MIN_BOND);
        assertEq(bonds.bonded(attesterA), 0);
        assertEq(bonds.unbondingAt(attesterA), 0);
        assertFalse(bonds.isActive(attesterA));
    }

    function test_cannotBondWhileUnbonding() public {
        vm.prank(attesterA);
        bonds.requestUnbond();
        vm.prank(attesterA);
        vm.expectRevert(SkyRelayBond.Unbonding.selector);
        bonds.bond{value: 1 ether}();
    }

    // ── equivocation ────────────────────────────────────────────────────────

    function test_genuineEquivocationSlashesPaysAndEjects() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        SkyRelayBeacon.SkyRelayAttestation memory b = _att(opA);
        b.elevationMilliDeg = 12_000;
        bytes memory sigA = _sign(PK_A, a);
        bytes memory sigB = _sign(PK_A, b);
        bytes32 digestA = beacon.hashAttestation(a, block.chainid, address(beacon));
        bytes32 digestB = beacon.hashAttestation(b, block.chainid, address(beacon));

        address reporter = makeAddr("reporter");
        uint256 bounty = MIN_BOND * REPORTER_BOUNTY_BPS / 10_000;
        uint256 toVault = MIN_BOND - bounty;
        uint256 vaultBefore = address(vault).balance;

        vm.prank(reporter);
        vm.expectEmit(true, true, false, true, address(bonds));
        emit SkyRelayBond.Equivocation(attesterA, reporter, digestA, digestB, MIN_BOND);
        bonds.slashEquivocation(a, sigA, b, sigB);

        assertEq(reporter.balance, bounty);
        assertEq(address(vault).balance, vaultBefore + toVault);
        assertEq(bonds.bonded(attesterA), 0);
        assertTrue(bonds.slashed(attesterA));
        assertFalse(bonds.isActive(attesterA));

        // permanently ineligible: cannot re-bond, cannot attest
        vm.prank(attesterA);
        vm.expectRevert(SkyRelayBond.Slashed.selector);
        bonds.bond{value: MIN_BOND}();

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sigA;
        SkyRelayBeacon.SkyRelayAttestation[] memory atts = new SkyRelayBeacon.SkyRelayAttestation[](1);
        atts[0] = a;
        vm.prank(opA);
        vm.expectRevert(SkyRelayBeacon.NotBonded.selector);
        beacon.verifyAndRecord(atts, sigs);
    }

    /// @dev Several stations at one instant is a quorum, not equivocation.
    ///      Same noradId, same timestamp, different operators — even if the
    ///      same key signed every member, that is not "two stories about one
    ///      station-second". Getting this wrong would slash honest members.
    function test_quorumOfThreeStationsAtOneInstantDoesNotSlash() public {
        _admitAndBond(PK_B);
        _admitAndBond(PK_C);

        SkyRelayBeacon.SkyRelayAttestation[] memory atts = new SkyRelayBeacon.SkyRelayAttestation[](3);
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

        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);
        sigs[2] = _sign(PK_C, atts[2]);

        vm.expectRevert(SkyRelayBond.NotEquivocation.selector);
        bonds.slashEquivocation(atts[0], sigs[0], atts[1], sigs[1]);
        vm.expectRevert(SkyRelayBond.NotEquivocation.selector);
        bonds.slashEquivocation(atts[0], sigs[0], atts[2], sigs[2]);
        vm.expectRevert(SkyRelayBond.NotEquivocation.selector);
        bonds.slashEquivocation(atts[1], sigs[1], atts[2], sigs[2]);

        // the same attester signing two operators at one instant is still a
        // quorum-shaped pair, not a self-contradiction about one station
        bytes memory sameKeyOpB = _sign(PK_A, atts[1]);
        vm.expectRevert(SkyRelayBond.NotEquivocation.selector);
        bonds.slashEquivocation(atts[0], sigs[0], atts[1], sameKeyOpB);

        assertTrue(bonds.isActive(attesterA));
        assertEq(bonds.bonded(attesterA), MIN_BOND);
        assertTrue(bonds.isActive(attesterB));
        assertTrue(bonds.isActive(attesterC));
    }

    function test_sameEquivocationCannotBeReportedTwice() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        SkyRelayBeacon.SkyRelayAttestation memory b = _att(opA);
        b.dopplerHz = 1;
        bytes memory sigA = _sign(PK_A, a);
        bytes memory sigB = _sign(PK_A, b);

        address reporter = makeAddr("reporter");
        vm.prank(reporter);
        bonds.slashEquivocation(a, sigA, b, sigB);

        vm.prank(makeAddr("secondReporter"));
        vm.expectRevert(SkyRelayBond.AlreadyProven.selector);
        bonds.slashEquivocation(a, sigA, b, sigB);

        // swapped order is the same pair
        vm.prank(makeAddr("thirdReporter"));
        vm.expectRevert(SkyRelayBond.AlreadyProven.selector);
        bonds.slashEquivocation(b, sigB, a, sigA);
    }

    function test_equivocationFromDifferentAttestersReverts() public {
        _admitAndBond(PK_B);
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        SkyRelayBeacon.SkyRelayAttestation memory b = _att(opA);
        b.elevationMilliDeg = 12_000;
        bytes memory sigA = _sign(PK_A, a);
        bytes memory sigB = _sign(PK_B, b);

        vm.expectRevert(SkyRelayBond.DistinctSigners.selector);
        bonds.slashEquivocation(a, sigA, b, sigB);
    }

    function test_slashDuringUnbondingStillTakesTheBond() public {
        vm.prank(attesterA);
        bonds.requestUnbond();
        assertFalse(bonds.isActive(attesterA));

        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        SkyRelayBeacon.SkyRelayAttestation memory b = _att(opA);
        b.snrMilliDb = 1;
        bytes memory sigA = _sign(PK_A, a);
        bytes memory sigB = _sign(PK_A, b);
        address reporter = makeAddr("reporter");
        vm.prank(reporter);
        bonds.slashEquivocation(a, sigA, b, sigB);

        assertEq(bonds.bonded(attesterA), 0);
        assertTrue(bonds.slashed(attesterA));
        vm.warp(block.timestamp + UNBONDING_PERIOD);
        vm.prank(attesterA);
        vm.expectRevert(SkyRelayBond.NotUnbonding.selector);
        bonds.withdraw();
    }
}
