// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";

contract VaultMock {
    receive() external payable {}
}

contract SkyRelayBeaconTest is Test {
    uint256 internal constant ATTESTER_PK = 0xA11CE;
    address internal attester;
    VaultMock internal vault;
    SkyRelayBeacon internal beacon;

    function setUp() public {
        attester = vm.addr(ATTESTER_PK);
        vault = new VaultMock();
        beacon = new SkyRelayBeacon(attester, address(vault));
        vm.warp(1_726_834_083); // 2026-09-20T10:48:03Z
    }

    function _att() internal view returns (SkyRelayBeacon.SkyRelayAttestation memory a) {
        a.operator = address(this);
        a.telemetryHash = keccak256("connected-001");
        a.noradId = 44714;
        a.elevationMilliDeg = 54_180;
        a.dopplerHz = -182_000;
        a.snrMilliDb = 8700;
        a.asn = 14593;
        a.timestamp = uint64(block.timestamp);
    }

    function _sign(SkyRelayBeacon.SkyRelayAttestation memory a) internal view returns (bytes memory) {
        bytes32 digest = beacon.hashAttestation(a, block.chainid, address(beacon));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_recordsBeaconAndEnergy() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        uint256 id = beacon.verifyAndRecord(a, _sign(a));
        assertEq(id, 1);
        assertEq(beacon.totalBeacons(), 1);
        assertEq(beacon.totalEnergy(), 8700);
        assertEq(beacon.userBeaconCount(address(this)), 1);
    }

    function test_forwardsValueToVault() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        beacon.verifyAndRecord{value: 0.05 ether}(a, _sign(a));
        assertEq(address(vault).balance, 0.05 ether);
    }

    function test_rejectsBadAsn() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.asn = 15169;
        bytes memory sig = _sign(a);
        vm.expectRevert(SkyRelayBeacon.BadAsn.selector);
        beacon.verifyAndRecord(a, sig);
    }

    function test_acceptsIndonesiaAsn() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.asn = 45700;
        uint256 id = beacon.verifyAndRecord(a, _sign(a));
        assertEq(id, 1);
    }

    function test_rejectsBelowHorizon() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.elevationMilliDeg = 0;
        bytes memory sig = _sign(a);
        vm.expectRevert(SkyRelayBeacon.BelowHorizon.selector);
        beacon.verifyAndRecord(a, sig);
    }

    function test_rejectsExpired() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.timestamp = uint64(block.timestamp - 121);
        bytes memory sig = _sign(a);
        vm.expectRevert(SkyRelayBeacon.Expired.selector);
        beacon.verifyAndRecord(a, sig);
    }

    function test_rejectsFuture() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.timestamp = uint64(block.timestamp + 31);
        bytes memory sig = _sign(a);
        vm.expectRevert(SkyRelayBeacon.Future.selector);
        beacon.verifyAndRecord(a, sig);
    }

    function test_rejectsReplay() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        bytes memory sig = _sign(a);
        beacon.verifyAndRecord(a, sig);
        vm.expectRevert(SkyRelayBeacon.Replay.selector);
        beacon.verifyAndRecord(a, sig);
    }

    function test_rejectsWrongSigner() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        bytes32 digest = beacon.hashAttestation(a, block.chainid, address(beacon));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest);
        vm.expectRevert(SkyRelayBeacon.BadSigner.selector);
        beacon.verifyAndRecord(a, abi.encodePacked(r, s, v));
    }

    function test_hashIsDomainBound() public view {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        bytes32 d0 = beacon.hashAttestation(a, 97, address(beacon));
        bytes32 d1 = beacon.hashAttestation(a, 56, address(beacon));
        assertTrue(d0 != d1);
    }

    function testFuzz_timestampInsideWindow(uint64 skew) public {
        skew = uint64(bound(skew, 0, 120));
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.timestamp = uint64(block.timestamp) - skew;
        uint256 id = beacon.verifyAndRecord(a, _sign(a));
        assertEq(id, 1);
    }

    function testFuzz_snrAccumulates(uint32 snrA, uint32 snrB) public {
        snrA = uint32(bound(snrA, 1, 50_000));
        snrB = uint32(bound(snrB, 1, 50_000));
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.snrMilliDb = snrA;
        beacon.verifyAndRecord(a, _sign(a));
        a.snrMilliDb = snrB;
        a.telemetryHash = keccak256(abi.encode(snrB));
        beacon.verifyAndRecord(a, _sign(a));
        assertEq(beacon.totalEnergy(), uint256(snrA) + snrB);
        assertEq(beacon.totalBeacons(), 2);
    }

    function test_rejectsOperatorMismatch() public {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.operator = address(0xBEEF);
        bytes memory sig = _sign(a);
        vm.expectRevert(SkyRelayBeacon.WrongOperator.selector);
        beacon.verifyAndRecord(a, sig);
    }

    /// @dev The attestation commits to the operator, so an observer who copies a
    ///      signed attestation out of the mempool cannot have the beacon credited
    ///      to itself, and cannot grief the rightful submitter by burning the digest.
    function test_frontRunnerCannotStealABeacon() public {
        address operator = makeAddr("operator");
        address frontRunner = makeAddr("frontRunner");
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        a.operator = operator;
        bytes memory sig = _sign(a);

        vm.prank(frontRunner);
        vm.expectRevert(SkyRelayBeacon.WrongOperator.selector);
        beacon.verifyAndRecord(a, sig);

        vm.prank(operator);
        uint256 id = beacon.verifyAndRecord(a, sig);
        assertEq(id, 1);
        assertEq(beacon.userBeaconCount(operator), 1);
        assertEq(beacon.userBeaconCount(frontRunner), 0);
    }

    function test_digestIsOperatorBound() public view {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att();
        bytes32 d0 = beacon.hashAttestation(a, block.chainid, address(beacon));
        a.operator = address(0xBEEF);
        bytes32 d1 = beacon.hashAttestation(a, block.chainid, address(beacon));
        assertTrue(d0 != d1);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(SkyRelayBeacon.ZeroAddress.selector);
        new SkyRelayBeacon(address(0), address(vault));
        vm.expectRevert(SkyRelayBeacon.ZeroAddress.selector);
        new SkyRelayBeacon(attester, address(0));
    }
}
