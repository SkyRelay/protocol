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
    address public immutable attesterOperator;

    uint64 public immutable startTimestamp;
    uint256 public immutable totalAllocation;
    uint256 public immutable totalPassesRequired;

    uint256 public totalClaimed;

    event VestingInitialized(
        address indexed token,
        address indexed beneficiary,
        address indexed attesterOperator,
        uint256 totalAllocation,
        uint256 totalPassesRequired,
        uint64 startTimestamp
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
    error NothingToClaim();
    error TransferFailed();
    error Unauthorized();

    constructor(
        address skyRelayAddress,
        address tokenAddress,
        address beneficiaryAddress,
        address operatorAddress,
        uint256 allocationAmount,
        uint256 passesRequired,
        uint64 startTs
    ) {
        if (skyRelayAddress == address(0)) revert ZeroAddress();
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (beneficiaryAddress == address(0)) revert ZeroAddress();
        if (operatorAddress == address(0)) revert ZeroAddress();
        if (allocationAmount == 0) revert ZeroAmount();
        if (passesRequired == 0) revert InvalidPassRequirement();

        skyRelay = ISkyRelay(skyRelayAddress);
        token = IERC20Transferable(tokenAddress);
        beneficiary = beneficiaryAddress;
        attesterOperator = operatorAddress;
        totalAllocation = allocationAmount;
        totalPassesRequired = passesRequired;
        startTimestamp = startTs == 0 ? uint64(block.timestamp) : startTs;

        emit VestingInitialized(
            tokenAddress,
            beneficiaryAddress,
            operatorAddress,
            allocationAmount,
            passesRequired,
            startTimestamp
        );
    }

    /// @notice Returns the number of verified orbital passes recorded since startTimestamp.
    function getRecordedPassCount() public view returns (uint256) {
        uint64 currentTs = uint64(block.timestamp);
        if (currentTs <= startTimestamp) return 0;

        // Window cannot exceed 366 days in a single call per SkyRelay protocol specification
        uint64 windowEnd = currentTs;
        if (windowEnd - startTimestamp > 365 days) {
            windowEnd = startTimestamp + 365 days;
        }

        return skyRelay.beaconCountInWindow(attesterOperator, startTimestamp, windowEnd);
    }

    /// @notice Computes the total cumulative vested tokens unlocked by orbital passes.
    function vestedAmount() public view returns (uint256) {
        uint256 passCount = getRecordedPassCount();
        if (passCount >= totalPassesRequired) {
            return totalAllocation;
        }
        return (totalAllocation * passCount) / totalPassesRequired;
    }

    /// @notice Computes the claimable tokens currently available for withdrawal.
    function claimableAmount() public view returns (uint256) {
        uint256 vested = vestedAmount();
        if (vested <= totalClaimed) return 0;
        return vested - totalClaimed;
    }

    /// @notice Release unlocked tokens to the beneficiary based on recorded orbital sightings.
    function claim() external returns (uint256 released) {
        released = claimableAmount();
        if (released == 0) revert NothingToClaim();

        totalClaimed += released;
        uint256 currentPasses = getRecordedPassCount();

        bool success = token.transfer(beneficiary, released);
        if (!success) revert TransferFailed();

        emit TokensClaimed(beneficiary, released, totalClaimed, currentPasses);
    }
}
