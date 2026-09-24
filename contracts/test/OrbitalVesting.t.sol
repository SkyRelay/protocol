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
    mapping(address => uint256) public mockCounts;

    function setMockCount(address operator, uint256 count) external {
        mockCounts[operator] = count;
    }

    function totalBeacons() external pure returns (uint256) {
        return 100;
    }

    function getBeacon(uint256) external pure returns (BeaconSummary memory) {
        return BeaconSummary(47352, 1000, 3, bytes32(0), bytes32(0));
    }

    function beaconCountInWindow(address operator, uint64, uint64) external view returns (uint256) {
        return mockCounts[operator];
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
    address internal stationOperator = makeAddr("stationOperator");
    uint256 internal constant TOTAL_ALLOCATION = 100_000 ether;
    uint256 internal constant REQUIRED_PASSES = 10; // 10 orbital passes for 100% unlock

    function setUp() public {
        token = new MockVestingToken();
        skyRelay = new MockSkyRelayForVesting();

        vesting = new OrbitalVesting(
            address(skyRelay),
            address(token),
            dev,
            stationOperator,
            TOTAL_ALLOCATION,
            REQUIRED_PASSES,
            uint64(block.timestamp)
        );

        // Fund vesting vault
        token.mint(address(vesting), TOTAL_ALLOCATION);
    }

    function test_initialStateZeroVested() public {
        assertEq(vesting.totalAllocation(), TOTAL_ALLOCATION);
        assertEq(vesting.totalPassesRequired(), REQUIRED_PASSES);
        assertEq(vesting.beneficiary(), dev);
        assertEq(vesting.attesterOperator(), stationOperator);

        // Zero passes recorded
        assertEq(vesting.vestedAmount(), 0);
        assertEq(vesting.claimableAmount(), 0);
    }

    function test_partialVestingAfterThreePasses() public {
        // Advance time and record 3 passes
        vm.warp(block.timestamp + 3 days);
        skyRelay.setMockCount(stationOperator, 3);

        // 3/10 passes = 30% of 100,000 ether = 30,000 ether
        assertEq(vesting.vestedAmount(), 30_000 ether);
        assertEq(vesting.claimableAmount(), 30_000 ether);

        // Dev claims partial allocation
        vesting.claim();

        assertEq(token.balanceOf(dev), 30_000 ether);
        assertEq(vesting.totalClaimed(), 30_000 ether);
        assertEq(vesting.claimableAmount(), 0);
    }

    function test_fullVestingWhenPassTargetReached() public {
        vm.warp(block.timestamp + 10 days);
        skyRelay.setMockCount(stationOperator, 10);

        // 100% unlocked
        assertEq(vesting.vestedAmount(), TOTAL_ALLOCATION);
        assertEq(vesting.claimableAmount(), TOTAL_ALLOCATION);

        vesting.claim();
        assertEq(token.balanceOf(dev), TOTAL_ALLOCATION);
        assertEq(vesting.totalClaimed(), TOTAL_ALLOCATION);
    }

    function test_overshootPassCountCapsAtTotal() public {
        vm.warp(block.timestamp + 20 days);
        skyRelay.setMockCount(stationOperator, 15); // Exceeds 10

        assertEq(vesting.vestedAmount(), TOTAL_ALLOCATION);
        assertEq(vesting.claimableAmount(), TOTAL_ALLOCATION);
    }

    function test_revertIfNothingToClaim() public {
        vm.expectRevert(OrbitalVesting.NothingToClaim.selector);
        vesting.claim();
    }
}
