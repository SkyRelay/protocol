// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SkyRelayBeacon
/// @notice Verifies EIP-712 Starlink physical attestations and records beacons on BSC.
/// @dev No OpenZeppelin. Domain matches packages/core/src/crypto/eip712.ts.
///
/// Two properties are worth stating up front, because both are easy to
/// over-read:
///
/// 1. The contract never computes an orbit. SGP4, the boresight match and the
///    ASN lookup all happen off chain. What it verifies is that a quorum of
///    registered keys signed attestations describing *the same sighting* —
///    same satellite, same second, same element set.
/// 2. A quorum does not make lying impossible. Anyone holding k registered keys
///    can still sign k mutually consistent fabrications. What it buys is that
///    an attacker must compromise k independent keys instead of one, and that a
///    dishonest minority cannot push through data the others contradict.
contract SkyRelayBeacon {
    uint32 public constant SPACEX_ASN = 14593;
    uint32 public constant STARLINK_ID_ASN = 45700;
    uint64 public constant ATTESTATION_TTL = 120;
    uint64 public constant FUTURE_SKEW = 30;

    /// @notice How long an expansion of signing power stays visible before it bites.
    uint64 public constant ROTATION_DELAY = 2 days;

    /// @notice Bounds the O(n^2) distinctness scan in `verifyAndRecord`.
    uint256 public constant MAX_QUORUM = 16;

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "SkyRelayAttestation(address operator,bytes32 telemetryHash,bytes32 catalogHash,uint32 noradId,int32 elevationMilliDeg,int32 dopplerHz,uint32 snrMilliDb,uint32 asn,uint64 timestamp)"
    );
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private immutable _nameHash;
    bytes32 private immutable _versionHash;

    address public immutable orbitalVault;

    // ── governance ──────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;
    bool public paused;

    /// @notice Keys whose signature the contract accepts.
    mapping(address => bool) public isAttester;
    uint8 public attesterCount;

    /// @notice How many distinct attesters must sign one sighting.
    uint8 public quorumThreshold;

    /// @notice Scheduled attester additions: address => earliest activation.
    mapping(address => uint64) public attesterEligibleAt;

    uint8 public pendingQuorumThreshold;
    uint64 public quorumThresholdEligibleAt;

    // ── beacons ─────────────────────────────────────────────────────────────

    uint256 public totalBeacons;
    /// @dev Sum of reported SNR in millidB across every station report recorded.
    ///      A bookkeeping counter, not a physical energy — see README.
    uint256 public totalEnergy;
    mapping(address => uint256) public userBeaconCount;
    mapping(bytes32 => bool) public usedDigest;

    struct SkyRelayAttestation {
        /// @notice A station operator; one of them must be `msg.sender`.
        /// @dev Without this the digest says nothing about who broadcasts the
        ///      beacon, so anyone watching the mempool could copy a signed
        ///      attestation, take the credit, and revert the rightful sender.
        address operator;
        bytes32 telemetryHash;
        /// @notice Commits to the element sets the geometry was resolved against,
        ///         so an attestation computed from a doctored catalog is
        ///         distinguishable from one computed against the real thing.
        bytes32 catalogHash;
        uint32 noradId;
        int32 elevationMilliDeg;
        int32 dopplerHz;
        uint32 snrMilliDb;
        uint32 asn;
        uint64 timestamp;
    }

    event BeaconBroadcast(
        uint256 indexed beaconId,
        uint32 indexed noradId,
        address indexed submitter,
        uint64 timestamp,
        bytes32 catalogHash,
        uint256 quorum
    );
    event StationReport(
        uint256 indexed beaconId,
        address indexed operator,
        int32 elevationMilliDeg,
        int32 dopplerHz,
        uint32 snrMilliDb,
        uint32 asn,
        bytes32 telemetryHash,
        bytes32 digest
    );
    event VaultDeposit(address indexed from, uint256 amount);

    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event PausedSet(bool paused);
    event AttesterScheduled(address indexed attester, uint64 eligibleAt);
    event AttesterCancelled(address indexed attester);
    event AttesterActivated(address indexed attester);
    event AttesterRemoved(address indexed attester);
    event QuorumThresholdScheduled(uint8 threshold, uint64 eligibleAt);
    event QuorumThresholdSet(uint8 threshold);

    error ZeroAddress();
    error NotOwner();
    error NotPendingOwner();
    error NotScheduled();
    error TooEarly();
    error AlreadyAttester();
    error NotAttester();
    error ThresholdUnreachable();
    error IsPaused();
    error LengthMismatch();
    error QuorumNotMet();
    error TooManyAttestations();
    error InconsistentQuorum();
    error BadAsn();
    error BelowHorizon();
    error Expired();
    error Future();
    error Replay();
    error BadSigner();
    error DuplicateSigner();
    error DuplicateOperator();
    error WrongOperator();
    error BadSignature();
    error VaultTransfer();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address attester_, address orbitalVault_) {
        if (owner_ == address(0) || attester_ == address(0) || orbitalVault_ == address(0)) {
            revert ZeroAddress();
        }
        owner = owner_;
        orbitalVault = orbitalVault_;
        isAttester[attester_] = true;
        attesterCount = 1;
        quorumThreshold = 1;
        _nameHash = keccak256("SkyRelay");
        _versionHash = keccak256("1");
        emit OwnershipTransferred(address(0), owner_);
        emit AttesterActivated(attester_);
        emit QuorumThresholdSet(1);
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

    // ── attester set ────────────────────────────────────────────────────────
    //
    // Expansions of signing power wait out ROTATION_DELAY and are visible on
    // chain first. Contractions are immediate: an operator who has just learned
    // a key is compromised must not have to wait two days to revoke it.

    function scheduleAttester(address attester) external onlyOwner {
        if (attester == address(0)) revert ZeroAddress();
        if (isAttester[attester]) revert AlreadyAttester();
        uint64 eligibleAt = uint64(block.timestamp) + ROTATION_DELAY;
        attesterEligibleAt[attester] = eligibleAt;
        emit AttesterScheduled(attester, eligibleAt);
    }

    function cancelAttester(address attester) external onlyOwner {
        delete attesterEligibleAt[attester];
        emit AttesterCancelled(attester);
    }

    /// @dev Permissionless once the delay has run: the decision was the owner's,
    ///      the clock is everybody's.
    function activateAttester(address attester) external {
        uint64 eligibleAt = attesterEligibleAt[attester];
        if (eligibleAt == 0) revert NotScheduled();
        if (block.timestamp < eligibleAt) revert TooEarly();
        delete attesterEligibleAt[attester];
        if (isAttester[attester]) revert AlreadyAttester();
        isAttester[attester] = true;
        attesterCount += 1;
        emit AttesterActivated(attester);
    }

    function removeAttester(address attester) external onlyOwner {
        if (!isAttester[attester]) revert NotAttester();
        if (attesterCount - 1 < quorumThreshold) revert ThresholdUnreachable();
        isAttester[attester] = false;
        attesterCount -= 1;
        emit AttesterRemoved(attester);
    }

    /// @notice Raising the bar is immediate; lowering it waits out the delay.
    function setQuorumThreshold(uint8 threshold) external onlyOwner {
        if (threshold == 0 || threshold > attesterCount) revert ThresholdUnreachable();
        if (threshold >= quorumThreshold) {
            delete pendingQuorumThreshold;
            delete quorumThresholdEligibleAt;
            quorumThreshold = threshold;
            emit QuorumThresholdSet(threshold);
        } else {
            uint64 eligibleAt = uint64(block.timestamp) + ROTATION_DELAY;
            pendingQuorumThreshold = threshold;
            quorumThresholdEligibleAt = eligibleAt;
            emit QuorumThresholdScheduled(threshold, eligibleAt);
        }
    }

    function activateQuorumThreshold() external {
        uint64 eligibleAt = quorumThresholdEligibleAt;
        if (eligibleAt == 0) revert NotScheduled();
        if (block.timestamp < eligibleAt) revert TooEarly();
        uint8 threshold = pendingQuorumThreshold;
        if (threshold == 0 || threshold > attesterCount) revert ThresholdUnreachable();
        delete pendingQuorumThreshold;
        delete quorumThresholdEligibleAt;
        quorumThreshold = threshold;
        emit QuorumThresholdSet(threshold);
    }

    function pause() external onlyOwner {
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PausedSet(false);
    }

    // ── digest ──────────────────────────────────────────────────────────────

    function domainSeparator() public view returns (bytes32) {
        return _domain(block.chainid, address(this));
    }

    /// @notice Pure hasher used by the TypeScript compatibility vectors.
    function hashAttestation(SkyRelayAttestation calldata att, uint256 chainId, address verifyingContract)
        public
        view
        returns (bytes32)
    {
        return _hash(att, chainId, verifyingContract);
    }

    // ── beacons ─────────────────────────────────────────────────────────────

    /// @notice Record one sighting, attested by a quorum of registered keys.
    /// @param atts One attestation per reporting station. All must describe the
    ///             same satellite, the same second and the same element set.
    /// @param sigs Signature per attestation, from distinct registered attesters.
    function verifyAndRecord(SkyRelayAttestation[] calldata atts, bytes[] calldata sigs)
        external
        payable
        returns (uint256 beaconId)
    {
        if (paused) revert IsPaused();
        uint256 n = atts.length;
        if (n != sigs.length) revert LengthMismatch();
        if (n == 0 || n < quorumThreshold) revert QuorumNotMet();
        if (n > MAX_QUORUM) revert TooManyAttestations();

        SkyRelayAttestation calldata first = atts[0];
        if (first.timestamp > block.timestamp + FUTURE_SKEW) revert Future();
        if (block.timestamp > uint256(first.timestamp) + ATTESTATION_TTL) revert Expired();

        address[] memory signers = new address[](n);
        bool senderIsOperator;
        beaconId = totalBeacons + 1;

        for (uint256 i = 0; i < n; i++) {
            SkyRelayAttestation calldata att = atts[i];

            if (
                att.noradId != first.noradId || att.timestamp != first.timestamp || att.catalogHash != first.catalogHash
            ) revert InconsistentQuorum();
            if (att.asn != SPACEX_ASN && att.asn != STARLINK_ID_ASN) revert BadAsn();
            if (att.elevationMilliDeg <= 0) revert BelowHorizon();

            for (uint256 j = 0; j < i; j++) {
                if (atts[j].operator == att.operator) revert DuplicateOperator();
            }

            bytes32 digest = _hash(att, block.chainid, address(this));
            if (usedDigest[digest]) revert Replay();
            usedDigest[digest] = true;

            address signer = _recover(digest, sigs[i]);
            if (!isAttester[signer]) revert BadSigner();
            for (uint256 j = 0; j < i; j++) {
                if (signers[j] == signer) revert DuplicateSigner();
            }
            signers[i] = signer;

            if (att.operator == msg.sender) senderIsOperator = true;

            userBeaconCount[att.operator] += 1;
            totalEnergy += att.snrMilliDb;

            emit StationReport(
                beaconId,
                att.operator,
                att.elevationMilliDeg,
                att.dopplerHz,
                att.snrMilliDb,
                att.asn,
                att.telemetryHash,
                digest
            );
        }

        if (!senderIsOperator) revert WrongOperator();

        totalBeacons = beaconId;

        if (msg.value > 0) {
            (bool ok,) = orbitalVault.call{value: msg.value}("");
            if (!ok) revert VaultTransfer();
            emit VaultDeposit(msg.sender, msg.value);
        }

        emit BeaconBroadcast(beaconId, first.noradId, msg.sender, first.timestamp, first.catalogHash, n);
    }

    // ── internals ───────────────────────────────────────────────────────────

    function _hash(SkyRelayAttestation calldata att, uint256 chainId, address verifyingContract)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                att.operator,
                att.telemetryHash,
                att.catalogHash,
                att.noradId,
                att.elevationMilliDeg,
                att.dopplerHz,
                att.snrMilliDb,
                att.asn,
                att.timestamp
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domain(chainId, verifyingContract), structHash));
    }

    function _domain(uint256 chainId, address verifyingContract) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, _nameHash, _versionHash, chainId, verifyingContract));
    }

    /// @dev Signature malleability is not screened, and does not need to be:
    ///      the replay key is the digest, not the signature, so a flipped `s`
    ///      produces the same digest and reverts on `Replay`.
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
