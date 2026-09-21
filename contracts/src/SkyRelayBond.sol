// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SkyRelayBeacon} from "./SkyRelayBeacon.sol";

/// @title SkyRelayBond
/// @notice Native-BNB bonds for SkyRelay attesters, and the one fraud proof
///         that is checkable on chain without computing an orbit.
///
/// Bonding is what a slash can take away. `isActive` is `bonded >= minBond`
/// and not unbonding: `requestUnbond` deactivates immediately so an attester
/// cannot equivocate and unbond in the same block.
///
/// Equivocation, exactly: two attestations from the **same signer**, with the
/// **same `operator`** and the **same `timestamp`**, but **different digests**.
/// A terminal is in one state at one second. An attester that signs two
/// different stories about one station at one instant has contradicted itself,
/// and that is two `ecrecover` calls and a comparison.
///
/// What is **not** equivocation: two attestations with the same `noradId` and
/// `timestamp` but different operators. That is a quorum — several stations
/// reporting one sighting from different places, with legitimately different
/// elevation and Doppler. Slashing that would punish honest members.
///
/// Bonding raises the cost of lying; it does not establish truth. A bonded
/// attester with a real station that never contradicts itself can still lie
/// about the physics. The fraud proof that would establish that does not
/// exist here.
contract SkyRelayBond {
    uint256 public immutable minBond;
    uint64 public immutable unbondingPeriod;
    uint16 public immutable reporterBountyBps;
    address public immutable vault;
    /// @dev EIP-712 verifying contract. Digests are computed against the
    ///      beacon's domain; this contract never has its own.
    SkyRelayBeacon public immutable beacon;

    mapping(address => uint256) public bonded;
    /// @notice 0 = not unbonding. Any other value is the timestamp the clock started.
    mapping(address => uint64) public unbondingAt;
    mapping(address => bool) public slashed;
    /// @dev Canonical (sorted) pair of digests already paid out, so the same
    ///      equivocation cannot be reported for a second bounty.
    mapping(bytes32 => bool) public proven;

    event Bonded(address indexed attester, uint256 amount, uint256 total);
    event UnbondRequested(address indexed attester, uint64 at, uint256 amount);
    event Withdrawn(address indexed attester, uint256 amount);
    event Equivocation(
        address indexed attester, address indexed reporter, bytes32 digestA, bytes32 digestB, uint256 amount
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

    constructor(uint256 minBond_, uint64 unbondingPeriod_, uint16 reporterBountyBps_, address vault_, address beacon_) {
        if (vault_ == address(0) || beacon_ == address(0)) revert ZeroAddress();
        if (minBond_ == 0 || unbondingPeriod_ == 0) revert ZeroValue();
        if (reporterBountyBps_ > 10_000) revert InvalidBounty();
        minBond = minBond_;
        unbondingPeriod = unbondingPeriod_;
        reporterBountyBps = reporterBountyBps_;
        vault = vault_;
        beacon = SkyRelayBeacon(beacon_);
    }

    /// @notice Lock native BNB. The signer becomes active once `bonded >= minBond`
    ///         and they are not unbonding. A slashed address is permanently ineligible.
    function bond() external payable {
        if (slashed[msg.sender]) revert Slashed();
        if (unbondingAt[msg.sender] != 0) revert Unbonding();
        if (msg.value == 0) revert ZeroValue();
        uint256 total = bonded[msg.sender] + msg.value;
        if (total < minBond) revert BelowMinBond();
        bonded[msg.sender] = total;
        emit Bonded(msg.sender, msg.value, total);
    }

    /// @notice Start the unbonding clock and deactivate immediately.
    function requestUnbond() external {
        if (slashed[msg.sender]) revert Slashed();
        if (unbondingAt[msg.sender] != 0) revert Unbonding();
        uint256 amount = bonded[msg.sender];
        if (amount == 0) revert NotBonded();
        unbondingAt[msg.sender] = uint64(block.timestamp);
        emit UnbondRequested(msg.sender, uint64(block.timestamp), amount);
    }

    /// @notice Withdraw the locked BNB after `unbondingPeriod`.
    function withdraw() external {
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

    /// @notice Bonded at least `minBond`, not unbonding, not slashed.
    function isActive(address attester) external view returns (bool) {
        return bonded[attester] >= minBond && unbondingAt[attester] == 0 && !slashed[attester];
    }

    /// @notice Prove two signed attestations contradict each other about one
    ///         station-second. Pays `reporterBountyBps` of the bond to the
    ///         reporter and the remainder to the vault, then permanently
    ///         ineligibilises the attester.
    function slashEquivocation(
        SkyRelayBeacon.SkyRelayAttestation calldata a,
        bytes calldata sigA,
        SkyRelayBeacon.SkyRelayAttestation calldata b,
        bytes calldata sigB
    ) external {
        if (a.operator != b.operator || a.timestamp != b.timestamp) revert NotEquivocation();

        bytes32 digestA = beacon.hashAttestation(a, block.chainid, address(beacon));
        bytes32 digestB = beacon.hashAttestation(b, block.chainid, address(beacon));
        if (digestA == digestB) revert NotEquivocation();

        address signerA = _recover(digestA, sigA);
        address signerB = _recover(digestB, sigB);
        if (signerA != signerB) revert DistinctSigners();

        bytes32 pairKey = digestA < digestB
            ? keccak256(abi.encodePacked(digestA, digestB))
            : keccak256(abi.encodePacked(digestB, digestA));
        if (proven[pairKey]) revert AlreadyProven();

        address attester = signerA;
        if (slashed[attester]) revert AlreadySlashed();
        uint256 amount = bonded[attester];
        if (amount == 0) revert NothingToSlash();

        proven[pairKey] = true;
        slashed[attester] = true;
        bonded[attester] = 0;
        unbondingAt[attester] = 0;

        uint256 bounty = amount * uint256(reporterBountyBps) / 10_000;
        uint256 toVault = amount - bounty;

        if (bounty > 0) {
            (bool ok,) = msg.sender.call{value: bounty}("");
            if (!ok) revert TransferFailed();
        }
        if (toVault > 0) {
            (bool ok,) = vault.call{value: toVault}("");
            if (!ok) revert TransferFailed();
        }

        emit Equivocation(attester, msg.sender, digestA, digestB, amount);
    }

    /// @dev Copied from SkyRelayBeacon: the replay key there is the digest, and
    ///      here the proven-pair key is the two digests, so a flipped `s` is
    ///      still the same report.
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
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
