// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISkyRelay} from "../../src/interfaces/ISkyRelay.sol";

/// @title MockCoverageEscrow
/// @notice Demonstration only: a funder locks a bounty for a remote station;
///         the operator collects after the ledger shows N verified sightings
///         in a window. Not a product.
///
/// The escrow asks the beacon `beaconCountInWindow`. It does not interpret
/// a relay claim, and it does not decide that a sighting is physically true —
/// it pays when the ledger's own counters say the window was filled.
contract MockCoverageEscrow {
    ISkyRelay public immutable relay;

    struct Escrow {
        address funder;
        address operator;
        uint64 fromTs;
        uint64 toTs;
        uint32 minBeacons;
        uint128 amount;
        bool settled;
    }

    uint256 public totalEscrows;
    mapping(uint256 => Escrow) public escrows;

    bool private _locked;

    event Funded(
        uint256 indexed escrowId,
        address indexed funder,
        address indexed operator,
        uint64 fromTs,
        uint64 toTs,
        uint32 minBeacons,
        uint256 amount
    );
    event Claimed(uint256 indexed escrowId, address indexed operator, uint256 count, uint256 amount);
    event Refunded(uint256 indexed escrowId, address indexed funder, uint256 count, uint256 amount);

    error ZeroAddress();
    error ZeroValue();
    error BadWindow();
    error UnknownEscrow();
    error NotOperator();
    error NotFunder();
    error WindowOpen();
    error AlreadySettled();
    error CoverageShort();
    error CoverageMet();
    error Reentrant();
    error TransferFailed();

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(ISkyRelay relay_) {
        if (address(relay_) == address(0)) revert ZeroAddress();
        relay = relay_;
    }

    /// @notice Lock `msg.value` for `operator`. Collectable after `toTs` if the
    ///         ledger shows at least `minBeacons` verified sightings in the window.
    function fund(address operator, uint64 fromTs, uint64 toTs, uint32 minBeacons)
        external
        payable
        returns (uint256 escrowId)
    {
        if (operator == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroValue();
        if (toTs < fromTs) revert BadWindow();
        escrowId = ++totalEscrows;
        escrows[escrowId] = Escrow({
            funder: msg.sender,
            operator: operator,
            fromTs: fromTs,
            toTs: toTs,
            minBeacons: minBeacons,
            amount: uint128(msg.value),
            settled: false
        });
        emit Funded(escrowId, msg.sender, operator, fromTs, toTs, minBeacons, msg.value);
    }

    /// @notice Operator collects after `toTs` if `beaconCountInWindow` meets `minBeacons`.
    function claim(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.funder == address(0)) revert UnknownEscrow();
        if (msg.sender != e.operator) revert NotOperator();
        if (block.timestamp <= e.toTs) revert WindowOpen();
        if (e.settled) revert AlreadySettled();
        uint256 count = relay.beaconCountInWindow(e.operator, e.fromTs, e.toTs);
        if (count < e.minBeacons) revert CoverageShort();
        e.settled = true;
        uint256 amount = e.amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(escrowId, msg.sender, count, amount);
    }

    /// @notice Funder reclaims the bounty if the window closed short of `minBeacons`.
    function refund(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        if (e.funder == address(0)) revert UnknownEscrow();
        if (msg.sender != e.funder) revert NotFunder();
        if (block.timestamp <= e.toTs) revert WindowOpen();
        if (e.settled) revert AlreadySettled();
        uint256 count = relay.beaconCountInWindow(e.operator, e.fromTs, e.toTs);
        if (count >= e.minBeacons) revert CoverageMet();
        e.settled = true;
        uint256 amount = e.amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Refunded(escrowId, msg.sender, count, amount);
    }
}
