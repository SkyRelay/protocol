// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStatementAdapter} from "./interfaces/IStatementAdapter.sol";

/// @title EquivocationBond
/// @notice Domain-agnostic economic bonding and fraud-proof slashing contract.
/// @dev Implements the canonical equivocation predicate:
///      Same Subject ∧ Same Slot ∧ Different Digest => Immediate On-Chain Slash.
///      Requires zero DAO governance, zero challenge periods, and zero external oracles.
contract EquivocationBond {
    uint256 public immutable minBond;
    uint64 public immutable unbondingPeriod;
    uint16 public immutable reporterBountyBps;
    address public immutable vault;
    IStatementAdapter public immutable adapter;

    mapping(address => uint256) public bonded;
    mapping(address => uint64) public unbondingAt;
    mapping(address => bool) public slashed;
    mapping(bytes32 => bool) public proven;

    event Bonded(address indexed attester, uint256 amount, uint256 total);
    event UnbondRequested(address indexed attester, uint64 at, uint256 amount);
    event Withdrawn(address indexed attester, uint256 amount);
    event GenericEquivocation(
        address indexed attester,
        address indexed reporter,
        address indexed subject,
        bytes32 slot,
        bytes32 digestA,
        bytes32 digestB,
        uint256 amountSlashed
    );

    error ZeroAddress();
    error ZeroValue();
    error InvalidBounty();
    error BelowMinBond();
    error Slashed();
    error Unbonding();
    error NotUnbonding();
    error TooEarly();
    error NotBonded();
    error TransferFailed();
    error NotEquivocation();
    error DistinctSigners();
    error AlreadyProven();
    error AlreadySlashed();
    error NothingToSlash();
    error BadSignature();

    constructor(
        uint256 minBond_,
        uint64 unbondingPeriod_,
        uint16 reporterBountyBps_,
        address vault_,
        address adapter_
    ) {
        if (vault_ == address(0) || adapter_ == address(0)) revert ZeroAddress();
        if (minBond_ == 0 || unbondingPeriod_ == 0) revert ZeroValue();
        if (reporterBountyBps_ > 10_000) revert InvalidBounty();

        minBond = minBond_;
        unbondingPeriod = unbondingPeriod_;
        reporterBountyBps = reporterBountyBps_;
        vault = vault_;
        adapter = IStatementAdapter(adapter_);
    }

    /// @notice Lock native BNB / ETH. The signer becomes active once bonded >= minBond and not unbonding.
    function bond() external payable virtual {
        if (slashed[msg.sender]) revert Slashed();
        if (unbondingAt[msg.sender] != 0) revert Unbonding();
        if (msg.value == 0) revert ZeroValue();

        uint256 total = bonded[msg.sender] + msg.value;
        if (total < minBond) revert BelowMinBond();

        bonded[msg.sender] = total;
        emit Bonded(msg.sender, msg.value, total);
    }

    /// @notice Start the unbonding cooldown and deactivate attester eligibility immediately.
    function requestUnbond() external virtual {
        if (slashed[msg.sender]) revert Slashed();
        if (unbondingAt[msg.sender] != 0) revert Unbonding();

        uint256 amount = bonded[msg.sender];
        if (amount == 0) revert NotBonded();

        unbondingAt[msg.sender] = uint64(block.timestamp);
        emit UnbondRequested(msg.sender, uint64(block.timestamp), amount);
    }

    /// @notice Withdraw unlocked funds after unbondingPeriod has elapsed.
    function withdraw() external virtual {
        uint64 started = unbondingAt[msg.sender];
        if (started == 0) revert NotUnbonding();
        if (block.timestamp < uint256(started) + unbondingPeriod) revert TooEarly();

        uint256 amount = bonded[msg.sender];
        bonded[msg.sender] = 0;
        unbondingAt[msg.sender] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Bonded at least minBond, not unbonding, not slashed.
    function isActive(address attester) external view virtual returns (bool) {
        return bonded[attester] >= minBond && unbondingAt[attester] == 0 && !slashed[attester];
    }

    struct EquivocationProof {
        bytes statementA;
        bytes sigA;
        bytes statementB;
        bytes sigB;
    }

    /// @notice Submit two contradictory signed statements to slash the signing attester.
    function slashGenericEquivocation(EquivocationProof calldata proof)
        external
        virtual
        returns (uint256 amountSlashed)
    {
        (address subjectA, bytes32 slotA, bytes32 digestA) = adapter.parseStatement(proof.statementA);
        (address subjectB, bytes32 slotB, bytes32 digestB) = adapter.parseStatement(proof.statementB);

        if (subjectA != subjectB || slotA != slotB || digestA == digestB) revert NotEquivocation();

        address signerA = _recover(digestA, proof.sigA);
        if (signerA != _recover(digestB, proof.sigB)) revert DistinctSigners();

        bytes32 pairKey = digestA < digestB
            ? keccak256(abi.encodePacked(digestA, digestB))
            : keccak256(abi.encodePacked(digestB, digestA));
        if (proven[pairKey]) revert AlreadyProven();
        if (slashed[signerA]) revert AlreadySlashed();

        amountSlashed = bonded[signerA];
        if (amountSlashed == 0) revert NothingToSlash();

        proven[pairKey] = true;
        slashed[signerA] = true;
        bonded[signerA] = 0;
        unbondingAt[signerA] = 0;

        _distributeSlash(amountSlashed);

        emit GenericEquivocation(signerA, msg.sender, subjectA, slotA, digestA, digestB, amountSlashed);
    }

    function _distributeSlash(uint256 amount) internal virtual {
        uint256 bounty = (amount * uint256(reporterBountyBps)) / 10_000;
        uint256 toVault = amount - bounty;

        if (bounty > 0) {
            (bool ok,) = msg.sender.call{value: bounty}("");
            if (!ok) revert TransferFailed();
        }
        if (toVault > 0) {
            (bool ok,) = vault.call{value: toVault}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @dev Decodes 65-byte RSV signature and executes standard ecrecover.
    function _recover(bytes32 digest, bytes calldata sig) internal pure virtual returns (address) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert BadSignature();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }
}
