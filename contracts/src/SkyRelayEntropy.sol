// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISkyRelay, ISkyRelayEntropy} from "./interfaces/ISkyRelay.sol";
import {ISkyRelayBond} from "./SkyRelayBeacon.sol";

/// @title SkyRelayEntropy
/// @notice Commit-reveal randomness gated on a verified sighting.
/// @dev The satellite contributes no entropy. A verified sighting is a
///      sybil-resistant admission ticket: a bonded key can open a commitment
///      in a round only if it signed a beacon whose timestamp falls inside
///      that round. The seed is the participants' secrets. Nothing in this
///      contract reads a sighting's geometry.
///
///      The beacon is secure if at least one participant is honest and
///      reveals.
///
///      The last revealer, having seen the other reveals, can withhold
///      theirs: that drops their contribution and forces the seed the round
///      would have had without them, and it does not let them pick a
///      different one; the cost is `revealDeposit`, so manipulation is
///      bounded by that deposit.
///
///      This is not a VRF. If a consumer needs randomness with stronger
///      guarantees than one honest participant, Chainlink VRF exists on BSC
///      and is the appropriate tool.
///
///      # Ordering
///
///      Rounds are fixed epochs: `round = timestamp / roundSeconds`.
///
///      - Commits for round R are submitted during round R-2. They close
///        when R-1 begins.
///      - Reveals for round R happen during round R.
///      - A consumer requesting during round R is served by round R+1.
///
///      The gap is two rounds on purpose. Commits for R+1 closed at the end
///      of R-1, before the request existed, so no participant can pick a
///      secret with the request in view. Reveals for R+1 happen after the
///      request, so the requester cannot watch reveals accumulate and then
///      decide whether to request. A one-round gap fails the second
///      property: a requester could sit until most of the round's reveals
///      were in and request only on a favourable partial seed.
///
///      A round with no reveals finalizes unseeded. `seedOf` reverts
///      `NoSeed` rather than return `bytes32(0)`. A request pointing at that
///      round does not resolve to the zero word; the requester may
///      `reservice` it onto a later round, or place a new request (a new
///      request keeps the commit-before-request gap; `reservice` does not —
///      that later round's commits may have been made with the original
///      request already visible).
contract SkyRelayEntropy is ISkyRelayEntropy {
    uint64 public immutable roundSeconds;
    /// @notice Posted with a commit and returned on reveal. Kept if the
    ///         commit is never revealed. This is the price of the
    ///         last-revealer abort.
    uint256 public immutable revealDeposit;

    address public immutable vault;
    ISkyRelay public immutable beacon;
    ISkyRelayBond public immutable bond;

    address public owner;
    address public pendingOwner;

    struct Round {
        /// @notice XOR of every revealed secret. Not a seed; `finalize` hashes it.
        uint256 accumulator;
        uint32 commitCount;
        uint32 revealCount;
        bool finalized;
        /// @notice Unset until a round with at least one reveal is finalized.
        ///         A finalized round with `revealCount == 0` stays zero.
        ///         `seedOf` reverts `NoSeed` — the zero word is not a seed.
        bytes32 seed;
    }

    mapping(uint64 => Round) public rounds;
    mapping(uint64 => mapping(address => bytes32)) public commitmentOf;
    mapping(uint64 => mapping(address => bool)) public revealedIn;
    /// @dev Committers, in commit order, so a sweep can name each forfeit.
    mapping(uint64 => address[]) private _committers;
    mapping(uint64 => bool) public forfeitsSwept;

    struct Request {
        address requester;
        uint64 servingRound;
        uint32 numWords;
    }

    mapping(bytes32 => Request) public requests;
    uint256 public requestNonce;

    event Committed(uint64 indexed round, address indexed attester, bytes32 commitment);
    event Revealed(uint64 indexed round, address indexed attester, uint256 indexed beaconId);
    event Finalized(uint64 indexed round, bytes32 seed, uint32 contributors);
    event DepositForfeited(uint64 indexed round, address indexed attester, uint256 amount);
    event RandomnessRequested(
        bytes32 indexed requestId, address indexed requester, uint64 servingRound, uint32 numWords
    );
    event RequestReserviced(bytes32 indexed requestId, uint64 servingRound);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error ZeroAddress();
    error ZeroValue();
    error NotOwner();
    error NotPendingOwner();
    error CommitWindowClosed();
    error NotBonded();
    error BadDeposit();
    error ZeroCommitment();
    error AlreadyCommitted();
    error RevealWindowClosed();
    error AlreadyRevealed();
    error CommitmentMismatch();
    error SightingOutsideRound();
    error SignersMismatch();
    error NotBeaconSigner();
    error RoundOpen();
    error AlreadyFinalized();
    error NotFinalized();
    error NoSeed();
    error UnknownRequest();
    error ZeroWords();
    error NotRequester();
    error RoundSeeded();
    error AlreadySwept();
    error NothingToSweep();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address owner_,
        address vault_,
        address bond_,
        address beacon_,
        uint64 roundSeconds_,
        uint256 revealDeposit_
    ) {
        if (owner_ == address(0) || vault_ == address(0) || bond_ == address(0) || beacon_ == address(0)) {
            revert ZeroAddress();
        }
        if (roundSeconds_ == 0 || revealDeposit_ == 0) revert ZeroValue();
        owner = owner_;
        vault = vault_;
        bond = ISkyRelayBond(bond_);
        beacon = ISkyRelay(beacon_);
        roundSeconds = roundSeconds_;
        revealDeposit = revealDeposit_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ── ownership ───────────────────────────────────────────────────────────

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ── rounds ──────────────────────────────────────────────────────────────

    function currentRound() public view returns (uint64) {
        return uint64(block.timestamp / roundSeconds);
    }

    /// @notice Commit to a secret for `round`, which must be `currentRound() + 2`.
    /// @param commitment `keccak256(abi.encode(secret, msg.sender, round))`.
    ///        The sender and the round are inside the preimage, so the same
    ///        commitment cannot be opened by another address or in another round.
    /// @dev A zero commitment is refused: the mapping uses zero as "none".
    ///      One commitment per `(round, address)`. The caller must be an
    ///      active bonded attester. `msg.value` must equal `revealDeposit`.
    function commit(uint64 round, bytes32 commitment) external payable {
        if (round != currentRound() + 2) revert CommitWindowClosed();
        if (msg.value != revealDeposit) revert BadDeposit();
        if (commitment == bytes32(0)) revert ZeroCommitment();
        if (commitmentOf[round][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        if (!bond.isActive(msg.sender)) revert NotBonded();

        commitmentOf[round][msg.sender] = commitment;
        rounds[round].commitCount += 1;
        _committers[round].push(msg.sender);
        emit Committed(round, msg.sender, commitment);
    }

    /// @notice Open a commitment during `round`, if `msg.sender` signed a
    ///         beacon whose timestamp falls inside `round`.
    /// @param signers Recovered signers of `beaconId`, in submission order.
    ///        The beacon stores one `signersHash`, not a slot per member; the
    ///        caller re-supplies the array, this checks the hash, then
    ///        requires `msg.sender` to appear in it.
    /// @dev Refunds `revealDeposit`. The secret is XORed into the round
    ///      accumulator. XOR is commutative, so reveal order does not change
    ///      the seed — the last revealer's only choice is to reveal or to
    ///      forfeit.
    function reveal(uint64 round, uint256 beaconId, bytes32 secret, address[] calldata signers) external {
        if (currentRound() != round) revert RevealWindowClosed();
        if (revealedIn[round][msg.sender]) revert AlreadyRevealed();

        bytes32 stored = commitmentOf[round][msg.sender];
        if (stored == bytes32(0) || stored != keccak256(abi.encode(secret, msg.sender, round))) {
            revert CommitmentMismatch();
        }
        _requireAdmitted(round, beaconId, signers);

        revealedIn[round][msg.sender] = true;
        Round storage r = rounds[round];
        r.accumulator ^= uint256(secret);
        r.revealCount += 1;
        emit Revealed(round, msg.sender, beaconId);

        (bool ok,) = msg.sender.call{value: revealDeposit}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Permissionless, once `round` has ended.
    /// @dev Seed is `keccak256(abi.encode(accumulator, round, revealCount))`.
    ///      With no reveals the round finalizes unseeded: `seed` stays zero,
    ///      `contributors` is zero, and `seedOf` reverts `NoSeed`. A
    ///      `Finalized` event with `contributors == 0` is that case, not a
    ///      seed of zero.
    function finalize(uint64 round) external {
        if (currentRound() <= round) revert RoundOpen();
        Round storage r = rounds[round];
        if (r.finalized) revert AlreadyFinalized();
        r.finalized = true;

        uint32 n = r.revealCount;
        bytes32 seed;
        if (n != 0) {
            seed = keccak256(abi.encode(r.accumulator, round, n));
            r.seed = seed;
        }
        emit Finalized(round, seed, n);
    }

    /// @notice Seed and contributor count. Reverts when the round is not
    ///         finalized, and when it finalized with no reveals.
    function seedOf(uint64 round) external view returns (bytes32 seed, uint32 contributors) {
        return _seedOf(round);
    }

    // ── consumers ───────────────────────────────────────────────────────────

    /// @notice Request `numWords` during round R. Served by round R+1.
    function requestRandomness(uint32 numWords) external returns (bytes32 requestId, uint64 servingRound) {
        if (numWords == 0) revert ZeroWords();
        servingRound = currentRound() + 1;
        uint256 nonce = ++requestNonce;
        requestId = keccak256(abi.encode(msg.sender, servingRound, numWords, nonce));
        requests[requestId] = Request({requester: msg.sender, servingRound: servingRound, numWords: numWords});
        emit RandomnessRequested(requestId, msg.sender, servingRound, numWords);
    }

    /// @notice Move a request off a round that finalized with no reveals.
    /// @dev Only the requester. The new serving round is `currentRound() + 1`,
    ///      whose reveals have not started, so the caller cannot select a
    ///      seed they have already watched. The new round's commits are not
    ///      the ones that closed before the original request — participants
    ///      may have seen it — so a consumer who still needs that gap calls
    ///      `requestRandomness` again instead.
    function reservice(bytes32 requestId) external returns (uint64 servingRound) {
        Request storage req = requests[requestId];
        if (req.numWords == 0) revert UnknownRequest();
        if (msg.sender != req.requester) revert NotRequester();

        Round storage r = rounds[req.servingRound];
        if (!r.finalized) revert NotFinalized();
        if (r.revealCount != 0) revert RoundSeeded();

        servingRound = currentRound() + 1;
        if (servingRound <= req.servingRound) revert RoundOpen();
        req.servingRound = servingRound;
        emit RequestReserviced(requestId, servingRound);
    }

    /// @notice `words[i] = uint256(keccak256(abi.encode(seed, requestId, i)))`.
    /// @dev Reverts if the serving round is not finalized or has no seed.
    function randomWords(bytes32 requestId) external view returns (uint256[] memory words) {
        Request storage req = requests[requestId];
        if (req.numWords == 0) revert UnknownRequest();
        (bytes32 seed,) = _seedOf(req.servingRound);
        words = new uint256[](req.numWords);
        for (uint256 i = 0; i < req.numWords; i++) {
            words[i] = uint256(keccak256(abi.encode(seed, requestId, i)));
        }
    }

    /// @notice Send unrevealed deposits for a closed round to `vault`.
    /// @dev Pays `(commitCount - revealCount) * revealDeposit`, not the
    ///      contract balance, so other rounds' deposits are not swept.
    ///      One sweep per round.
    function sweepForfeited(uint64 round) external onlyOwner {
        if (currentRound() <= round) revert RoundOpen();
        if (forfeitsSwept[round]) revert AlreadySwept();
        Round storage r = rounds[round];
        uint256 outstanding = uint256(r.commitCount - r.revealCount) * revealDeposit;
        if (outstanding == 0) revert NothingToSweep();
        forfeitsSwept[round] = true;

        address[] storage committers = _committers[round];
        uint256 n = committers.length;
        for (uint256 i = 0; i < n; i++) {
            address who = committers[i];
            if (!revealedIn[round][who]) emit DepositForfeited(round, who, revealDeposit);
        }

        (bool ok,) = vault.call{value: outstanding}("");
        if (!ok) revert TransferFailed();
    }

    // ── internals ───────────────────────────────────────────────────────────

    function _seedOf(uint64 round) internal view returns (bytes32 seed, uint32 contributors) {
        Round storage r = rounds[round];
        if (!r.finalized) revert NotFinalized();
        if (r.revealCount == 0) revert NoSeed();
        return (r.seed, r.revealCount);
    }

    /// @dev The sighting gate. `timestamp / roundSeconds == round`, and
    ///      `msg.sender` is in the signer set Task 4 committed as `signersHash`.
    function _requireAdmitted(uint64 round, uint256 beaconId, address[] calldata signers) internal view {
        ISkyRelay.BeaconSummary memory summary = beacon.getBeacon(beaconId);
        if (summary.timestamp / roundSeconds != round) revert SightingOutsideRound();
        if (keccak256(abi.encodePacked(signers)) != summary.signersHash) revert SignersMismatch();
        uint256 n = signers.length;
        for (uint256 i = 0; i < n; i++) {
            if (signers[i] == msg.sender) return;
        }
        revert NotBeaconSigner();
    }
}
