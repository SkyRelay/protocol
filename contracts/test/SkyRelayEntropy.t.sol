// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayBeacon} from "../src/SkyRelayBeacon.sol";
import {SkyRelayBond} from "../src/SkyRelayBond.sol";
import {SkyRelayEntropy} from "../src/SkyRelayEntropy.sol";
import {CatalogRegistry} from "../src/CatalogRegistry.sol";
import {MockRandomnessConsumer} from "./mock/MockRandomnessConsumer.sol";

contract Vault {
    receive() external payable {}
}

/// @notice Commit-reveal beacon. A sighting admits a bonded signer; the seed
///         is the XOR of the secrets that were actually revealed.
contract SkyRelayEntropyTest is Test {
    uint256 internal constant PK_A = 0xA11CE;
    uint256 internal constant PK_B = 0xB0B;
    uint256 internal constant PK_C = 0xC0FFEE;
    uint256 internal constant MIN_BOND = 1 ether;
    uint64 internal constant UNBONDING_PERIOD = 7 days;
    uint16 internal constant REPORTER_BOUNTY_BPS = 1000;
    uint64 internal constant ROUND_SECONDS = 3600;
    uint256 internal constant DEPOSIT = 0.05 ether;

    address internal owner = makeAddr("owner");
    address internal opA = makeAddr("opA");
    address internal opB = makeAddr("opB");

    Vault internal vault;
    CatalogRegistry internal catalog;
    SkyRelayBond internal bonds;
    SkyRelayBeacon internal beacon;
    SkyRelayEntropy internal entropy;

    uint64 internal baseRound;

    bytes32 internal constant CATALOG = keccak256("catalog-2026-263");

    function setUp() public {
        vm.warp(1_700_000_000);
        vault = new Vault();
        catalog = new CatalogRegistry(owner);
        uint64 nonce = vm.getNonce(address(this));
        address predictedBeacon = vm.computeCreateAddress(address(this), nonce + 1);
        bonds = new SkyRelayBond(MIN_BOND, UNBONDING_PERIOD, REPORTER_BOUNTY_BPS, address(vault), predictedBeacon);
        beacon = new SkyRelayBeacon(owner, vm.addr(PK_A), address(vault), address(catalog), address(bonds));
        entropy = new SkyRelayEntropy(owner, address(vault), address(bonds), address(beacon), ROUND_SECONDS, DEPOSIT);
        assertEq(address(beacon), predictedBeacon);

        vm.prank(owner);
        catalog.register(CATALOG, "gnfd://skyrelay-catalog/test.tle");

        _bond(vm.addr(PK_A));

        vm.prank(owner);
        beacon.scheduleAttester(vm.addr(PK_B));
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(vm.addr(PK_B));
        _bond(vm.addr(PK_B));

        uint256 ts = block.timestamp;
        vm.warp(ts - (ts % ROUND_SECONDS) + 500);
        baseRound = entropy.currentRound();
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _bond(address who) internal {
        vm.deal(who, 10 ether);
        vm.prank(who);
        bonds.bond{value: MIN_BOND}();
    }

    function _enter(uint64 round) internal {
        vm.warp(uint256(round) * ROUND_SECONDS + 500);
        assertEq(entropy.currentRound(), round);
    }

    function _commitment(bytes32 secret, address who, uint64 round) internal pure returns (bytes32) {
        return keccak256(abi.encode(secret, who, round));
    }

    function _commit(uint256 pk, uint64 round, bytes32 secret) internal {
        address who = vm.addr(pk);
        vm.prank(who);
        entropy.commit{value: DEPOSIT}(round, _commitment(secret, who, round));
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

    function _sign(uint256 pk, SkyRelayBeacon.SkyRelayAttestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, beacon.hashAttestation(a, block.chainid, address(beacon)));
        return abi.encodePacked(r, s, v);
    }

    function _one(SkyRelayBeacon.SkyRelayAttestation memory a)
        internal
        pure
        returns (SkyRelayBeacon.SkyRelayAttestation[] memory out)
    {
        out = new SkyRelayBeacon.SkyRelayAttestation[](1);
        out[0] = a;
    }

    function _one(bytes memory sig) internal pure returns (bytes[] memory out) {
        out = new bytes[](1);
        out[0] = sig;
    }

    function _signers(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _signers(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _record(address operator, uint256 pk, bytes32 salt) internal returns (uint256 id) {
        SkyRelayBeacon.SkyRelayAttestation memory a = _att(operator);
        a.telemetryHash = salt;
        bytes[] memory sigs = _one(_sign(pk, a));
        vm.prank(operator);
        id = beacon.verifyAndRecord(_one(a), sigs);
    }

    function _reveal(uint256 pk, uint64 round, uint256 beaconId, bytes32 secret) internal {
        address who = vm.addr(pk);
        vm.prank(who);
        entropy.reveal(round, beaconId, secret, _signers(who));
    }

    function _expectedSeed(bytes32 secretA, bytes32 secretB, uint64 round, bool both) internal pure returns (bytes32) {
        uint256 acc = uint256(secretA);
        uint32 n = 1;
        if (both) {
            acc ^= uint256(secretB);
            n = 2;
        }
        return keccak256(abi.encode(acc, round, n));
    }

    // ── commit window ───────────────────────────────────────────────────────

    function test_commitInTheWrongRoundReverts() public {
        address who = vm.addr(PK_A);
        bytes32 c = _commitment(bytes32("s"), who, baseRound);
        vm.startPrank(who);
        vm.expectRevert(SkyRelayEntropy.CommitWindowClosed.selector);
        entropy.commit{value: DEPOSIT}(baseRound, c);
        vm.expectRevert(SkyRelayEntropy.CommitWindowClosed.selector);
        entropy.commit{value: DEPOSIT}(baseRound + 1, c);
        vm.expectRevert(SkyRelayEntropy.CommitWindowClosed.selector);
        entropy.commit{value: DEPOSIT}(baseRound + 3, c);
        vm.stopPrank();
    }

    function test_commitFromUnbondedAddressReverts() public {
        uint64 round = baseRound + 2;
        address stranger = makeAddr("stranger");
        vm.deal(stranger, DEPOSIT);
        vm.prank(stranger);
        vm.expectRevert(SkyRelayEntropy.NotBonded.selector);
        entropy.commit{value: DEPOSIT}(round, _commitment(bytes32("s"), stranger, round));

        // Registered with the beacon, but no bond: still not admitted.
        vm.prank(owner);
        beacon.scheduleAttester(vm.addr(PK_C));
        vm.warp(block.timestamp + beacon.ROTATION_DELAY());
        beacon.activateAttester(vm.addr(PK_C));
        _enter(entropy.currentRound());
        uint64 later = entropy.currentRound() + 2;
        address unbonded = vm.addr(PK_C);
        vm.deal(unbonded, DEPOSIT);
        vm.prank(unbonded);
        vm.expectRevert(SkyRelayEntropy.NotBonded.selector);
        entropy.commit{value: DEPOSIT}(later, _commitment(bytes32("s"), unbonded, later));
    }

    function test_commitRejectsASecondCommitmentAndAWrongDeposit() public {
        uint64 round = baseRound + 2;
        _commit(PK_A, round, bytes32("s"));
        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayEntropy.AlreadyCommitted.selector);
        entropy.commit{value: DEPOSIT}(round, _commitment(bytes32("other"), vm.addr(PK_A), round));

        vm.prank(vm.addr(PK_B));
        vm.expectRevert(SkyRelayEntropy.BadDeposit.selector);
        entropy.commit{value: DEPOSIT - 1}(round, _commitment(bytes32("b"), vm.addr(PK_B), round));
    }

    function test_gasCommit() public {
        uint64 round = baseRound + 2;
        address who = vm.addr(PK_A);
        bytes32 secret = bytes32(uint256(7));
        bytes32 c = _commitment(secret, who, round);
        vm.prank(who);
        entropy.commit{value: DEPOSIT}(round, c);
        assertEq(entropy.commitmentOf(round, who), c);
        (uint256 acc, uint32 commits,,,) = entropy.rounds(round);
        assertEq(acc, 0);
        assertEq(commits, 1);
        assertEq(address(entropy).balance, DEPOSIT);
    }

    // ── reveal ──────────────────────────────────────────────────────────────

    function test_revealWithMismatchedSecretReverts() public {
        uint64 round = baseRound + 2;
        bytes32 secret = bytes32(uint256(11));
        _enter(round - 2);
        _commit(PK_A, round, secret);
        _enter(round);
        uint256 id = _record(opA, PK_A, keccak256("mismatch"));
        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayEntropy.CommitmentMismatch.selector);
        entropy.reveal(round, id, bytes32(uint256(12)), _signers(vm.addr(PK_A)));
    }

    function test_revealWithAnotherAddressCommitmentReverts() public {
        uint64 round = baseRound + 2;
        bytes32 secretA = bytes32(uint256(21));
        bytes32 secretB = bytes32(uint256(22));
        _enter(round - 2);
        _commit(PK_A, round, secretA);
        _commit(PK_B, round, secretB);
        _enter(round);
        uint256 idB = _record(opB, PK_B, keccak256("other-addr"));
        // B knows A's secret and A's commitment. The preimage binds the sender.
        vm.prank(vm.addr(PK_B));
        vm.expectRevert(SkyRelayEntropy.CommitmentMismatch.selector);
        entropy.reveal(round, idB, secretA, _signers(vm.addr(PK_B)));
    }

    /// @dev The replay the sender binding exists to stop. B copies A's
    ///      commitment verbatim and registers it under B's own address in the
    ///      same round, then tries to open it with A's secret — which B learns
    ///      the moment A's reveal is in the mempool. Without `msg.sender` in
    ///      the preimage this would succeed and hand B a second contribution.
    ///
    ///      The positive control at the end is load-bearing, not decoration. A
    ///      bare `expectRevert` here passes for any reason at all — including a
    ///      build where the preimage binds nothing and *every* reveal reverts —
    ///      which is exactly the false comfort the warm-path gas guard gave
    ///      before it was fixed. Requiring A to open the same commitment makes
    ///      the test distinguish "B is rejected" from "nobody can reveal".
    function test_copiedCommitmentDoesNotOpenForAnotherSender() public {
        uint64 round = baseRound + 2;
        bytes32 secretA = bytes32(uint256(41));
        _enter(round - 2);
        bytes32 copied = _commitment(secretA, vm.addr(PK_A), round);
        _commit(PK_A, round, secretA);
        vm.prank(vm.addr(PK_B));
        entropy.commit{value: DEPOSIT}(round, copied);

        _enter(round);
        uint256 idB = _record(opB, PK_B, keccak256("copied-commitment"));
        vm.prank(vm.addr(PK_B));
        vm.expectRevert(SkyRelayEntropy.CommitmentMismatch.selector);
        entropy.reveal(round, idB, secretA, _signers(vm.addr(PK_B)));

        uint256 idA = _record(opA, PK_A, keccak256("copied-commitment-owner"));
        _reveal(PK_A, round, idA, secretA);
        assertTrue(entropy.revealedIn(round, vm.addr(PK_A)), "the owner must still be able to open it");
        assertFalse(entropy.revealedIn(round, vm.addr(PK_B)));
    }

    function test_commitmentDoesNotOpenInAnotherRound() public {
        bytes32 secret = bytes32(uint256(31));
        uint64 first = baseRound + 2;
        _enter(first - 2);
        bytes32 copied = _commitment(secret, vm.addr(PK_A), first);
        _commit(PK_A, first, secret);

        uint64 second = first + 3;
        _enter(second - 2);
        vm.prank(vm.addr(PK_A));
        entropy.commit{value: DEPOSIT}(second, copied);

        _enter(second);
        uint256 id = _record(opA, PK_A, keccak256("replay-round"));
        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayEntropy.CommitmentMismatch.selector);
        entropy.reveal(second, id, secret, _signers(vm.addr(PK_A)));
    }

    function test_revealWithoutQualifyingBeaconReverts() public {
        uint64 round = baseRound + 2;
        bytes32 secret = bytes32(uint256(41));
        _enter(round - 2);
        _commit(PK_A, round, secret);
        _enter(round);
        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayBeacon.UnknownBeacon.selector);
        entropy.reveal(round, 0, secret, _signers(vm.addr(PK_A)));
    }

    function test_revealWithBeaconFromAnotherRoundReverts() public {
        uint64 round = baseRound + 2;
        bytes32 secret = bytes32(uint256(51));
        _enter(round - 2);
        _commit(PK_A, round, secret);
        uint256 early = _record(opA, PK_A, keccak256("early-sighting"));
        _enter(round);
        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayEntropy.SightingOutsideRound.selector);
        entropy.reveal(round, early, secret, _signers(vm.addr(PK_A)));
    }

    function test_revealCallerDidNotSignBeaconReverts() public {
        uint64 round = baseRound + 2;
        bytes32 secretB = bytes32(uint256(62));
        _enter(round - 2);
        _commit(PK_B, round, secretB);
        _enter(round);
        uint256 idA = _record(opA, PK_A, keccak256("signed-by-a"));
        vm.prank(vm.addr(PK_B));
        vm.expectRevert(SkyRelayEntropy.NotBeaconSigner.selector);
        entropy.reveal(round, idA, secretB, _signers(vm.addr(PK_A)));
    }

    function test_revealWithMismatchedSignerArrayReverts() public {
        uint64 round = baseRound + 2;
        bytes32 secret = bytes32(uint256(71));
        _enter(round - 2);
        _commit(PK_A, round, secret);
        _enter(round);
        uint256 id = _record(opA, PK_A, keccak256("signer-array"));
        address[] memory swapped = _signers(vm.addr(PK_B), vm.addr(PK_A));
        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayEntropy.SignersMismatch.selector);
        entropy.reveal(round, id, secret, swapped);
    }

    function test_gasReveal() public {
        uint64 round = baseRound + 2;
        bytes32 secret = bytes32(uint256(81));
        _enter(round - 2);
        _commit(PK_A, round, secret);
        _enter(round);
        uint256 id = _record(opA, PK_A, keccak256("gas-reveal"));
        uint256 before = vm.addr(PK_A).balance;
        _reveal(PK_A, round, id, secret);
        assertEq(vm.addr(PK_A).balance, before + DEPOSIT);
        (, uint32 commits, uint32 reveals,,) = entropy.rounds(round);
        assertEq(commits, 1);
        assertEq(reveals, 1);
        assertTrue(entropy.revealedIn(round, vm.addr(PK_A)));
    }

    function test_twoHonestParticipantsSeedIsXor() public {
        uint64 round = baseRound + 2;
        bytes32 secretA = bytes32(uint256(0xA1));
        bytes32 secretB = bytes32(uint256(0xB2));
        _enter(round - 2);
        _commit(PK_A, round, secretA);
        _commit(PK_B, round, secretB);

        vm.prank(owner);
        beacon.setQuorumThreshold(2);
        _enter(round);

        SkyRelayBeacon.SkyRelayAttestation[] memory atts = new SkyRelayBeacon.SkyRelayAttestation[](2);
        atts[0] = _att(opA);
        atts[1] = _att(opB);
        atts[0].telemetryHash = keccak256("quorum-a");
        atts[1].telemetryHash = keccak256("quorum-b");
        atts[1].elevationMilliDeg = 30_351;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(PK_A, atts[0]);
        sigs[1] = _sign(PK_B, atts[1]);
        vm.prank(opA);
        uint256 id = beacon.verifyAndRecord(atts, sigs);
        address[] memory signers = _signers(vm.addr(PK_A), vm.addr(PK_B));

        // B is the second signer. Admission is membership, not signers[0].
        vm.prank(vm.addr(PK_B));
        entropy.reveal(round, id, secretB, signers);
        vm.prank(vm.addr(PK_A));
        entropy.reveal(round, id, secretA, signers);
        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayEntropy.AlreadyRevealed.selector);
        entropy.reveal(round, id, secretA, signers);

        _enter(round + 1);
        entropy.finalize(round);
        (bytes32 seed, uint32 contributors) = entropy.seedOf(round);
        assertEq(contributors, 2);
        assertEq(seed, _expectedSeed(secretA, secretB, round, true));
    }

    function test_revealOrderDoesNotChangeTheXor() public {
        bytes32 secretA = bytes32(uint256(0x11));
        bytes32 secretB = bytes32(uint256(0x22));
        uint64 first = baseRound + 2;
        bytes32 seedFirst = _seedPair(first, secretA, secretB, true);
        uint64 second = first + 3;
        bytes32 seedSecond = _seedPair(second, secretA, secretB, false);
        assertEq(seedFirst, _expectedSeed(secretA, secretB, first, true));
        assertEq(seedSecond, _expectedSeed(secretA, secretB, second, true));
        assertTrue(seedFirst != seedSecond);
    }

    // ── withhold, empty round, finalize ─────────────────────────────────────

    function test_withheldRevealForfeitsAndRemainingSeedStands() public {
        uint64 round = baseRound + 2;
        bytes32 secretA = bytes32(uint256(0xA));
        bytes32 secretB = bytes32(uint256(0xB));
        _enter(round - 2);
        _commit(PK_A, round, secretA);
        _commit(PK_B, round, secretB);
        _enter(round);
        uint256 idA = _record(opA, PK_A, keccak256("withhold-a"));
        uint256 balA = vm.addr(PK_A).balance;
        uint256 balB = vm.addr(PK_B).balance;
        _reveal(PK_A, round, idA, secretA);
        assertEq(vm.addr(PK_A).balance, balA + DEPOSIT);
        assertEq(vm.addr(PK_B).balance, balB);

        vm.prank(owner);
        vm.expectRevert(SkyRelayEntropy.RoundOpen.selector);
        entropy.sweepForfeited(round);

        _enter(round + 1);
        vm.prank(vm.addr(PK_B));
        vm.expectRevert(SkyRelayEntropy.RevealWindowClosed.selector);
        entropy.reveal(round, idA, secretB, _signers(vm.addr(PK_B)));

        entropy.finalize(round);
        (bytes32 seed, uint32 contributors) = entropy.seedOf(round);
        assertEq(contributors, 1);
        assertEq(seed, _expectedSeed(secretA, secretB, round, false));

        uint256 vaultBefore = address(vault).balance;
        vm.expectEmit(true, true, false, true);
        emit SkyRelayEntropy.DepositForfeited(round, vm.addr(PK_B), DEPOSIT);
        vm.prank(owner);
        entropy.sweepForfeited(round);
        assertEq(address(vault).balance - vaultBefore, DEPOSIT);
        assertEq(address(entropy).balance, 0);

        vm.prank(owner);
        vm.expectRevert(SkyRelayEntropy.AlreadySwept.selector);
        entropy.sweepForfeited(round);
    }

    function test_roundWithNoRevealsFinalizesUnseeded() public {
        uint64 round = baseRound + 2;
        _enter(round - 2);
        _commit(PK_A, round, bytes32("silent"));
        _enter(round + 1);
        vm.expectEmit(true, false, false, true);
        emit SkyRelayEntropy.Finalized(round, bytes32(0), 0);
        entropy.finalize(round);
        vm.expectRevert(SkyRelayEntropy.NoSeed.selector);
        entropy.seedOf(round);

        vm.expectRevert(SkyRelayEntropy.AlreadyFinalized.selector);
        entropy.finalize(round);
    }

    function test_finalizeBeforeTheRoundEndsReverts() public {
        vm.expectRevert(SkyRelayEntropy.RoundOpen.selector);
        entropy.finalize(baseRound);
    }

    function test_strangerCannotSweep() public {
        uint64 round = baseRound + 2;
        _enter(round - 2);
        _commit(PK_A, round, bytes32("sweep-auth"));
        _enter(round + 1);
        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayEntropy.NotOwner.selector);
        entropy.sweepForfeited(round);
    }

    function test_gasFinalize() public {
        uint64 round = baseRound + 2;
        bytes32 secret = bytes32(uint256(91));
        _enter(round - 2);
        _commit(PK_A, round, secret);
        _enter(round);
        uint256 id = _record(opA, PK_A, keccak256("gas-finalize"));
        _reveal(PK_A, round, id, secret);
        _enter(round + 1);
        entropy.finalize(round);
        (bytes32 seed, uint32 contributors) = entropy.seedOf(round);
        assertEq(contributors, 1);
        assertEq(seed, _expectedSeed(secret, bytes32(0), round, false));
    }

    // ── requests ────────────────────────────────────────────────────────────

    function test_requestDuringRoundIsServedByTheNextRound() public {
        uint64 requestRound = baseRound + 1;
        uint64 serving = requestRound + 1;
        bytes32 secret = bytes32(uint256(101));

        _enter(serving - 2);
        _commit(PK_A, serving, secret);

        _enter(requestRound);
        (bytes32 requestId, uint64 got) = entropy.requestRandomness(4);
        assertEq(got, serving);
        vm.expectRevert(SkyRelayEntropy.NotFinalized.selector);
        entropy.randomWords(requestId);

        _enter(serving);
        uint256 id = _record(opA, PK_A, keccak256("served"));
        _reveal(PK_A, serving, id, secret);
        vm.expectRevert(SkyRelayEntropy.NotFinalized.selector);
        entropy.randomWords(requestId);

        _enter(serving + 1);
        entropy.finalize(serving);
        uint256[] memory words = entropy.randomWords(requestId);
        (bytes32 seed,) = entropy.seedOf(serving);
        assertEq(words.length, 4);
        assertEq(words[0], uint256(keccak256(abi.encode(seed, requestId, uint256(0)))));
        assertEq(words[1], uint256(keccak256(abi.encode(seed, requestId, uint256(1)))));
        assertTrue(words[0] != words[1]);
        assertEq(entropy.randomWords(requestId)[3], words[3]);
    }

    function test_unseededRequestIsReservicedByALaterRound() public {
        uint64 requestRound = baseRound;
        (bytes32 requestId, uint64 serving) = entropy.requestRandomness(2);
        assertEq(serving, requestRound + 1);

        // Commits for the round a reservice during requestRound+2 will aim at.
        uint64 later = requestRound + 3;
        _enter(later - 2);
        bytes32 secret = bytes32(uint256(202));
        _commit(PK_A, later, secret);

        _enter(serving + 1);
        entropy.finalize(serving);
        vm.expectRevert(SkyRelayEntropy.NoSeed.selector);
        entropy.seedOf(serving);
        vm.expectRevert(SkyRelayEntropy.NoSeed.selector);
        entropy.randomWords(requestId);

        vm.prank(vm.addr(PK_A));
        vm.expectRevert(SkyRelayEntropy.NotRequester.selector);
        entropy.reservice(requestId);

        uint64 next = entropy.reservice(requestId);
        assertEq(next, later);
        (address requester, uint64 nowServing, uint32 n) = entropy.requests(requestId);
        assertEq(requester, address(this));
        assertEq(nowServing, later);
        assertEq(n, 2);

        _enter(later);
        vm.expectRevert(SkyRelayEntropy.NotFinalized.selector);
        entropy.randomWords(requestId);
        uint256 id = _record(opA, PK_A, keccak256("reservice"));
        _reveal(PK_A, later, id, secret);

        _enter(later + 1);
        entropy.finalize(later);
        uint256[] memory words = entropy.randomWords(requestId);
        (bytes32 seed,) = entropy.seedOf(later);
        assertEq(words[0], uint256(keccak256(abi.encode(seed, requestId, uint256(0)))));
        assertEq(words[1], uint256(keccak256(abi.encode(seed, requestId, uint256(1)))));
        assertTrue(words[0] != words[1]);
    }

    function test_consumerSettlesFromTheServingRound() public {
        uint64 serving = baseRound + 2;
        bytes32 secret = bytes32(uint256(303));
        _enter(serving - 2);
        _commit(PK_A, serving, secret);

        _enter(serving - 1);
        MockRandomnessConsumer consumer = new MockRandomnessConsumer(entropy);
        vm.expectRevert(SkyRelayEntropy.ZeroWords.selector);
        consumer.requestDraw(0);
        uint256 drawId = consumer.requestDraw(3);
        (bytes32 requestId, uint64 got, uint32 numWords, bool settled,) = consumer.draws(drawId);
        assertEq(got, serving);
        assertEq(numWords, 3);
        assertFalse(settled);

        vm.expectRevert(SkyRelayEntropy.NotFinalized.selector);
        consumer.settle(drawId);

        _enter(serving);
        uint256 id = _record(opA, PK_A, keccak256("consumer"));
        _reveal(PK_A, serving, id, secret);
        _enter(serving + 1);
        entropy.finalize(serving);

        uint256 word = consumer.settle(drawId);
        (bytes32 seed,) = entropy.seedOf(serving);
        assertEq(word, uint256(keccak256(abi.encode(seed, requestId, uint256(0)))));
        (,,,, uint256 stored) = consumer.draws(drawId);
        assertEq(stored, word);

        vm.expectRevert(MockRandomnessConsumer.AlreadySettled.selector);
        consumer.settle(drawId);
    }

    function test_consumerReservicesAnUnseededDraw() public {
        MockRandomnessConsumer consumer = new MockRandomnessConsumer(entropy);
        uint256 drawId = consumer.requestDraw(1);
        (, uint64 serving,,,) = consumer.draws(drawId);

        uint64 later = serving + 2;
        _enter(later - 2);
        bytes32 secret = bytes32(uint256(404));
        _commit(PK_A, later, secret);

        _enter(serving + 1);
        entropy.finalize(serving);
        vm.expectRevert(SkyRelayEntropy.NoSeed.selector);
        consumer.settle(drawId);

        uint64 next = consumer.reservice(drawId);
        assertEq(next, later);

        _enter(later);
        uint256 id = _record(opA, PK_A, keccak256("consumer-reservice"));
        _reveal(PK_A, later, id, secret);
        _enter(later + 1);
        entropy.finalize(later);

        (bytes32 requestId,,,,) = consumer.draws(drawId);
        uint256 word = consumer.settle(drawId);
        (bytes32 seed,) = entropy.seedOf(later);
        assertEq(word, uint256(keccak256(abi.encode(seed, requestId, uint256(0)))));
    }

    // ── fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_distinctSecretsGiveDistinctSeeds(bytes32 a, bytes32 b, bytes32 c, bytes32 d) public {
        vm.assume(uint256(a) ^ uint256(b) != uint256(c) ^ uint256(d));
        uint64 first = baseRound + 2;
        bytes32 seedAB = _seedPair(first, a, b, true);
        uint64 second = first + 3;
        bytes32 seedCD = _seedPair(second, c, d, true);
        assertEq(seedAB, _expectedSeed(a, b, first, true));
        assertEq(seedCD, _expectedSeed(c, d, second, true));
        assertTrue(seedAB != seedCD);
    }

    function testFuzz_randomWordsDeterministicInSeedRequestAndIndex(uint8 i, uint8 j) public {
        i = uint8(bound(i, 0, 7));
        j = uint8(bound(j, 0, 7));
        vm.assume(i != j);

        uint64 serving = baseRound + 2;
        bytes32 secret = bytes32(uint256(uint256(i) << 8 | uint256(j) | 1));
        _enter(serving - 2);
        _commit(PK_A, serving, secret);
        _enter(serving - 1);
        (bytes32 requestId, uint64 got) = entropy.requestRandomness(8);
        assertEq(got, serving);
        _enter(serving);
        uint256 id = _record(opA, PK_A, keccak256(abi.encode("fuzz-words", i, j)));
        _reveal(PK_A, serving, id, secret);
        _enter(serving + 1);
        entropy.finalize(serving);

        (bytes32 seed,) = entropy.seedOf(serving);
        uint256[] memory first = entropy.randomWords(requestId);
        uint256[] memory second = entropy.randomWords(requestId);
        assertEq(first[i], second[i]);
        assertEq(first[i], uint256(keccak256(abi.encode(seed, requestId, uint256(i)))));
        assertEq(first[j], uint256(keccak256(abi.encode(seed, requestId, uint256(j)))));
        assertTrue(first[i] != first[j]);
    }

    // ── pair runner ─────────────────────────────────────────────────────────

    /// @param aFirst When true, A reveals before B. The seed does not depend on it.
    function _seedPair(uint64 round, bytes32 secretA, bytes32 secretB, bool aFirst) internal returns (bytes32 seed) {
        _enter(round - 2);
        _commit(PK_A, round, secretA);
        _commit(PK_B, round, secretB);
        _enter(round);
        uint256 idA = _record(opA, PK_A, keccak256(abi.encode("pair-a", round)));
        uint256 idB = _record(opB, PK_B, keccak256(abi.encode("pair-b", round)));
        if (aFirst) {
            _reveal(PK_A, round, idA, secretA);
            _reveal(PK_B, round, idB, secretB);
        } else {
            _reveal(PK_B, round, idB, secretB);
            _reveal(PK_A, round, idA, secretA);
        }
        _enter(round + 1);
        entropy.finalize(round);
        (seed,) = entropy.seedOf(round);
    }
}
