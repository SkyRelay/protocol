// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SkyRelayBeacon
/// @notice Verifies EIP-712 Starlink physical attestations and records beacons on BSC.
/// @dev No OpenZeppelin. Domain matches packages/core/src/crypto/eip712.ts.
contract SkyRelayBeacon {
    uint32 public constant SPACEX_ASN = 14593;
    uint32 public constant STARLINK_ID_ASN = 45700;
    uint64 public constant ATTESTATION_TTL = 120;
    uint64 public constant FUTURE_SKEW = 30;

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "SkyRelayAttestation(address operator,bytes32 telemetryHash,uint32 noradId,int32 elevationMilliDeg,int32 dopplerHz,uint32 snrMilliDb,uint32 asn,uint64 timestamp)"
    );
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private immutable _nameHash;
    bytes32 private immutable _versionHash;

    address public immutable attester;
    address public immutable orbitalVault;

    uint256 public totalBeacons;
    uint256 public totalEnergy;
    mapping(address => uint256) public userBeaconCount;
    mapping(bytes32 => bool) public usedDigest;

    struct SkyRelayAttestation {
        /// @notice The only address allowed to submit this attestation.
        /// @dev Without it the digest says nothing about who broadcasts the
        ///      beacon, so anyone watching the mempool could copy a signed
        ///      attestation, take the credit, and revert the rightful sender.
        address operator;
        bytes32 telemetryHash;
        uint32 noradId;
        int32 elevationMilliDeg;
        int32 dopplerHz;
        uint32 snrMilliDb;
        uint32 asn;
        uint64 timestamp;
    }

    event BeaconBroadcast(
        address indexed operator,
        uint256 indexed beaconId,
        uint32 noradId,
        int32 elevationMilliDeg,
        uint32 snrMilliDb,
        uint32 asn,
        bytes32 telemetryHash,
        bytes32 digest
    );
    event VaultDeposit(address indexed from, uint256 amount);

    error ZeroAddress();
    error BadAsn();
    error BelowHorizon();
    error Expired();
    error Future();
    error Replay();
    error BadSigner();
    error WrongOperator();
    error BadSignature();
    error VaultTransfer();

    constructor(address attester_, address orbitalVault_) {
        if (attester_ == address(0) || orbitalVault_ == address(0)) revert ZeroAddress();
        attester = attester_;
        orbitalVault = orbitalVault_;
        _nameHash = keccak256("SkyRelay");
        _versionHash = keccak256("1");
    }

    function domainSeparator() public view returns (bytes32) {
        return _domain(block.chainid, address(this));
    }

    /// @notice Pure hasher used by TS compatibility tests (explicit domain).
    function hashAttestation(SkyRelayAttestation calldata att, uint256 chainId, address verifyingContract)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                att.operator,
                att.telemetryHash,
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

    function verifyAndRecord(SkyRelayAttestation calldata att, bytes calldata signature)
        external
        payable
        returns (uint256 beaconId)
    {
        if (att.operator != msg.sender) revert WrongOperator();
        if (att.asn != SPACEX_ASN && att.asn != STARLINK_ID_ASN) revert BadAsn();
        if (att.elevationMilliDeg <= 0) revert BelowHorizon();
        if (att.timestamp > block.timestamp + FUTURE_SKEW) revert Future();
        if (block.timestamp > uint256(att.timestamp) + ATTESTATION_TTL) revert Expired();

        bytes32 digest = hashAttestation(att, block.chainid, address(this));
        // Permanent, and only load-bearing for ATTESTATION_TTL seconds. It is kept
        // as a plain mapping because the alternative -- an attester nonce -- would
        // serialise operators behind a single counter.
        if (usedDigest[digest]) revert Replay();
        address signer = _recover(digest, signature);
        if (signer != attester) revert BadSigner();
        usedDigest[digest] = true;

        beaconId = ++totalBeacons;
        userBeaconCount[msg.sender] += 1;
        totalEnergy += att.snrMilliDb;

        if (msg.value > 0) {
            (bool ok,) = orbitalVault.call{value: msg.value}("");
            if (!ok) revert VaultTransfer();
            emit VaultDeposit(msg.sender, msg.value);
        }

        emit BeaconBroadcast(
            msg.sender, beaconId, att.noradId, att.elevationMilliDeg, att.snrMilliDb, att.asn, att.telemetryHash, digest
        );
    }

    function _domain(uint256 chainId, address verifyingContract) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, _nameHash, _versionHash, chainId, verifyingContract));
    }

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
