import { keccak256Hex, utf8 } from "../crypto/keccak.ts";

const LOCATION_KEYS = new Set([
  "latitude",
  "longitude",
  "altitudeMeters",
  "altitude",
  "lat",
  "lon",
  "gps",
  "location",
]);

function redact(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (LOCATION_KEYS.has(k)) continue;
      if (k === "id" && typeof v === "string") {
        out.utidHash = keccak256Hex(utf8(v)).slice(0, 18);
        continue;
      }
      out[k] = redact(v);
    }
    return out;
  }
  return value;
}

/** Strip GPS and raw UTID before a capture leaves the LAN. */
export function stripPrivateFields<T>(capture: T): T {
  return redact(capture) as T;
}
