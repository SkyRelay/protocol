// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";
import {CatalogRegistry} from "../src/CatalogRegistry.sol";
import {FlapSpaceGenesis, SpaceGenesisToken} from "../src/adapters/FlapSpaceGenesis.sol";

contract Vault {
    receive() external payable {}
}

contract OwnedToken {
    address public owner;
    constructor(address o) { owner = o; }
}

contract GetOwnedToken {
    address public getOwner;
    constructor(address o) { getOwner = o; }
}

contract NoOwnerToken {
    uint256 public totalSupply = 1;
}

contract GasBurnerToken {
    function owner() external view returns (address) {
        uint256 x;
        while (true) { x += gasleft(); }
        return address(uint160(x));
    }
}

contract DirtyOwnerToken {
    function owner() external pure returns (uint256) {
        return type(uint256).max; // not a clean address word
    }
}

contract MockResolver {
    mapping(address => address) public creatorOf;
    function set(address token, address creator) external { creatorOf[token] = creator; }
}

contract MockLaunchpad {
    FlapSpaceGenesis internal immutable binder;
    constructor(FlapSpaceGenesis b) { binder = b; }
    function launch(address creator) external returns (address token) {
        token = address(new NoOwnerToken());
        binder.bindFromFactory(token, creator, 0);
    }
}

