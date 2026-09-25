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

        factory = new FlapSpaceGenesis(address(beacon));
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
        new FlapSpaceGenesis(address(0));
    }

    function test_revertsIfNoActiveBeacon() public {
        vm.prank(user);
        vm.expectRevert(FlapSpaceGenesis.NoActiveSpaceBeacon.selector);
        factory.createTokenWithSpaceGenesis("MoonCoin", "MOON");
    }

    function test_createTokenWithSpaceGenesisSuccess() public {
        _recordBeacon();
        assertEq(beacon.totalBeacons(), 1);

        vm.prank(user);
        address tokenAddr = factory.createTokenWithSpaceGenesis("SpaceMeme", "ORBIT");

        assertTrue(tokenAddr != address(0));
        SpaceGenesisToken token = SpaceGenesisToken(tokenAddr);
        assertEq(token.name(), "SpaceMeme");
        assertEq(token.symbol(), "ORBIT");
        assertEq(token.balanceOf(user), 1_000_000_000 * 10 ** 18);

        FlapSpaceGenesis.SpaceProvenance memory p = factory.getProvenance(tokenAddr);
        assertEq(p.beaconId, 1);
        assertEq(p.noradId, 47887);
        assertEq(p.genesisTimestamp, block.timestamp);
        assertEq(p.quorum, 1);
        assertEq(p.catalogHash, CATALOG);
        assertEq(p.deployer, user);
    }

    function test_bindExistingTokenSuccess() public {
        _recordBeacon();

        address existingToken = makeAddr("mockToken");
        vm.prank(user);
        factory.bindSpaceGenesis(existingToken);

        FlapSpaceGenesis.SpaceProvenance memory p = factory.getProvenance(existingToken);
        assertEq(p.beaconId, 1);
        assertEq(p.noradId, 47887);
        assertEq(p.deployer, user);

        // Binding again should revert AlreadyBound
        vm.expectRevert(FlapSpaceGenesis.AlreadyBound.selector);
        factory.bindSpaceGenesis(existingToken);
    }
}
