import {
  hashTypedData,
  type Eip712Domain,
  type SkyRelayAttestation,
} from "./eip712.ts";
import { keccak256Hex, hexToBytes } from "./keccak.ts";
import { concat } from "./abi.ts";

export type EquivocationProof = {
  attestationA: SkyRelayAttestation;
  sigA: `0x${string}`;
  attestationB: SkyRelayAttestation;
  sigB: `0x${string}`;
  digestA: `0x${string}`;
  digestB: `0x${string}`;
  /** Canonical pair key matching Solidity: keccak256(abi.encodePacked(min(digestA, digestB), max(digestA, digestB))). */
  pairKey: `0x${string}`;
  operator: `0x${string}`;
};

/**
 * Compute the canonical pair key used by SkyRelayBond.sol to prevent duplicate slashing reports.
 */
export function computeEquivocationPairKey(
  digestA: `0x${string}`,
  digestB: `0x${string}`,
): `0x${string}` {
  const bytesA = hexToBytes(digestA);
  const bytesB = hexToBytes(digestB);

  // Compare byte-by-byte in big-endian
  const aIsSmaller = digestA.toLowerCase() < digestB.toLowerCase();
  const first = aIsSmaller ? bytesA : bytesB;
  const second = aIsSmaller ? bytesB : bytesA;

  return keccak256Hex(concat([first, second]));
}

/**
 * Validate whether two signed attestations constitute a valid, slashable equivocation.
 *
 * Rules matching SkyRelayBond.slashEquivocation:
 * 1. a.operator === b.operator
 * 2. a.timestamp === b.timestamp
 * 3. digestA !== digestB (different satellite, different telemetry, or different boresight)
 * 4. Signatures must be 65 bytes long (r, s, v)
 */
export function evaluateEquivocation(
  a: SkyRelayAttestation,
  sigA: `0x${string}`,
  b: SkyRelayAttestation,
  sigB: `0x${string}`,
  domain: Eip712Domain,
): {
  isSlashable: boolean;
  revertReason?: string;
  proof?: EquivocationProof;
} {
  if (a.operator.toLowerCase() !== b.operator.toLowerCase()) {
    return { isSlashable: false, revertReason: "NotEquivocation: distinct operators" };
  }
  if (a.timestamp !== b.timestamp) {
    return { isSlashable: false, revertReason: "NotEquivocation: timestamps differ" };
  }

  const cleanSigA = sigA.startsWith("0x") ? sigA.slice(2) : sigA;
  const cleanSigB = sigB.startsWith("0x") ? sigB.slice(2) : sigB;
  if (cleanSigA.length !== 130 || cleanSigB.length !== 130) {
    return { isSlashable: false, revertReason: "BadSignature: signature must be 65 bytes" };
  }

  const digestA = hashTypedData(a, domain);
  const digestB = hashTypedData(b, domain);

  if (digestA === digestB) {
    return { isSlashable: false, revertReason: "NotEquivocation: identical attestations" };
  }

  const pairKey = computeEquivocationPairKey(digestA, digestB);

  return {
    isSlashable: true,
    proof: {
      attestationA: a,
      sigA,
      attestationB: b,
      sigB,
      digestA,
      digestB,
      pairKey,
      operator: a.operator,
    },
  };
}

/**
 * Format the transaction call parameters for BSC SkyRelayBond.slashEquivocation.
 */
export function formatSlashEquivocationCall(proof: EquivocationProof): {
  functionName: "slashEquivocation";
  args: [
    SkyRelayAttestation,
    `0x${string}`,
    SkyRelayAttestation,
    `0x${string}`,
  ];
} {
  return {
    functionName: "slashEquivocation",
    args: [proof.attestationA, proof.sigA, proof.attestationB, proof.sigB],
  };
}
