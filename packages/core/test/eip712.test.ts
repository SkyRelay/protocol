import assert from "node:assert/strict";
import { test } from "node:test";
import {
  ATTESTATION_TYPEHASH,
  ATTESTATION_TYPE_STRING,
  DOMAIN_TYPEHASH,
  hashTypedData,
  type Eip712Domain,
  type SkyRelayAttestation,
} from "../src/crypto/eip712.ts";
import { keccak256Hex, utf8 } from "../src/crypto/keccak.ts";

const DOMAIN: Eip712Domain = {
  chainId: 97,
  verifyingContract: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC",
};

const ATT: SkyRelayAttestation = {
  operator: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  telemetryHash: `0x${"11".repeat(32)}`,
  noradId: 44714,
  elevationMilliDeg: 54180,
  dopplerHz: -182000,
  snrMilliDb: 8700,
  asn: 14593,
  timestamp: 1726834083,
};

test("EIP-712 domain typehash matches the canonical Ethereum string", () => {
  assert.equal(
    DOMAIN_TYPEHASH,
    "0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f",
  );
});

test("attestation typehash is pinned", () => {
  assert.equal(ATTESTATION_TYPEHASH, "0x3ef74e5ab3e68a910b640f4b2d211ddb61f06e52f18da48417abca1644024a79");
  assert.equal(ATTESTATION_TYPEHASH, keccak256Hex(utf8(ATTESTATION_TYPE_STRING)));
});

test("the type string carries the operator as its first member", () => {
  assert.ok(ATTESTATION_TYPE_STRING.startsWith("SkyRelayAttestation(address operator,"));
});

test("digest changes if chainId changes", () => {
  const a = hashTypedData(ATT, DOMAIN);
  const b = hashTypedData(ATT, { ...DOMAIN, chainId: 56 });
  assert.notEqual(a, b);
  assert.equal(a.length, 66);
});

test("digest changes if the verifying contract changes", () => {
  const a = hashTypedData(ATT, DOMAIN);
  const b = hashTypedData(ATT, {
    ...DOMAIN,
    verifyingContract: "0xdddddddddddddddddddddddddddddddddddddddd",
  });
  assert.notEqual(a, b);
});

test("keccak256 handles inputs spanning multiple 136-byte blocks", () => {
  // The domain separator alone is a 160-byte preimage, so the absorb loop is
  // exercised; these pin it against values produced outside this repository.
  assert.equal(
    keccak256Hex(utf8("a".repeat(136))),
    "0xa6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e",
  );
  assert.equal(
    keccak256Hex(utf8("a".repeat(200))),
    "0x96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d",
  );
});
