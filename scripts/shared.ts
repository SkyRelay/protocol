/** Inputs shared by the vector generator, the verifier, and the test harness. */
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parse3le, type Tle } from "../packages/core/src/orbit/tle.ts";
import type { Eip712Domain } from "../packages/core/src/crypto/eip712.ts";

/** Anvil account #0 — an obviously disposable key, used as the demo operator. */
export const OPERATOR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`;

/**
 * One disposable address per station, so a quorum fixture has the distinct
 * operators the contract requires. Anvil accounts #0-#2.
 */
const STATION_OPERATORS: Record<string, `0x${string}`> = {
  "GENESIS-01": OPERATOR,
  "MERIDIAN-04": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "MV-ANYUAN": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
};

export function operatorFor(stationId: string): `0x${string}` {
  return STATION_OPERATORS[stationId] ?? OPERATOR;
}

export function readDomain(root: string): Eip712Domain {
  const d = JSON.parse(readFileSync(join(root, "vectors/eip712/domain.json"), "utf8"));
  return { chainId: d.chainId, verifyingContract: d.verifyingContract };
}

/** Every public element set a capture may be matched against. */
export function readCatalog(root: string): Tle[] {
  return readdirSync(join(root, "vectors/tle"))
    .filter((f) => f.startsWith("starlink-") && f.endsWith(".txt"))
    .sort()
    .map((f) => parse3le(readFileSync(join(root, "vectors/tle", f), "utf8")));
}
