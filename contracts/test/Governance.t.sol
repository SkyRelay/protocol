// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";

contract VaultMock {
    receive() external payable {}
}

/// @title Governance of the attester set
/// @notice One invariant runs through every test here: **expansions of signing
///         power are timelocked, contractions take effect immediately**. Adding
///         an attester or lowering the quorum lets more signatures through, so
///         both wait out ROTATION_DELAY and are observable on chain first.
///         Removing an attester or raising the quorum only ever lets fewer
///         through, so both are immediate — an operator discovering a
///         compromised key must not have to wait two days to revoke it.
contract GovernanceTest is Test {
    SkyRelayBeacon internal beacon;
    address internal owner = makeAddr("owner");
    address internal attesterA = makeAddr("attesterA");
    address internal attesterB = makeAddr("attesterB");
    VaultMock internal vault;

    function setUp() public {
        vault = new VaultMock();
        vm.prank(owner);
        beacon = new SkyRelayBeacon(owner, attesterA, address(vault));
    }

    function test_seedsOneAttesterWithThresholdOne() public view {
        assertTrue(beacon.isAttester(attesterA));
        assertEq(beacon.attesterCount(), 1);
        assertEq(beacon.quorumThreshold(), 1);
        assertEq(beacon.owner(), owner);
        assertFalse(beacon.paused());
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(SkyRelayBeacon.ZeroAddress.selector);
        new SkyRelayBeacon(address(0), attesterA, address(vault));
        vm.expectRevert(SkyRelayBeacon.ZeroAddress.selector);
        new SkyRelayBeacon(owner, address(0), address(vault));
        vm.expectRevert(SkyRelayBeacon.ZeroAddress.selector);
        new SkyRelayBeacon(owner, attesterA, address(0));
    }

    // ── adding an attester is an expansion: timelocked ──────────────────────

    function test_addingAnAttesterWaitsOutTheDelay() public {
        vm.prank(owner);
        beacon.scheduleAttester(attesterB);
        assertFalse(beacon.isAttester(attesterB), "must not be live on scheduling");

        vm.expectRevert(SkyRelayBeacon.TooEarly.selector);
        beacon.activateAttester(attesterB);

        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(attesterB);
        assertTrue(beacon.isAttester(attesterB));
        assertEq(beacon.attesterCount(), 2);
    }

    function test_activatingSomethingNeverScheduledReverts() public {
        vm.expectRevert(SkyRelayBeacon.NotScheduled.selector);
        beacon.activateAttester(attesterB);
    }

    function test_ownerCanCancelAScheduledAttester() public {
        vm.startPrank(owner);
        beacon.scheduleAttester(attesterB);
        beacon.cancelAttester(attesterB);
        vm.stopPrank();
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        vm.expectRevert(SkyRelayBeacon.NotScheduled.selector);
        beacon.activateAttester(attesterB);
    }

    // ── removing an attester is a contraction: immediate ────────────────────

    function test_removingAnAttesterIsImmediate() public {
        vm.prank(owner);
        beacon.scheduleAttester(attesterB);
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(attesterB);

        vm.prank(owner);
        beacon.removeAttester(attesterB);
        assertFalse(beacon.isAttester(attesterB));
        assertEq(beacon.attesterCount(), 1);
    }

    function test_cannotRemoveBelowTheQuorumThreshold() public {
        vm.prank(owner);
        vm.expectRevert(SkyRelayBeacon.ThresholdUnreachable.selector);
        beacon.removeAttester(attesterA);
    }

    // ── quorum threshold, same asymmetry ────────────────────────────────────

    function test_raisingTheQuorumIsImmediate() public {
        vm.prank(owner);
        beacon.scheduleAttester(attesterB);
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(attesterB);

        vm.prank(owner);
        beacon.setQuorumThreshold(2);
        assertEq(beacon.quorumThreshold(), 2);
    }

    function test_loweringTheQuorumWaitsOutTheDelay() public {
        vm.prank(owner);
        beacon.scheduleAttester(attesterB);
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(attesterB);
        vm.prank(owner);
        beacon.setQuorumThreshold(2);

        vm.prank(owner);
        beacon.setQuorumThreshold(1);
        assertEq(beacon.quorumThreshold(), 2, "must not drop immediately");

        vm.expectRevert(SkyRelayBeacon.TooEarly.selector);
        beacon.activateQuorumThreshold();

        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateQuorumThreshold();
        assertEq(beacon.quorumThreshold(), 1);
    }

    function test_quorumCannotExceedTheAttesterSetOrBeZero() public {
        vm.startPrank(owner);
        vm.expectRevert(SkyRelayBeacon.ThresholdUnreachable.selector);
        beacon.setQuorumThreshold(2);
        vm.expectRevert(SkyRelayBeacon.ThresholdUnreachable.selector);
        beacon.setQuorumThreshold(0);
        vm.stopPrank();
    }

    // ── pause ───────────────────────────────────────────────────────────────

    function test_ownerCanPauseAndUnpause() public {
        vm.prank(owner);
        beacon.pause();
        assertTrue(beacon.paused());
        vm.prank(owner);
        beacon.unpause();
        assertFalse(beacon.paused());
    }

    // ── ownership is two-step ───────────────────────────────────────────────

    function test_ownershipTransferIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        beacon.transferOwnership(next);
        assertEq(beacon.owner(), owner, "must not move on the first step");
        assertEq(beacon.pendingOwner(), next);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(SkyRelayBeacon.NotPendingOwner.selector);
        beacon.acceptOwnership();

        vm.prank(next);
        beacon.acceptOwnership();
        assertEq(beacon.owner(), next);
        assertEq(beacon.pendingOwner(), address(0));
    }

    // ── every privileged entry point is gated ───────────────────────────────

    function test_strangersCannotGovern() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(SkyRelayBeacon.NotOwner.selector);
        beacon.scheduleAttester(attesterB);
        vm.expectRevert(SkyRelayBeacon.NotOwner.selector);
        beacon.cancelAttester(attesterB);
        vm.expectRevert(SkyRelayBeacon.NotOwner.selector);
        beacon.removeAttester(attesterA);
        vm.expectRevert(SkyRelayBeacon.NotOwner.selector);
        beacon.setQuorumThreshold(1);
        vm.expectRevert(SkyRelayBeacon.NotOwner.selector);
        beacon.pause();
        vm.expectRevert(SkyRelayBeacon.NotOwner.selector);
        beacon.transferOwnership(address(1));
        vm.stopPrank();
    }
}
