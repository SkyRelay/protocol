// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CatalogRegistry
/// @notice Names a `catalogHash` and stores an opaque retrieval hint for it.
///
/// `catalogHash` is the commitment: keccak256 over the element sets a sighting
/// was resolved against. `locator` is only a hint about where to look — a BNB
/// Greenfield object reference in practice, e.g.
/// `gnfd://skyrelay-catalog/2026-09-20T2000Z.tle`. This contract does not parse
/// or validate the locator. An object fetched from it that does not hash to
/// `catalogHash` is simply the wrong object; that check happens off chain.
///
/// What this does **not** achieve: a dishonest registrar can register a
/// doctored catalog, so the registry moves the trust rather than removing it.
/// What the hash does prevent is substitution after the fact — once a hash is
/// written, nobody can point it at a different locator, and a later fetch
/// either matches the hash or it does not.
contract CatalogRegistry {
    struct CatalogEntry {
        uint64 registeredAt;
        string locator;
    }

    address public owner;
    address public pendingOwner;
    address public registrar;

    /// @notice catalogHash => entry. Entries are immutable once written.
    mapping(bytes32 => CatalogEntry) public catalogs;

    event CatalogRegistered(bytes32 indexed catalogHash, string locator, uint64 at);
    event RegistrarSet(address indexed registrar);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error ZeroAddress();
    error ZeroHash();
    error NotOwner();
    error NotPendingOwner();
    error NotRegistrar();
    error AlreadyRegistered();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        registrar = owner_;
        emit OwnershipTransferred(address(0), owner_);
        emit RegistrarSet(owner_);
    }

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

    function setRegistrar(address registrar_) external onlyOwner {
        if (registrar_ == address(0)) revert ZeroAddress();
        registrar = registrar_;
        emit RegistrarSet(registrar_);
    }

    /// @notice Record `catalogHash` with a retrieval hint. Re-registering an
    ///         already-registered hash reverts; the entry is then immutable.
    function register(bytes32 catalogHash, string calldata locator) external {
        if (msg.sender != registrar) revert NotRegistrar();
        if (catalogHash == bytes32(0)) revert ZeroHash();
        if (catalogs[catalogHash].registeredAt != 0) revert AlreadyRegistered();
        uint64 at = uint64(block.timestamp);
        if (at == 0) at = 1;
        catalogs[catalogHash] = CatalogEntry({registeredAt: at, locator: locator});
        emit CatalogRegistered(catalogHash, locator, at);
    }

    function isRegistered(bytes32 catalogHash) external view returns (bool) {
        return catalogs[catalogHash].registeredAt != 0;
    }
}
