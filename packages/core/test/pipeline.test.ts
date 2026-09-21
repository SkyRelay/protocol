import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { parseCapture } from "../src/telemetry/parse.ts";
import { extractFeatures } from "../src/telemetry/features.ts";
import { classifyAsn } from "../src/telemetry/asn.ts";
import { stripPrivateFields } from "../src/telemetry/privacy.ts";
import { runPipeline } from "../src/pipeline.ts";
import { hashTypedData } from "../src/crypto/eip712.ts";
import { parse3le, type Tle } from "../src/orbit/tle.ts";
import type { Station } from "../src/orbit/pass.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const vec = (...p: string[]) => JSON.parse(readFileSync(join(root, "vectors", ...p), "utf8"));

const CATALOG: Tle[] = readdirSync(join(root, "vectors/tle"))
  .filter((f) => f.startsWith("starlink-") && f.endsWith(".txt"))
  .sort()
  .map((f) => parse3le(readFileSync(join(root, "vectors/tle", f), "utf8")));

/** Anvil account #0 — an obviously disposable key, used as the demo operator. */
const OPERATOR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const;

const DOMAIN = {
  chainId: 97,
  verifyingContract: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC" as `0x${string}`,
};

const frame = (name: string) => {
  const capture = vec("frames", `${name}.json`);
  return { capture, station: capture.station as Station, catalog: CATALOG, domain: DOMAIN, operator: OPERATOR };
};

test("AS14593 allow, AS15169 deny", () => {
  assert.equal(classifyAsn(14593).allowed, true);
  assert.equal(classifyAsn(45700).allowed, true);
  assert.equal(classifyAsn(15169).allowed, false);
});

test("privacy strip removes GPS and raw UTID", () => {
  const stripped = stripPrivateFields(vec("frames", "connected-001.json")) as {
    dishGetDiagnostics?: { id?: string; location?: unknown };
  };
  assert.equal(stripped.dishGetDiagnostics?.location, undefined);
  assert.equal(stripped.dishGetDiagnostics?.id, undefined);
});

test("connected frame extracts millidB SNR and Starlink ASN", () => {
  const f = extractFeatures(parseCapture(vec("frames", "connected-001.json")));
  assert.equal(f.asn, 14593);
  assert.equal(f.asnAllowed, true);
  assert.equal(f.snrMilliDb, 8700);
  assert.equal(f.telemetryHash.length, 66);
});

test("every positive frame resolves to the satellite it claims", () => {
  for (const file of readdirSync(join(root, "vectors/frames")).sort()) {
    const name = file.replace(/\.json$/, "");
    if (name.startsWith("bad-")) continue;
    const input = frame(name);
    const out = runPipeline(input);
    assert.equal(out.attestation.noradId, input.capture.expectNoradId, `${name} matched the wrong satellite`);
    assert.ok(out.attestation.elevationMilliDeg > 0, `${name} is below the horizon`);
    assert.ok(
      Math.abs(out.attestation.dopplerHz) < 300_000,
      `${name} Doppler ${out.attestation.dopplerHz} Hz is outside the Ku LEO envelope`,
    );
    assert.ok(out.sighting.boresightResidualDeg < 2, `${name} boresight residual too large`);
  }
});

test("pipeline rejects a non-Starlink ASN", () => {
  assert.throws(() => runPipeline(frame("bad-asn-005")), /ASN 15169 is outside/);
});

test("pipeline rejects a boresight no catalog satellite explains", () => {
  assert.throws(() => runPipeline(frame("bad-geometry-006")), /from the nearest catalog satellite/);
});

test("pipeline rejects a capture whose timestamp has no pass at all", () => {
  const input = frame("connected-001");
  const capture = { ...input.capture, capturedAt: "2026-09-20T03:00:00.000Z" };
  assert.throws(() => runPipeline({ ...input, capture }), /above the horizon|nearest catalog satellite/);
});

test("pipeline digest is deterministic", () => {
  const input = frame("connected-001");
  const a = runPipeline(input);
  const b = runPipeline(input);
  assert.equal(a.digest, b.digest);
  assert.equal(hashTypedData(a.attestation, DOMAIN), a.digest);
});

/**
 * vectors/eip712/attestations.json is the only thing the Solidity side can see.
 * If it drifts from what the pipeline actually produces, the cross-implementation
 * check in contracts/test/Eip712Vectors.t.sol would be verifying stale numbers.
 */
test("committed digest vectors match what the pipeline produces today", () => {
  const committed = vec("eip712", "attestations.json") as {
    domain: { chainId: number; verifyingContract: `0x${string}` };
    count: number;
    attestations: Record<string, unknown>[];
  };
  assert.equal(committed.count, committed.attestations.length);
  assert.ok(committed.count >= 3, "expected at least three digest vectors");

  for (const row of committed.attestations) {
    const input = frame(row.id as string);
    const out = runPipeline({
      ...input,
      domain: committed.domain,
      operator: row.operator as `0x${string}`,
    });
    assert.deepEqual(
      { id: row.id, ...out.attestation, digest: out.digest },
      row,
      `${row.id} is stale — run \`pnpm run vectors\``,
    );
  }
});
