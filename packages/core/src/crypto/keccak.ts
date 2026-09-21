/**
 * Ethereum Keccak-256 (not NIST SHA3-256).
 * Padding domain is 0x01; permutation is Keccak-f[1600].
 * Zero runtime dependencies — required so EIP-712 digests match Solidity.
 */

const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

const ROTL = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];

function rotl64(x: bigint, n: number): bigint {
  const s = BigInt(n % 64);
  const mask = (1n << 64n) - 1n;
  return ((x << s) | (x >> (64n - s))) & mask;
}

function keccakF(a: bigint[]): void {
  const b = new Array<bigint>(25);
  const c = new Array<bigint>(5);
  const d = new Array<bigint>(5);
  const mask = (1n << 64n) - 1n;
  for (let round = 0; round < 24; round++) {
    for (let x = 0; x < 5; x++) {
      c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
    }
    for (let x = 0; x < 5; x++) {
      d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1);
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        a[x + 5 * y] ^= d[x];
      }
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(a[x + 5 * y], ROTL[x][y]);
      }
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        const i = x + 5 * y;
        a[i] = b[i] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y]);
        a[i] &= mask;
      }
    }
    a[0] ^= RC[round];
  }
}

function loadLane(bytes: Uint8Array, offset: number): bigint {
  let x = 0n;
  for (let i = 0; i < 8; i++) {
    x |= BigInt(bytes[offset + i] ?? 0) << BigInt(8 * i);
  }
  return x;
}

function storeLane(lane: bigint, out: Uint8Array, offset: number): void {
  for (let i = 0; i < 8; i++) {
    out[offset + i] = Number((lane >> BigInt(8 * i)) & 0xffn);
  }
}

/** Keccak-256 of arbitrary bytes. Returns 32-byte digest. */
export function keccak256(data: Uint8Array): Uint8Array {
  const rate = 136; // 1088 bits
  const state = new Array<bigint>(25).fill(0n);
  let offset = 0;
  while (offset + rate <= data.length) {
    for (let i = 0; i < rate / 8; i++) {
      state[i] ^= loadLane(data, offset + i * 8);
    }
    keccakF(state);
    offset += rate;
  }
  const block = new Uint8Array(rate);
  const rem = data.length - offset;
  block.set(data.subarray(offset));
  block[rem] = 0x01; // Ethereum domain
  block[rate - 1] |= 0x80;
  for (let i = 0; i < rate / 8; i++) {
    state[i] ^= loadLane(block, i * 8);
  }
  keccakF(state);
  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    storeLane(state[i], out, i * 8);
  }
  return out;
}

export function keccak256Hex(data: Uint8Array): `0x${string}` {
  return bytesToHex(keccak256(data));
}

export function utf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

export function bytesToHex(b: Uint8Array): `0x${string}` {
  return `0x${Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("")}`;
}

export function hexToBytes(hex: string): Uint8Array {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (h.length % 2 !== 0) {
    throw new Error("odd hex length");
  }
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}
