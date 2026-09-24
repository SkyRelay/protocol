// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EquivocationBond} from "../src/EquivocationBond.sol";
import {IStatementAdapter} from "../src/interfaces/IStatementAdapter.sol";
import {SkyRelayStatementAdapter} from "../src/adapters/SkyRelayStatementAdapter.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {CatalogRegistry} from "../src/CatalogRegistry.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";

contract Vault {
    receive() external payable {}
}

/// @notice Generic Price Oracle Statement Adapter proving non-satellite applicability.
contract MockPriceOracleAdapter is IStatementAdapter {
    struct PriceReport {
        address reporter;
        uint64 epochRound;
        uint256 bnbPriceUsd;
    }

    function parseStatement(bytes calldata statement)
        external
        pure
        override
        returns (address subject, bytes32 slot, bytes32 digest)
    {
        PriceReport memory report = abi.decode(statement, (PriceReport));
        subject = report.reporter;
        slot = bytes32(uint256(report.epochRound));
        digest = keccak256(abi.encode(report.reporter, report.epochRound, report.bnbPriceUsd));
    }
}

contract EquivocationBondTest is Test {
    uint256 internal constant PK_A = 0xA11CE;
    uint256 internal constant PK_B = 0xB0B;
    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant UNBONDING_PERIOD = 7 days;
    uint16 internal constant REPORTER_BOUNTY_BPS = 1000; // 10%

    address internal attesterA;
    address internal attesterB;
    address internal owner = makeAddr("owner");
    address internal opA = makeAddr("opA");
    address internal opB = makeAddr("opB");

    Vault internal vault;
    CatalogRegistry internal catalog;
    SkyRelayBond internal dummyBonds;
    SkyRelayBeacon internal beacon;
    SkyRelayStatementAdapter internal skyAdapter;
    EquivocationBond internal skyBond;

    MockPriceOracleAdapter internal priceAdapter;
    EquivocationBond internal priceBond;

    bytes32 internal constant CATALOG = keccak256("catalog-2026-263");

    function setUp() public {
        attesterA = vm.addr(PK_A);
        attesterB = vm.addr(PK_B);

        vault = new Vault();
        catalog = new CatalogRegistry(owner);

        // Deploy dummy beacon & bonds for SkyRelay adapter testing
        uint64 nonce = vm.getNonce(address(this));
        address predictedBeacon = vm.computeCreateAddress(address(this), nonce + 1);
        dummyBonds = new SkyRelayBond(MIN_BOND, UNBONDING_PERIOD, REPORTER_BOUNTY_BPS, address(vault), predictedBeacon);
        beacon = new SkyRelayBeacon(owner, attesterA, address(vault), address(catalog), address(dummyBonds));

        skyAdapter = new SkyRelayStatementAdapter(address(beacon));
        skyBond = new EquivocationBond(
            MIN_BOND,
            UNBONDING_PERIOD,
            REPORTER_BOUNTY_BPS,
            address(vault),
            address(skyAdapter)
        );

        priceAdapter = new MockPriceOracleAdapter();
        priceBond = new EquivocationBond(
            MIN_BOND,
            UNBONDING_PERIOD,
            REPORTER_BOUNTY_BPS,
            address(vault),
            address(priceAdapter)
        );

        vm.deal(attesterA, 10 ether);
        vm.deal(attesterB, 10 ether);
    }

    function _att(address operator) internal view returns (SkyRelayBeacon.SkyRelayAttestation memory a) {
        a.operator = operator;
        a.telemetryHash = keccak256(abi.encodePacked("telemetry", operator));
        a.catalogHash = CATALOG;
        a.noradId = 44714;
        a.elevationMilliDeg = 48_229;
        a.dopplerHz = 171_617;
        a.snrMilliDb = 8700;
        a.asn = 14593;
        a.timestamp = uint64(block.timestamp);
    }

    function _signSky(uint256 pk, SkyRelayBeacon.SkyRelayAttestation memory a) internal view returns (bytes memory) {
        bytes32 digest = beacon.hashAttestation(a, block.chainid, address(beacon));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ── Generic Bonding Tests ──────────────────────────────────────────────

    function test_genericBondingLifecycle() public {
        vm.prank(attesterA);
        skyBond.bond{value: MIN_BOND}();

        assertTrue(skyBond.isActive(attesterA));
        assertEq(skyBond.bonded(attesterA), MIN_BOND);

        // Request unbond
        vm.prank(attesterA);
        skyBond.requestUnbond();
        assertFalse(skyBond.isActive(attesterA));

        // Withdraw before period reverts
        vm.prank(attesterA);
        vm.expectRevert(EquivocationBond.TooEarly.selector);
        skyBond.withdraw();

        // Withdraw after period succeeds
        vm.warp(block.timestamp + UNBONDING_PERIOD + 1);
        uint256 balBefore = attesterA.balance;
        vm.prank(attesterA);
        skyBond.withdraw();
        assertEq(attesterA.balance, balBefore + MIN_BOND);
    }

    // ── Generic SkyRelay Adapter Slashes ────────────────────────────────────

    function test_slashSkyRelayEquivocationViaGenericBond() public {
        vm.prank(attesterA);
        skyBond.bond{value: MIN_BOND}();

        SkyRelayBeacon.SkyRelayAttestation memory a = _att(opA);
        SkyRelayBeacon.SkyRelayAttestation memory b = _att(opA);
        b.dopplerHz = 999_999; // Contradictory Doppler for same station-second

        bytes memory sigA = _signSky(PK_A, a);
        bytes memory sigB = _signSky(PK_A, b);

        address reporter = makeAddr("whistleblower");
        vm.deal(reporter, 0);

        vm.prank(reporter);
        uint256 slashed = skyBond.slashGenericEquivocation(
            EquivocationBond.EquivocationProof({
                statementA: abi.encode(a),
                sigA: sigA,
                statementB: abi.encode(b),
                sigB: sigB
            })
        );

        assertEq(slashed, MIN_BOND);
        assertFalse(skyBond.isActive(attesterA));
        assertTrue(skyBond.slashed(attesterA));

        // 10% bounty paid to whistleblower
        assertEq(reporter.balance, MIN_BOND / 10);
        // 90% remainder in vault
        assertEq(address(vault).balance, (MIN_BOND * 9) / 10);
    }

    // ── Generic Price Oracle Adapter Slashes (Non-satellite proof!) ──────────

    function test_slashGenericPriceOracleEquivocation() public {
        vm.prank(attesterB);
        priceBond.bond{value: 2 ether}();

        // Attester B reports two different BNB prices for the exact same epoch round 42
        MockPriceOracleAdapter.PriceReport memory report1 = MockPriceOracleAdapter.PriceReport({
            reporter: opB,
            epochRound: 42,
            bnbPriceUsd: 600 * 1e18
        });
        MockPriceOracleAdapter.PriceReport memory report2 = MockPriceOracleAdapter.PriceReport({
            reporter: opB,
            epochRound: 42,
            bnbPriceUsd: 650 * 1e18
        });

        bytes32 digest1 = keccak256(abi.encode(report1.reporter, report1.epochRound, report1.bnbPriceUsd));
        bytes32 digest2 = keccak256(abi.encode(report2.reporter, report2.epochRound, report2.bnbPriceUsd));

        bytes memory sig1 = _signDigest(PK_B, digest1);
        bytes memory sig2 = _signDigest(PK_B, digest2);

        address whistleblower = makeAddr("priceWhistleblower");
        vm.deal(whistleblower, 0);

        vm.prank(whistleblower);
        uint256 slashed = priceBond.slashGenericEquivocation(
            EquivocationBond.EquivocationProof({
                statementA: abi.encode(report1),
                sigA: sig1,
                statementB: abi.encode(report2),
                sigB: sig2
            })
        );

        assertEq(slashed, 2 ether);
        assertFalse(priceBond.isActive(attesterB));
        assertTrue(priceBond.slashed(attesterB));
        assertEq(whistleblower.balance, 0.2 ether); // 10% bounty
    }
}
