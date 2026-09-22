import assert from "node:assert/strict";
import { test } from "node:test";
import {
  computeEquivocationPairKey,
  evaluateEquivocation,
  formatSlashEquivocationCall,
} from "../src/crypto/slashing.ts";
import type { SkyRelayAttestation, Eip712Domain } from "../src/crypto/eip712.ts";

const DOMAIN: Eip712Domain = {
  chainId: 97,
  verifyingContract: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC",
};

const OPERATOR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`;

const BASE_ATTESTATION: SkyRelayAttestation = {
  operator: OPERATOR,
  telemetryHash: "0x1111111111111111111111111111111111111111111111111111111111111111",
  catalogHash: "0x2222222222222222222222222222222222222222222222222222222222222222",
  noradId: 47352,
  elevationMilliDeg: 45000,
  dopplerHz: -12000,
  snrMilliDb: 8500,
  asn: 14593,
  timestamp: 1789934703,
};

// Valid 65-byte dummy signatures
const DUMMY_SIG_A = ("0x" + "aa".repeat(65)) as `0x${string}`;
const DUMMY_SIG_B = ("0x" + "bb".repeat(65)) as `0x${string}`;

test("computeEquivocationPairKey is order-independent and deterministic", () => {
  const digest1 = "0x1111111111111111111111111111111111111111111111111111111111111111" as `0x${string}`;
  const digest2 = "0x2222222222222222222222222222222222222222222222222222222222222222" as `0x${string}`;

  const k1 = computeEquivocationPairKey(digest1, digest2);
  const k2 = computeEquivocationPairKey(digest2, digest1);

  assert.equal(k1, k2, "pair key must be independent of digest argument order");
  assert.match(k1, /^0x[a-f0-9]{64}$/);
});

test("evaluateEquivocation flags contradictory attestations from the same operator at the same second", () => {
  const attA = { ...BASE_ATTESTATION };
  // Contradictory second attestation: same operator & second, but claims different satellite (e.g. 58921)
  const attB = { ...BASE_ATTESTATION, noradId: 58921, dopplerHz: 15000 };

  const evalResult = evaluateEquivocation(attA, DUMMY_SIG_A, attB, DUMMY_SIG_B, DOMAIN);
  assert.equal(evalResult.isSlashable, true);
  assert.ok(evalResult.proof);
  assert.equal(evalResult.proof.operator, OPERATOR);
  assert.notEqual(evalResult.proof.digestA, evalResult.proof.digestB);

  const call = formatSlashEquivocationCall(evalResult.proof);
  assert.equal(call.functionName, "slashEquivocation");
  assert.equal(call.args.length, 4);
});

test("evaluateEquivocation rejects attestations from different operators", () => {
  const attA = { ...BASE_ATTESTATION };
  const attB = { ...BASE_ATTESTATION, operator: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as `0x${string}` };

  const res = evaluateEquivocation(attA, DUMMY_SIG_A, attB, DUMMY_SIG_B, DOMAIN);
  assert.equal(res.isSlashable, false);
  assert.match(res.revertReason!, /distinct operators/);
});

test("evaluateEquivocation rejects attestations from different timestamps", () => {
  const attA = { ...BASE_ATTESTATION };
  const attB = { ...BASE_ATTESTATION, timestamp: BASE_ATTESTATION.timestamp + 1 };

  const res = evaluateEquivocation(attA, DUMMY_SIG_A, attB, DUMMY_SIG_B, DOMAIN);
  assert.equal(res.isSlashable, false);
  assert.match(res.revertReason!, /timestamps differ/);
});

test("evaluateEquivocation rejects identical attestations", () => {
  const attA = { ...BASE_ATTESTATION };
  const attB = { ...BASE_ATTESTATION };

  const res = evaluateEquivocation(attA, DUMMY_SIG_A, attB, DUMMY_SIG_B, DOMAIN);
  assert.equal(res.isSlashable, false);
  assert.match(res.revertReason!, /identical attestations/);
});