contract FlapSpaceGenesisTest is Test {
    uint256 internal constant PK_A = 0xA11CE;
    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant UNBONDING_PERIOD = 7 days;
    uint16 internal constant REPORTER_BOUNTY_BPS = 1000;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    Vault internal vault;
    CatalogRegistry internal catalog;
    SkyRelayBond internal bonds;
    SkyRelayBeacon internal beacon;
    FlapSpaceGenesis internal factory;
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant CATALOG = keccak256("catalog-2026-starlink");

    function setUp() public {
        vault = new Vault();
        catalog = new CatalogRegistry(owner);
        uint64 nonce = vm.getNonce(address(this));
        address predictedBeacon = vm.computeCreateAddress(address(this), nonce + 1);
        bonds = new SkyRelayBond(MIN_BOND, UNBONDING_PERIOD, REPORTER_BOUNTY_BPS, address(vault), predictedBeacon);
        beacon = new SkyRelayBeacon(owner, vm.addr(PK_A), address(vault), address(catalog), address(bonds));
        assertEq(address(beacon), predictedBeacon);
        vm.warp(1_789_918_203);

        vm.prank(owner);
        catalog.register(CATALOG, "gnfd://skyrelay-catalog/test.tle");

        address attester = vm.addr(PK_A);
        vm.deal(attester, 10 ether);
        vm.prank(attester);
        bonds.bond{value: MIN_BOND}();

        factory = new FlapSpaceGenesis(address(beacon), owner);
    }

    function _recordBeacon() internal {
        address op = vm.addr(PK_A);
        SkyRelayBeacon.SkyRelayAttestation memory a;
        a.operator = op;
        a.telemetryHash = keccak256(abi.encodePacked("telemetry", op, block.timestamp));
        a.catalogHash = CATALOG;
        a.noradId = 47887; // STARLINK-2346
        a.elevationMilliDeg = 75_202;
        a.dopplerHz = -9908;
        a.snrMilliDb = 8700;
        a.asn = 14593;
        a.timestamp = uint64(block.timestamp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK_A, beacon.hashAttestation(a, block.chainid, address(beacon)));
        bytes memory sig = abi.encodePacked(r, s, v);

        SkyRelayBeacon.SkyRelayAttestation[] memory atts = new SkyRelayBeacon.SkyRelayAttestation[](1);
        atts[0] = a;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        vm.prank(op);
        beacon.verifyAndRecord(atts, sigs);
    }

    function test_revertsIfZeroBeaconAddress() public {
        vm.expectRevert(FlapSpaceGenesis.ZeroAddress.selector);
        new FlapSpaceGenesis(address(0), owner);
    }

    function test_revertsIfZeroAdminAddress() public {
        vm.expectRevert(FlapSpaceGenesis.ZeroAddress.selector);
        new FlapSpaceGenesis(address(beacon), address(0));
    }

    function test_revertsIfNoActiveBeacon() public {
        vm.prank(user);
        vm.expectRevert(FlapSpaceGenesis.NoActiveSpaceBeacon.selector);
        factory.createTokenWithSpaceGenesis("MoonCoin", "MOON");
    }

    function test_createTokenWithSpaceGenesisSuccess() public {
        _recordBeacon();
        vm.prank(user);
        address tokenAddr = factory.createTokenWithSpaceGenesis("SpaceMeme", "ORBIT");
        SpaceGenesisToken token = SpaceGenesisToken(tokenAddr);
        assertEq(token.balanceOf(user), 1_000_000_000 * 10 ** 18);
        assertEq(token.owner(), user);
        FlapSpaceGenesis.SpaceProvenance memory p = factory.getProvenance(tokenAddr);
        assertEq(p.beaconId, 1);
        assertEq(p.noradId, 47887);
        assertEq(p.quorum, 1);
        assertEq(p.catalogHash, CATALOG);
        assertEq(p.deployer, user);
        assertEq(uint8(p.authPath), uint8(FlapSpaceGenesis.AuthPath.Created));
    }

    // ---------- owner() and getOwner() path

    function test_ownerCanBind() public {
        _recordBeacon();
        address tok = address(new OwnedToken(user));
        vm.prank(user);
        factory.bindSpaceGenesis(tok, 1);
        FlapSpaceGenesis.SpaceProvenance memory p = factory.getProvenance(tok);
        assertEq(p.deployer, user);
        assertEq(uint8(p.authPath), uint8(FlapSpaceGenesis.AuthPath.TokenOwner));
        vm.prank(user);
        vm.expectRevert(FlapSpaceGenesis.AlreadyBound.selector);
        factory.bindSpaceGenesis(tok, 0);
    }

    function test_ownerCanBindWithSingleArgOverload() public {
        _recordBeacon();
        address tok = address(new OwnedToken(user));
        vm.prank(user);
        factory.bindSpaceGenesis(tok);
        FlapSpaceGenesis.SpaceProvenance memory p = factory.getProvenance(tok);
        assertEq(p.deployer, user);
        assertEq(uint8(p.authPath), uint8(FlapSpaceGenesis.AuthPath.TokenOwner));
    }

    function test_bep20GetOwnerCanBind() public {
        _recordBeacon();
        address tok = address(new GetOwnedToken(user));
        vm.prank(user);
        factory.bindSpaceGenesis(tok, 1);
        FlapSpaceGenesis.SpaceProvenance memory p = factory.getProvenance(tok);
        assertEq(p.deployer, user);
        assertEq(uint8(p.authPath), uint8(FlapSpaceGenesis.AuthPath.TokenOwner));
    }

    function test_frontRunnerCannotSquatOwnedToken() public {
        _recordBeacon();
        address tok = address(new OwnedToken(user));
        vm.prank(attacker);
        vm.expectRevert(FlapSpaceGenesis.NotAuthorized.selector);
        factory.bindSpaceGenesis(tok, 0);
        // the real owner is still free to bind afterwards
        vm.prank(user);
        factory.bindSpaceGenesis(tok, 0);
        assertEq(factory.getProvenance(tok).deployer, user);
    }

    function test_renouncedTokenCannotBindViaOwnerPath() public {
        _recordBeacon();
        address tok = address(new OwnedToken(address(0)));
        vm.prank(user);
        vm.expectRevert(FlapSpaceGenesis.NotAuthorized.selector);
        factory.bindSpaceGenesis(tok, 0);
    }

    function test_tokenWithoutOwnerFnReverts() public {
        _recordBeacon();
        address tok = address(new NoOwnerToken());
        vm.prank(user);
        vm.expectRevert(FlapSpaceGenesis.NotAuthorized.selector);
        factory.bindSpaceGenesis(tok, 0);
    }

    function test_gasBurningOwnerFnIsContained() public {
        _recordBeacon();
        address tok = address(new GasBurnerToken());
        vm.prank(user);
        vm.expectRevert(FlapSpaceGenesis.NotAuthorized.selector);
        factory.bindSpaceGenesis(tok, 0);
    }

    function test_dirtyOwnerWordRejected() public {
        _recordBeacon();
        address tok = address(new DirtyOwnerToken());
        vm.prank(address(type(uint160).max));
        vm.expectRevert(FlapSpaceGenesis.NotAuthorized.selector);
        factory.bindSpaceGenesis(tok, 0);
    }

    function test_eoaTargetReverts() public {
        _recordBeacon();
        vm.prank(user);
        vm.expectRevert(FlapSpaceGenesis.NotContract.selector);
        factory.bindSpaceGenesis(makeAddr("eoa"), 0);
    }

    function test_beaconMismatchReverts() public {
        _recordBeacon();
        address tok = address(new OwnedToken(user));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlapSpaceGenesis.BeaconMismatch.selector, uint256(1)));
        factory.bindSpaceGenesis(tok, 2);
    }

    // ---------- resolver path (renounced Flap / Four.meme tokens)

    function _activeResolver() internal returns (MockResolver r) {
        r = new MockResolver();
        vm.prank(owner);
        factory.scheduleResolver(address(r));
        vm.warp(block.timestamp + 2 days);
    }

    function test_resolverCreatorCanBind() public {
        MockResolver r = _activeResolver();
        _recordBeacon();
        address tok = address(new NoOwnerToken());
        r.set(tok, user);
        vm.prank(attacker);
        vm.expectRevert(FlapSpaceGenesis.NotAuthorized.selector);
        factory.bindSpaceGenesisVia(tok, address(r), 0);
        vm.prank(user);
        factory.bindSpaceGenesisVia(tok, address(r), 0);
        FlapSpaceGenesis.SpaceProvenance memory p = factory.getProvenance(tok);
        assertEq(p.deployer, user);
        assertEq(uint8(p.authPath), uint8(FlapSpaceGenesis.AuthPath.Resolver));
    }

    function test_attackerResolverRejected() public {
        _recordBeacon();
        MockResolver evil = new MockResolver();
        address tok = address(new NoOwnerToken());
        evil.set(tok, attacker);
        vm.prank(attacker);
        vm.expectRevert(FlapSpaceGenesis.UnknownResolver.selector);
        factory.bindSpaceGenesisVia(tok, address(evil), 0);
    }

    function test_resolverTimelock() public {
        MockResolver r = new MockResolver();
        vm.prank(owner);
        factory.scheduleResolver(address(r));
        assertFalse(factory.isResolverActive(address(r)));
        vm.warp(block.timestamp + 2 days - 1);
        assertFalse(factory.isResolverActive(address(r)));
        vm.warp(block.timestamp + 1);
        assertTrue(factory.isResolverActive(address(r)));
        vm.prank(owner);
        factory.removeResolver(address(r));
        assertFalse(factory.isResolverActive(address(r)));
    }

    function test_onlyAdminSchedules() public {
        vm.prank(attacker);
        vm.expectRevert(FlapSpaceGenesis.NotAdmin.selector);
        factory.scheduleResolver(attacker);
        vm.prank(attacker);
        vm.expectRevert(FlapSpaceGenesis.NotAdmin.selector);
        factory.scheduleFactory(attacker);
    }

    // ---------- factory callback path

    function test_launchpadCallbackBinds() public {
        MockLaunchpad pad = new MockLaunchpad(factory);
        vm.prank(owner);
        factory.scheduleFactory(address(pad));
        vm.warp(block.timestamp + 2 days);
        _recordBeacon();
        address tok = pad.launch(user);
        FlapSpaceGenesis.SpaceProvenance memory p = factory.getProvenance(tok);
        assertEq(p.deployer, user);
        assertEq(uint8(p.authPath), uint8(FlapSpaceGenesis.AuthPath.Factory));
    }

    function test_unlistedFactoryCallbackReverts() public {
        _recordBeacon();
        address tok = address(new NoOwnerToken());
        vm.prank(attacker);
        vm.expectRevert(FlapSpaceGenesis.UnknownFactory.selector);
        factory.bindFromFactory(tok, attacker, 0);
    }

    function test_adminTransferTwoStep() public {
        vm.prank(owner);
        factory.transferAdmin(user);
        assertEq(factory.admin(), owner);
        vm.prank(attacker);
        vm.expectRevert(FlapSpaceGenesis.NotAdmin.selector);
        factory.acceptAdmin();
        vm.prank(user);
        factory.acceptAdmin();
        assertEq(factory.admin(), user);
    }
}
