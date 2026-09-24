// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrbitalVesting} from "../src/OrbitalVesting.sol";
import {ISkyRelay} from "../src/interfaces/ISkyRelay.sol";

contract MockVestingToken {
    string public name = "Meme Dev Token";
    string public symbol = "MEME";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor() {}

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockSkyRelayForVesting is ISkyRelay {
    mapping(uint256 => BeaconSummary) internal _beacons;
    uint256 public totalBeacons;

    function recordMock(uint256 id, uint32 noradId, uint64 ts) external {
        _beacons[id] = BeaconSummary({
            noradId: noradId,
            timestamp: ts,
            quorum: 3,
            catalogHash: keccak256("CAT"),
            signersHash: keccak256("SIG")
        });
        if (id >= totalBeacons) totalBeacons = id + 1;
    }

    function getBeacon(uint256 beaconId) external view returns (BeaconSummary memory) {
        return _beacons[beaconId];
    }

    function beaconCountInWindow(address, uint64, uint64) external pure returns (uint256) {
        return 0;
    }

    function wasClaimedSpaceRelayed(bytes32, uint256, bytes32[] calldata)
        external
        pure
        returns (bool, address, uint64, uint32)
    {
        return (false, address(0), 0, 0);
    }
}

contract OrbitalVestingTest is Test {
    MockVestingToken internal token;
    MockSkyRelayForVesting internal skyRelay;
    OrbitalVesting internal vesting;

    address internal dev = makeAddr("devBeneficiary");
    uint256 internal constant TOTAL_ALLOCATION = 100_000 ether;
    uint256 internal constant REQUIRED_PASSES = 10; // 10 orbital passes for 100% unlock
    uint64 internal constant ORBIT_PERIOD_SEC = 5400; // ~90 minutes per LEO pass

    uint64 internal startTs;

    function setUp() public {
        token = new MockVestingToken();
        skyRelay = new MockSkyRelayForVesting();
        startTs = uint64(block.timestamp);

        vesting = new OrbitalVesting(
            address(skyRelay),
            address(token),
            dev,
            TOTAL_ALLOCATION,
            REQUIRED_PASSES,
            ORBIT_PERIOD_SEC,
            startTs
        );

        // Fund vesting vault
        token.mint(address(vesting), TOTAL_ALLOCATION);
    }

    function test_initialStateZeroVested() public view {
        assertEq(vesting.totalAllocation(), TOTAL_ALLOCATION);
        assertEq(vesting.totalPassesRequired(), REQUIRED_PASSES);
        assertEq(vesting.beneficiary(), dev);
        assertEq(vesting.minPassIntervalSec(), ORBIT_PERIOD_SEC);

        // Zero passes recorded
        assertEq(vesting.vestedAmount(), 0);
        assertEq(vesting.claimableAmount(), 0);
    }

    function test_advancePassEnforcesInterval() public {
        // Beacon 1 recorded at startTs + 10s
        skyRelay.recordMock(1, 47352, startTs + 10);
        vesting.advancePass(1);

        assertEq(vesting.passesCounted(), 1);
        assertEq(vesting.vestedAmount(), 10_000 ether); // 1/10 = 10%

        // Attempt Beacon 2 only 60 seconds later (in the same orbit!)
        skyRelay.recordMock(2, 47353, startTs + 70);

        // MUST revert with PassIntervalNotElapsed (protects against flood/spam)
        vm.expectRevert(
            abi.encodeWithSelector(
                OrbitalVesting.PassIntervalNotElapsed.selector,
                60, // elapsedSec
                ORBIT_PERIOD_SEC // requiredSec
            )
        );
        vesting.advancePass(2);

        // Pass count remains strictly 1
        assertEq(vesting.passesCounted(), 1);
    }

    function test_cannotAccelerateVestingByFloodingBeaconsInSameOrbit() public {
        skyRelay.recordMock(1, 47352, startTs + 100);
        vesting.advancePass(1);

        // Attester / dev tries to flood 10 beacons across 10 visible satellites within 10 minutes
        for (uint256 i = 2; i <= 10; i++) {
            skyRelay.recordMock(i, uint32(47350 + i), startTs + 100 + uint64(i * 10));
            vm.expectRevert();
            vesting.advancePass(i);
        }

        // Clock cannot be accelerated: exactly 1 pass counted
        assertEq(vesting.passesCounted(), 1);
        assertEq(vesting.vestedAmount(), 10_000 ether);
    }

    function test_vestingProgressesWithGenuineOrbitPasses() public {
        // 3 genuine orbital passes spaced by >= 5400s
        for (uint256 i = 1; i <= 3; i++) {
            uint64 passTime = startTs + uint64(i * ORBIT_PERIOD_SEC);
            skyRelay.recordMock(i, 47352, passTime);
            vesting.advancePass(i);
        }

        // 3/10 passes = 30,000 ether
        assertEq(vesting.passesCounted(), 3);
        assertEq(vesting.vestedAmount(), 30_000 ether);
        assertEq(vesting.claimableAmount(), 30_000 ether);

        // Claim
        vesting.claim();
        assertEq(token.balanceOf(dev), 30_000 ether);
        assertEq(vesting.totalClaimed(), 30_000 ether);
        assertEq(vesting.claimableAmount(), 0);
    }

    function test_revertIfNothingToClaim() public {
        vm.expectRevert(OrbitalVesting.NothingToClaim.selector);
        vesting.claim();
    }
}
