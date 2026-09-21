import { DEG2RAD, MINUTES_PER_DAY, TWO_PI } from "./constants.ts";
import { epochToJulian } from "./coords.ts";

export type Tle = {
  name: string;
  noradId: number;
  classification: string;
  intlDesignator: string;
  epochYear: number;
  epochDay: number;
  ndot: number;
  nddot: number;
  bstar: number;
  elementSet: number;
  inclinationDeg: number;
  raanDeg: number;
  eccentricity: number;
  argPerigeeDeg: number;
  meanAnomalyDeg: number;
  meanMotionRevPerDay: number;
  revolutionNumber: number;
  line1: string;
  line2: string;
};

function checksum(line: string): number {
  let sum = 0;
  for (let i = 0; i < 68; i++) {
    const c = line[i] ?? " ";
    if (c === "-") sum += 1;
    else if (c >= "0" && c <= "9") sum += c.charCodeAt(0) - 48;
  }
  return sum % 10;
}

function parseExp(field: string): number {
  const t = field.trim();
  if (t.length === 0) return 0;
  const sign = t[0] === "-" ? -1 : 1;
  const body = t[0] === "+" || t[0] === "-" ? t.slice(1) : t;
  const m = body.match(/^(\d+)([+-]\d+)$/);
  if (!m) return Number(t);
  const mantissa = Number(`0.${m[1]}`);
  const exp = Number(m[2]);
  return sign * mantissa * 10 ** exp;
}

/**
 * Parse a classic 69-column TLE pair. Checksums are verified.
 * Epoch year 57–99 → 1957–1999; 00–56 → 2000–2056 (NORAD convention).
 */
export function parseTle(line1: string, line2: string, name = ""): Tle {
  const l1 = line1.replace(/\r/g, "").padEnd(69).slice(0, 69);
  const l2 = line2.replace(/\r/g, "").padEnd(69).slice(0, 69);
  if (l1[0] !== "1" || l2[0] !== "2") {
    throw new Error("TLE lines must start with 1 / 2");
  }
  const c1 = checksum(l1);
  const c2 = checksum(l2);
  if (Number(l1[68]) !== c1) {
    throw new Error(`TLE line 1 checksum ${l1[68]} != ${c1}`);
  }
  if (Number(l2[68]) !== c2) {
    throw new Error(`TLE line 2 checksum ${l2[68]} != ${c2}`);
  }
  const norad1 = Number(l1.slice(2, 7));
  const norad2 = Number(l2.slice(2, 7));
  if (norad1 !== norad2) {
    throw new Error("NORAD id mismatch between TLE lines");
  }
  const yy = Number(l1.slice(18, 20));
  const epochYear = yy < 57 ? 2000 + yy : 1900 + yy;
  return {
    name: name.trim(),
    noradId: norad1,
    classification: l1[7] ?? "U",
    intlDesignator: l1.slice(9, 17).trim(),
    epochYear,
    epochDay: Number(l1.slice(20, 32)),
    ndot: Number(l1.slice(33, 43)),
    nddot: parseExp(l1.slice(44, 52)),
    bstar: parseExp(l1.slice(53, 61)),
    elementSet: Number(l1.slice(64, 68)),
    inclinationDeg: Number(l2.slice(8, 16)),
    raanDeg: Number(l2.slice(17, 25)),
    eccentricity: Number(`0.${l2.slice(26, 33)}`),
    argPerigeeDeg: Number(l2.slice(34, 42)),
    meanAnomalyDeg: Number(l2.slice(43, 51)),
    meanMotionRevPerDay: Number(l2.slice(52, 63)),
    revolutionNumber: Number(l2.slice(63, 68)),
    line1: l1,
    line2: l2,
  };
}

export function parse3le(block: string): Tle {
  const lines = block
    .split(/\n/)
    .map((l) => l.trimEnd())
    .filter((l) => l.length > 0);
  if (lines.length < 2) throw new Error("need at least two TLE lines");
  if (lines[0]!.startsWith("1 ")) {
    return parseTle(lines[0]!, lines[1]!);
  }
  return parseTle(lines[1]!, lines[2]!, lines[0]);
}

/** Full Julian date of TLE epoch (UTC). */
export function tleEpochJulian(tle: Tle): number {
  const { jd, fr } = epochToJulian(tle.epochYear, tle.epochDay);
  return jd + fr;
}

export function meanMotionRadPerMin(tle: Tle): number {
  return (tle.meanMotionRevPerDay * TWO_PI) / MINUTES_PER_DAY;
}

export function tleAnglesRad(tle: Tle) {
  return {
    inclo: tle.inclinationDeg * DEG2RAD,
    nodeo: tle.raanDeg * DEG2RAD,
    argpo: tle.argPerigeeDeg * DEG2RAD,
    mo: tle.meanAnomalyDeg * DEG2RAD,
  };
}
