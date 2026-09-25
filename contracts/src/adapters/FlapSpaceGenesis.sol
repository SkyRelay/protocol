// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISkyRelay} from "../interfaces/ISkyRelay.sol";

/// @title SpaceGenesisToken
/// @notice Minimal ERC-20 token deployed with in-orbit proven origin on BNB Smart Chain.
contract SpaceGenesisToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;
    address public immutable owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, address recipient) {
        name = _name;
        symbol = _symbol;
        owner = recipient;
        uint256 initialSupply = 1_000_000_000 * 10 ** 18; // 1 Billion standard meme supply
        totalSupply = initialSupply;
        balanceOf[recipient] = initialSupply;
        emit Transfer(address(0), recipient, initialSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "InsufficientBalance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "InsufficientBalance");
        require(allowance[from][msg.sender] >= amount, "InsufficientAllowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

interface IOwnableLike {
    function owner() external view returns (address);
}

/// @notice Per-launchpad adapter that answers "who created this token".
/// @dev Flap / Four.meme tokens usually renounce ownership, so `owner()` is
///      zero. The launchpad's own records (portal storage, creation event
///      indexed on chain) are the source of truth; one small resolver per
///      launchpad wraps that lookup so this binder never hardcodes it.
interface ICreatorResolver {
    function creatorOf(address token) external view returns (address);
}

/// @title FlapSpaceGenesis
/// @notice Space-genesis factory and provenance binder for Flap.sh and BSC launchpads.
/// @dev A bind is authorized by exactly one of four paths:
///      1. Created     token deployed by this contract in the same call;
///      2. TokenOwner  caller is `token.owner()` or BEP-20 `token.getOwner()`;
///      3. Resolver    caller is the creator per an admin-approved launchpad resolver;
///      4. Factory     an admin-approved launchpad calls back during token creation.
///      Resolvers and factories go live only after a 2-day timelock; removal is instant.
contract FlapSpaceGenesis {
    enum AuthPath {
        None,
        Created,
        TokenOwner,
        Resolver,
        Factory
    }

    struct SpaceProvenance {
        uint256 beaconId;
        uint32 noradId;
        uint64 genesisTimestamp;
        uint8 quorum;
        bytes32 catalogHash;
        bytes32 signersHash;
        address deployer; // the authorized creator, never an arbitrary caller
        AuthPath authPath;
    }

    uint64 public constant ALLOWLIST_DELAY = 2 days;
    uint256 internal constant OWNER_CALL_GAS = 30_000;

    ISkyRelay public immutable skyRelay;

    address public admin;
    address public pendingAdmin;

    /// @notice 0 = not listed; otherwise the timestamp it becomes usable.
    mapping(address => uint64) public resolverActiveAt;
    mapping(address => uint64) public factoryActiveAt;

    mapping(address => SpaceProvenance) public provenances;

    event MemeSpaceGenesis(
        address indexed tokenAddress,
        uint256 indexed beaconId,
        uint32 noradId,
        uint64 genesisTimestamp,
        bytes32 catalogHash,
        address deployer,
        AuthPath authPath
    );
    event ResolverScheduled(address indexed resolver, uint64 activeAt);
    event ResolverRemoved(address indexed resolver);
    event FactoryScheduled(address indexed factory, uint64 activeAt);
    event FactoryRemoved(address indexed factory);
    event AdminTransferStarted(address indexed from, address indexed to);
    event AdminTransferred(address indexed from, address indexed to);

    error NoActiveSpaceBeacon();
    error AlreadyBound();
    error ZeroAddress();
    error NotContract();
    error NotAuthorized();
    error NotAdmin();
    error UnknownResolver();
    error UnknownFactory();
    error BeaconMismatch(uint256 latestBeaconId);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address skyRelayBeacon, address admin_) {
        if (skyRelayBeacon == address(0) || admin_ == address(0)) revert ZeroAddress();
        skyRelay = ISkyRelay(skyRelayBeacon);
        admin = admin_;
        emit AdminTransferred(address(0), admin_);
    }

    // ---------------------------------------------------------------- create

    /// @notice Deploys a new token and binds it atomically. Cannot be front-run:
    ///         the token address does not exist until this call creates it.
    function createTokenWithSpaceGenesis(string memory name, string memory symbol)
        external
        returns (address token)
    {
        token = address(new SpaceGenesisToken(name, symbol, msg.sender));
        _bind(token, 0, msg.sender, AuthPath.Created);
    }

    // ------------------------------------------------------------------ bind

    /// @notice Bind an external token when the caller is its `owner()` or `getOwner()`.
    /// @param expectedBeaconId 0 accepts the latest beacon; non-zero must equal
    ///        it, so a beacon landing between signing and inclusion reverts
    ///        instead of silently binding to something the creator never saw.
    function bindSpaceGenesis(address token, uint256 expectedBeaconId) public {
        _requireContract(token);
        address o = _tryOwner(token);
        if (o == address(0) || o != msg.sender) revert NotAuthorized();
        _bind(token, expectedBeaconId, msg.sender, AuthPath.TokenOwner);
    }

    /// @notice Backward-compatible convenience bind with expectedBeaconId = 0.
    function bindSpaceGenesis(address token) external {
        bindSpaceGenesis(token, 0);
    }

    /// @notice Bind a renounced launchpad token; caller must be its creator per `resolver`.
    function bindSpaceGenesisVia(address token, address resolver, uint256 expectedBeaconId) external {
        _requireContract(token);
        if (!_isActive(resolverActiveAt[resolver])) revert UnknownResolver();
        address creator;
        try ICreatorResolver(resolver).creatorOf(token) returns (address c) {
            creator = c;
        } catch {
            revert NotAuthorized();
        }
        if (creator == address(0) || creator != msg.sender) revert NotAuthorized();
        _bind(token, expectedBeaconId, msg.sender, AuthPath.Resolver);
    }

    /// @notice Callback for an approved launchpad, called inside its token-creation tx.
    /// @dev The launchpad vouches for `creator`; that is why factories are timelocked.
    function bindFromFactory(address token, address creator, uint256 expectedBeaconId) external {
        if (!_isActive(factoryActiveAt[msg.sender])) revert UnknownFactory();
        if (creator == address(0)) revert ZeroAddress();
        _requireContract(token);
        _bind(token, expectedBeaconId, creator, AuthPath.Factory);
    }

    // ----------------------------------------------------------------- admin

    function scheduleResolver(address resolver) external onlyAdmin {
        if (resolver == address(0)) revert ZeroAddress();
        uint64 at = uint64(block.timestamp) + ALLOWLIST_DELAY;
        resolverActiveAt[resolver] = at;
        emit ResolverScheduled(resolver, at);
    }

    function removeResolver(address resolver) external onlyAdmin {
        delete resolverActiveAt[resolver];
        emit ResolverRemoved(resolver);
    }

    function scheduleFactory(address factory) external onlyAdmin {
        if (factory == address(0)) revert ZeroAddress();
        uint64 at = uint64(block.timestamp) + ALLOWLIST_DELAY;
        factoryActiveAt[factory] = at;
        emit FactoryScheduled(factory, at);
    }

    function removeFactory(address factory) external onlyAdmin {
        delete factoryActiveAt[factory];
        emit FactoryRemoved(factory);
    }

    function transferAdmin(address next) external onlyAdmin {
        pendingAdmin = next;
        emit AdminTransferStarted(admin, next);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    // ------------------------------------------------------------------ view

    function getProvenance(address token) external view returns (SpaceProvenance memory) {
        return provenances[token];
    }

    function isResolverActive(address r) external view returns (bool) {
        return _isActive(resolverActiveAt[r]);
    }

    function isFactoryActive(address f) external view returns (bool) {
        return _isActive(factoryActiveAt[f]);
    }

    // -------------------------------------------------------------- internal

    function _bind(address token, uint256 expectedBeaconId, address creator, AuthPath path) internal {
        if (provenances[token].genesisTimestamp != 0) revert AlreadyBound();

        uint256 latest = skyRelay.totalBeacons();
        if (latest == 0) revert NoActiveSpaceBeacon();
        if (expectedBeaconId != 0 && expectedBeaconId != latest) revert BeaconMismatch(latest);

        ISkyRelay.BeaconSummary memory b = skyRelay.getBeacon(latest);
        if (b.timestamp == 0) revert NoActiveSpaceBeacon();

        provenances[token] = SpaceProvenance({
            beaconId: latest,
            noradId: b.noradId,
            genesisTimestamp: b.timestamp,
            quorum: b.quorum,
            catalogHash: b.catalogHash,
            signersHash: b.signersHash,
            deployer: creator,
            authPath: path
        });

        emit MemeSpaceGenesis(token, latest, b.noradId, b.timestamp, b.catalogHash, creator, path);
    }

    /// @dev Gas-capped staticcall: checks `owner()` and `getOwner()`. A token without them,
    ///      or one that reverts, returns dirty bits, or burns gas, yields address(0).
    function _tryOwner(address token) internal view returns (address) {
        (bool ok, bytes memory ret) =
            token.staticcall{gas: OWNER_CALL_GAS}(abi.encodeWithSelector(IOwnableLike.owner.selector));
        if (ok && ret.length == 32) {
            uint256 w = abi.decode(ret, (uint256));
            if (w >> 160 == 0 && address(uint160(w)) != address(0)) {
                return address(uint160(w));
            }
        }

        (ok, ret) =
            token.staticcall{gas: OWNER_CALL_GAS}(abi.encodeWithSignature("getOwner()"));
        if (ok && ret.length == 32) {
            uint256 w = abi.decode(ret, (uint256));
            if (w >> 160 == 0 && address(uint160(w)) != address(0)) {
                return address(uint160(w));
            }
        }

        return address(0);
    }

    function _requireContract(address token) internal view {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NotContract();
    }

    function _isActive(uint64 at) internal view returns (bool) {
        return at != 0 && block.timestamp >= at;
    }
}
