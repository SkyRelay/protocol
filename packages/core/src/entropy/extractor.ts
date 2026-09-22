import {
  bytesToHex,
  hexToBytes,
  keccak256Hex,
  utf8,
} from "../crypto/keccak.ts";

export type PhysicalEntropyInputs = {
  /** Signal-to-noise ratio in millidB (e.g. 8700 for 8.7 dB). */
  snrMilliDb: number;
  /** Carrier Doppler frequency shift in Hz. */
  dopplerHz: number;
  /** Satellite look angle elevation in millidegrees (e.g. 45000 for 45.0 deg). */
  elevationMilliDeg: number;
  /** Pass observation UTC timestamp in seconds. */
  timestampSec: number;
  /** Node operator EVM address. */
  operator: `0x${string}`;
  /** Optional downlink throughput in bits/sec. */
  downlinkThroughputBps?: number;
  /** Optional ping latency to ground POP in milliseconds. */
  popPingLatencyMs?: number;
  /** Cryptographically secure client salt (32-byte hex). */
  localSalt?: `0x${string}`;
};

/**
 * Derive a 32-byte space-time physical entropy secret from satellite microwave pass telemetry.
 *
 * Micro-fluctuations in Ku-band carrier Doppler shift, ionospheric scintillation,
 * pointing jitter, and hardware thermal noise provide physical entropy rooted in LEO orbit.
 */
export function derivePhysicalSecret(inputs: PhysicalEntropyInputs): `0x${string}` {
  const salt = inputs.localSalt || bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
  const payload = [
    `SALT:${salt.toLowerCase()}`,
    `OPERATOR:${inputs.operator.toLowerCase()}`,
    `TIME:${inputs.timestampSec}`,
    `DOPPLER:${Math.round(inputs.dopplerHz)}`,
    `SNR:${Math.round(inputs.snrMilliDb)}`,
    `ELEV:${Math.round(inputs.elevationMilliDeg)}`,
    `BPS:${Math.round(inputs.downlinkThroughputBps ?? 0)}`,
    `PING:${(inputs.popPingLatencyMs ?? 0).toFixed(3)}`,
  ].join("|");

  return keccak256Hex(utf8(payload));
}

/**
 * ABI-encode (bytes32 secret, address sender, uint64 round) into exact 96-byte layout
 * matching Solidity `abi.encode(secret, msg.sender, round)`.
 */
export function abiEncodeCommitment(
  secret: `0x${string}`,
  sender: `0x${string}`,
  round: bigint | number,
): Uint8Array {
  const buf = new Uint8Array(96);

  // Word 0 (0..31): bytes32 secret
  const secretBytes = hexToBytes(secret);
  if (secretBytes.length !== 32) throw new Error("secret must be 32 bytes");
  buf.set(secretBytes, 0);

  // Word 1 (32..63): address sender (left-padded with 12 zero bytes)
  const cleanAddr = sender.startsWith("0x") ? sender.slice(2) : sender;
  const addrBytes = hexToBytes(cleanAddr);
  if (addrBytes.length !== 20) throw new Error("sender must be 20-byte address");
  buf.set(addrBytes, 32 + 12);

  // Word 2 (64..95): uint64 round (left-padded with 24 zero bytes, big-endian)
  const roundBig = BigInt(round);
  const view = new DataView(buf.buffer, buf.byteOffset + 64, 32);
  view.setBigUint64(24, roundBig, false);

  return buf;
}

/**
 * Compute the commitment hash for BSC SkyRelayEntropy.sol:
 *   keccak256(abi.encode(secret, msg.sender, round))
 */
export function computeEntropyCommitment(
  secret: `0x${string}`,
  sender: `0x${string}`,
  round: bigint | number,
): `0x${string}` {
  return keccak256Hex(abiEncodeCommitment(secret, sender, round));
}

/**
 * Verify if a given commitment matches the secret, sender address, and round.
 */
export function verifyEntropyCommitment(
  commitment: `0x${string}`,
  secret: `0x${string}`,
  sender: `0x${string}`,
  round: bigint | number,
): boolean {
  const expected = computeEntropyCommitment(secret, sender, round);
  return commitment.toLowerCase() === expected.toLowerCase();
}

/**
 * Accumulate revealed secrets by XORing their uint256 values,
 * exactly matching Solidity `r.accumulator ^= uint256(secret)`.
 */
export function accumulateEntropySeeds(secrets: (`0x${string}` | bigint)[]): bigint {
  let accumulator = 0n;
  for (const s of secrets) {
    const val = typeof s === "bigint" ? s : BigInt(s);
    accumulator ^= val;
  }
  return accumulator;
}

/**
 * ABI-encode (uint256 accumulator, uint64 round, uint32 revealCount) into exact 96-byte layout
 * matching Solidity `abi.encode(r.accumulator, round, n)`.
 */
export function abiEncodeFinalize(
  accumulator: bigint,
  round: bigint | number,
  revealCount: number,
): Uint8Array {
  const buf = new Uint8Array(96);

  // Word 0 (0..31): uint256 accumulator (big-endian 32 bytes)
  const hexAccum = accumulator.toString(16).padStart(64, "0");
  buf.set(hexToBytes(hexAccum), 0);

  // Word 1 (32..63): uint64 round (left-padded with 24 zero bytes)
  const view1 = new DataView(buf.buffer, buf.byteOffset + 32, 32);
  view1.setBigUint64(24, BigInt(round), false);

  // Word 2 (64..95): uint32 revealCount (left-padded with 28 zero bytes)
  const view2 = new DataView(buf.buffer, buf.byteOffset + 64, 32);
  view2.setUint32(28, revealCount, false);

  return buf;
}

/**
 * Compute the finalized seed matching Solidity SkyRelayEntropy.finalize:
 *   keccak256(abi.encode(r.accumulator, round, n))
 */
export function computeFinalizedSeed(
  accumulator: bigint,
  round: bigint | number,
  revealCount: number,
): `0x${string}` {
  if (revealCount === 0) throw new Error("cannot finalize round with 0 reveals");
  return keccak256Hex(abiEncodeFinalize(accumulator, round, revealCount));
}

/** Calculate current round number given timestamp and epoch length in seconds. */
export function calculateRound(timestampSec: number, roundSeconds: number): bigint {
  if (roundSeconds <= 0) throw new Error("roundSeconds must be positive");
  return BigInt(Math.floor(timestampSec / roundSeconds));
}

/** Calculate target commit round (must commit for currentRound + 2). */
export function calculateTargetCommitRound(currentTimestampSec: number, roundSeconds: number): bigint {
  return calculateRound(currentTimestampSec, roundSeconds) + 2n;
}
