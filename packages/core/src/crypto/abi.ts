/** ABI encoding for the static types used by SkyRelay EIP-712 (no dynamic fields). */

export function pad32(bytes: Uint8Array): Uint8Array {
  if (bytes.length > 32) {
    throw new Error("value exceeds 32 bytes");
  }
  const out = new Uint8Array(32);
  out.set(bytes, 32 - bytes.length);
  return out;
}

export function u256(n: bigint): Uint8Array {
  if (n < 0n) {
    throw new Error("u256 of negative");
  }
  const out = new Uint8Array(32);
  let x = n;
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return out;
}

export function u32(n: number): Uint8Array {
  if (!Number.isInteger(n) || n < 0 || n > 0xffffffff) {
    throw new Error(`u32 out of range: ${n}`);
  }
  return u256(BigInt(n));
}

export function u64(n: number | bigint): Uint8Array {
  const v = typeof n === "bigint" ? n : BigInt(n);
  if (v < 0n || v > 0xffffffffffffffffn) {
    throw new Error(`u64 out of range: ${v}`);
  }
  return u256(v);
}

/** Sign-extend a 32-bit two's complement integer into a 32-byte ABI word. */
export function i32(n: number): Uint8Array {
  if (!Number.isInteger(n) || n < -0x80000000 || n > 0x7fffffff) {
    throw new Error(`i32 out of range: ${n}`);
  }
  const v = BigInt(n);
  const word = v < 0n ? (1n << 256n) + v : v;
  return u256(word);
}

export function bytes32(hex: string): Uint8Array {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (h.length !== 64) {
    throw new Error("bytes32 requires 32 bytes");
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export function address(addr: string): Uint8Array {
  const h = addr.startsWith("0x") ? addr.slice(2) : addr;
  if (h.length !== 40) {
    throw new Error("address requires 20 bytes");
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 20; i++) {
    out[12 + i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export function concat(parts: Uint8Array[]): Uint8Array {
  const n = parts.reduce((s, p) => s + p.length, 0);
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}
