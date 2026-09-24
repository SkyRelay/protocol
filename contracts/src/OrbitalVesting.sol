// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISkyRelay} from "./interfaces/ISkyRelay.sol";

interface IERC20Transferable {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title OrbitalVesting
/// @notice External-Clock Token Vesting Vault powered by SkyRelay Orbital Passes.
/// @dev Dev and team allocations unlock strictly in proportion to cumulative verifiable
///      orbital sightings recorded by bonded SkyRelay ground stations.
///      Unlike traditional block.timestamp timelocks, this vesting schedule cannot be
///      accelerated by miners, dev private keys, or chain re-orgs.
contract OrbitalVesting {
    ISkyRelay public immutable skyRelay;
    IERC20Transferable public immutable token;
    address public immutable beneficiary;

    uint64 public immutable startTimestamp;
    uint64 public immutable minPassIntervalSec; // e.g. 5400 seconds (~90 mins per LEO orbit)
    uint256 public immutable totalAllocation;
    uint256 public immutable totalPassesRequired;

    uint256 public passesCounted;
    uint64 public lastCountedTimestamp;
    uint256 public totalClaimed;

    event VestingInitialized(
        address indexed token,
        address indexed beneficiary,
        uint256 totalAllocation,
        uint256 totalPassesRequired,
        uint64 minPassIntervalSec,
        uint64 startTimestamp
    );

    event OrbitalPassAdvanced(
        uint256 indexed beaconId,
        uint32 noradId,
        uint64 sightingTimestamp,
        uint256 newPassCount
    );

    event TokensClaimed(
        address indexed beneficiary,
        uint256 amountClaimed,
        uint256 totalClaimedSoFar,
        uint256 currentPassCount
    );

    error ZeroAddress();
    error ZeroAmount();
    error InvalidPassRequirement();
    error InvalidBeacon();
    error PassIntervalNotElapsed(uint64 elapsedSec, uint64 requiredSec);
    error BeaconPrecedesStart(uint64 beaconTs, uint64 startTs);
    error SightingTooOld(uint64 beaconTs, uint64 lastCountedTs);
    error NothingToClaim();
    error TransferFailed();

    constructor(
        address skyRelayAddress,
        address tokenAddress,
        address beneficiaryAddress,
        uint256 allocationAmount,
        uint256 passesRequired,
        uint64 passIntervalSec,
        uint64 startTs
    ) {
        if (skyRelayAddress == address(0)) revert ZeroAddress();
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (beneficiaryAddress == address(0)) revert ZeroAddress();
        if (allocationAmount == 0) revert ZeroAmount();
        if (passesRequired == 0) revert InvalidPassRequirement();

        skyRelay = ISkyRelay(skyRelayAddress);
        token = IERC20Transferable(tokenAddress);
        beneficiary = beneficiaryAddress;
        totalAllocation = allocationAmount;
        totalPassesRequired = passesRequired;
        minPassIntervalSec = passIntervalSec == 0 ? 5400 : passIntervalSec; // Default 90 min LEO orbit
        startTimestamp = startTs == 0 ? uint64(block.timestamp) : startTs;

        emit VestingInitialized(
            tokenAddress,
            beneficiaryAddress,
            allocationAmount,
            passesRequired,
            minPassIntervalSec,
            startTimestamp
        );
    }

    /// @notice Register a newly verified orbital beacon to advance the vesting clock.
    /// @dev Prevents spamming: even if an attester floods 100 beacons simultaneously,
    ///      only one beacon can be registered per minPassIntervalSec (~90 min).
    function advancePass(uint256 beaconId) public {
        ISkyRelay.BeaconSummary memory summary = skyRelay.getBeacon(beaconId);
        if (summary.timestamp == 0) revert InvalidBeacon();
        if (summary.timestamp < startTimestamp) revert BeaconPrecedesStart(summary.timestamp, startTimestamp);

        if (passesCounted == 0) {
            lastCountedTimestamp = summary.timestamp;
            passesCounted = 1;
        } else {
            if (summary.timestamp <= lastCountedTimestamp) revert SightingTooOld(summary.timestamp, lastCountedTimestamp);
            uint64 elapsed = summary.timestamp - lastCountedTimestamp;
            if (elapsed < minPassIntervalSec) {
                revert PassIntervalNotElapsed(elapsed, minPassIntervalSec);
            }
            lastCountedTimestamp = summary.timestamp;
            passesCounted += 1;
        }

        emit OrbitalPassAdvanced(beaconId, summary.noradId, summary.timestamp, passesCounted);
    }

    /// @notice Computes the total cumulative vested tokens unlocked by recorded orbital passes.
    function vestedAmount() public view returns (uint256) {
        if (passesCounted >= totalPassesRequired) {
            return totalAllocation;
        }
        return (totalAllocation * passesCounted) / totalPassesRequired;
    }

    /// @notice Computes the claimable tokens currently available for withdrawal.
    function claimableAmount() public view returns (uint256) {
        uint256 vested = vestedAmount();
        if (vested <= totalClaimed) return 0;
        return vested - totalClaimed;
    }

    /// @notice Advance vesting clock and release unlocked tokens in a single call.
    function advanceAndClaim(uint256 beaconId) external returns (uint256 released) {
        if (beaconId > 0) {
            advancePass(beaconId);
        }
        return claim();
    }

    /// @notice Release unlocked tokens to the beneficiary based on recorded orbital sightings.
    function claim() public returns (uint256 released) {
        released = claimableAmount();
        if (released == 0) revert NothingToClaim();

        totalClaimed += released;

        bool success = token.transfer(beneficiary, released);
        if (!success) revert TransferFailed();

        emit TokensClaimed(beneficiary, released, totalClaimed, passesCounted);
    }
}
