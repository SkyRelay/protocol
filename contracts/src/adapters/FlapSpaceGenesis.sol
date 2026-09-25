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

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, address recipient) {
        name = _name;
        symbol = _symbol;
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

/// @title FlapSpaceGenesis
/// @notice Standardized space genesis factory & provenance binder for Flap.sh and BSC launchpads.
/// @dev Implements zero-financial-risk, read-only composability with SkyRelayBeacon.
contract FlapSpaceGenesis {
    struct SpaceProvenance {
        uint256 beaconId;
        uint32 noradId;
        uint64 genesisTimestamp;
        uint8 quorum;
        bytes32 catalogHash;
        bytes32 signersHash;
        address deployer;
    }

    ISkyRelay public immutable skyRelay;

    /// @notice Records immutable in-orbit provenance for registered tokens.
    mapping(address => SpaceProvenance) public provenances;

    event MemeSpaceGenesis(
        address indexed tokenAddress,
        uint256 indexed beaconId,
        uint32 noradId,
        uint64 genesisTimestamp,
        bytes32 catalogHash,
        address deployer
    );

    error NoActiveSpaceBeacon();
    error AlreadyBound();
    error ZeroAddress();

    constructor(address skyRelayBeacon) {
        if (skyRelayBeacon == address(0)) revert ZeroAddress();
        skyRelay = ISkyRelay(skyRelayBeacon);
    }

    /// @notice Deploys a new token and atomically binds it to the latest verified space beacon.
    function createTokenWithSpaceGenesis(
        string memory name,
        string memory symbol
    ) external returns (address token) {
        uint256 latestBeaconId = skyRelay.totalBeacons();
        if (latestBeaconId == 0) revert NoActiveSpaceBeacon();

        ISkyRelay.BeaconSummary memory beacon = skyRelay.getBeacon(latestBeaconId);
        if (beacon.timestamp == 0) revert NoActiveSpaceBeacon();

        token = address(new SpaceGenesisToken(name, symbol, msg.sender));

        provenances[token] = SpaceProvenance({
            beaconId: latestBeaconId,
            noradId: beacon.noradId,
            genesisTimestamp: beacon.timestamp,
            quorum: beacon.quorum,
            catalogHash: beacon.catalogHash,
            signersHash: beacon.signersHash,
            deployer: msg.sender
        });

        emit MemeSpaceGenesis(
            token,
            latestBeaconId,
            beacon.noradId,
            beacon.timestamp,
            beacon.catalogHash,
            msg.sender
        );
    }

    /// @notice Binds an externally created token (e.g. from Flap.sh or Four.meme) to the latest space beacon.
    function bindSpaceGenesis(address tokenAddress) external {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (provenances[tokenAddress].genesisTimestamp != 0) revert AlreadyBound();

        uint256 latestBeaconId = skyRelay.totalBeacons();
        if (latestBeaconId == 0) revert NoActiveSpaceBeacon();

        ISkyRelay.BeaconSummary memory beacon = skyRelay.getBeacon(latestBeaconId);
        if (beacon.timestamp == 0) revert NoActiveSpaceBeacon();

        provenances[tokenAddress] = SpaceProvenance({
            beaconId: latestBeaconId,
            noradId: beacon.noradId,
            genesisTimestamp: beacon.timestamp,
            quorum: beacon.quorum,
            catalogHash: beacon.catalogHash,
            signersHash: beacon.signersHash,
            deployer: msg.sender
        });

        emit MemeSpaceGenesis(
            tokenAddress,
            latestBeaconId,
            beacon.noradId,
            beacon.timestamp,
            beacon.catalogHash,
            msg.sender
        );
    }

    /// @notice Returns the full space provenance of a token.
    function getProvenance(address token) external view returns (SpaceProvenance memory) {
        return provenances[token];
    }
}
