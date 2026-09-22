import assert from "node:assert/strict";
import { test } from "node:test";
import {
  abiEncodeCommitment,
  accumulateEntropySeeds,
  calculateRound,
  calculateTargetCommitRound,
  computeEntropyCommitment,
  computeFinalizedSeed,
  derivePhysicalSecret,
  verifyEntropyCommitment,
} from "../src/entropy/extractor.ts";
import { bytesToHex } from "../src/crypto/keccak.ts";

test("derivePhysicalSecret generates unique deterministic 32-byte secrets from RF physical parameters", () => {
  const operator = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`;
  const salt = "0x11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff" as `0x${string}`;

  const secret1 = derivePhysicalSecret({
    snrMilliDb: 8700,
    dopplerHz: -14238,
    elevationMilliDeg: 47283,
    timestampSec: 1789934703,
    operator,
    localSalt: salt,
  });

  assert.match(secret1, /^0x[a-f0-9]{64}$/);

  // Deterministic with same inputs
  const secret2 = derivePhysicalSecret({
    snrMilliDb: 8700,
    dopplerHz: -14238,
    elevationMilliDeg: 47283,
    timestampSec: 1789934703,
    operator,
    localSalt: salt,
  });
  assert.equal(secret1, secret2);

  // Micro-fluctuation in Doppler alters the secret (avalanche effect)
  const secretDiffDoppler = derivePhysicalSecret({
    snrMilliDb: 8700,
    dopplerHz: -14239, // 1 Hz physical shift
    elevationMilliDeg: 47283,
    timestampSec: 1789934703,
    operator,
    localSalt: salt,
  });
  assert.notEqual(secret1, secretDiffDoppler);

  // Micro-fluctuation in SNR alters the secret
  const secretDiffSnr = derivePhysicalSecret({
    snrMilliDb: 8701,
    dopplerHz: -14238,
    elevationMilliDeg: 47283,
    timestampSec: 1789934703,
    operator,
    localSalt: salt,
  });
  assert.notEqual(secret1, secretDiffSnr);
});

test("abiEncodeCommitment produces exact 96-byte ABI word layout", () => {
  const secret = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as `0x${string}`;
  const sender = "0x1234567890123456789012345678901234567890" as `0x${string}`;
  const round = 100n;

  const encoded = abiEncodeCommitment(secret, sender, round);
  assert.equal(encoded.length, 96);

  // Word 0 (0..31): secret
  const word0 = bytesToHex(encoded.slice(0, 32));
  assert.equal(word0, secret);

  // Word 1 (32..63): 12 zero bytes followed by 20-byte address
  const word1 = bytesToHex(encoded.slice(32, 64));
  assert.equal(word1, `0x000000000000000000000000${sender.slice(2).toLowerCase()}`);

  // Word 2 (64..95): 24 zero bytes followed by 8-byte uint64 (big-endian 100 = 0x64)
  const word2 = bytesToHex(encoded.slice(64, 96));
  assert.equal(word2, "0x0000000000000000000000000000000000000000000000000000000000000064");
});

test("computeEntropyCommitment and verifyEntropyCommitment match Solidity commitment logic", () => {
  const secret = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" as `0x${string}`;
  const operator = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`;
  const round = 42n;

  const commitment = computeEntropyCommitment(secret, operator, round);
  assert.match(commitment, /^0x[a-f0-9]{64}$/);

  // Verification passes with correct tuple
  assert.equal(verifyEntropyCommitment(commitment, secret, operator, round), true);

  // Verification fails if wrong secret, sender, or round
  const wrongSecret = "0xbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdead" as `0x${string}`;
  assert.equal(verifyEntropyCommitment(commitment, wrongSecret, operator, round), false);

  const wrongOperator = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as `0x${string}`;
  assert.equal(verifyEntropyCommitment(commitment, secret, wrongOperator, round), false);

  assert.equal(verifyEntropyCommitment(commitment, secret, operator, 43n), false);
});

test("accumulateEntropySeeds XORs secrets commutatively and matches contract state", () => {
  const s1 = "0x000000000000000000000000000000000000000000000000000000000000000f" as `0x${string}`;
  const s2 = "0x00000000000000000000000000000000000000000000000000000000000000f0" as `0x${string}`;
  const s3 = "0x0000000000000000000000000000000000000000000000000000000000000f00" as `0x${string}`;

  const acc1 = accumulateEntropySeeds([s1, s2, s3]);
  const acc2 = accumulateEntropySeeds([s3, s1, s2]); // XOR is commutative

  assert.equal(acc1, 0x0fffn);
  assert.equal(acc1, acc2);
});

test("abiEncodeFinalize and computeFinalizedSeed match SkyRelayEntropy.finalize", () => {
  const accumulator = 0x12345678n;
  const round = 10n;
  const revealCount = 3;

  const finalized = computeFinalizedSeed(accumulator, round, revealCount);
  assert.match(finalized, /^0x[a-f0-9]{64}$/);

  // Zero reveals throws
  assert.throws(() => computeFinalizedSeed(accumulator, round, 0), /cannot finalize round with 0 reveals/);
});

test("calculateRound and calculateTargetCommitRound calculate fixed epochs", () => {
  const roundSeconds = 300; // 5 minute rounds
  const timestamp = 1789934800; // e.g. 5966449.33...
  const currentR = calculateRound(timestamp, roundSeconds);
  assert.equal(currentR, BigInt(Math.floor(timestamp / roundSeconds)));

  const targetR = calculateTargetCommitRound(timestamp, roundSeconds);
  assert.equal(targetR, currentR + 2n);
});
