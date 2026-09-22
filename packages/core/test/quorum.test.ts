import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { runQuorum, type QuorumMember } from "../src/quorum.ts";
import { parse3le, type Tle } from "../src/orbit/tle.ts";
import type { Station } from "../src/orbit/pass.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const vec = (...p: string[]) => JSON.parse(readFileSync(join(root, "vectors", ...p), "utf8"));

const CATALOG: Tle[] = readdirSync(join(root, "vectors/tle"))
  .filter((f) => f.startsWith("starlink-") && f.endsWith(".txt"))
  .sort()
  .map((f) => parse3le(readFileSync(join(root, "vectors/tle", f), "utf8")));

const DOMAIN = {
  chainId: 97,
  verifyingContract: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC" as `0x${string}`,
};

const OPERATORS: Record<string, `0x${string}`> = {
  "VALENTIA-01": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "GOONHILLY-02": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "PLEUMEUR-03": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  "MV-FASTNET": "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
};

const member = (name: string): QuorumMember => {
  const capture = vec("frames", `${name}.json`);
  const station = capture.station as Station;
  return { capture, station, operator: OPERATORS[station.id]! };
};

const MEMBERS = ["connected-001", "quorum-goonhilly-007", "quorum-pleumeur-009"];
const quorum = () => runQuorum({ members: MEMBERS.map(member), catalog: CATALOG, domain: DOMAIN });

test("three stations resolve one sighting", () => {
  const q = quorum();
  assert.equal(q.reports.length, 3);
  assert.equal(q.noradId, 47352);
  for (const r of q.reports) {
    assert.equal(r.attestation.noradId, q.noradId);
    assert.equal(r.attestation.timestamp, q.timestamp);
    assert.equal(r.attestation.catalogHash, q.catalogHash);
  }
});

/**
 * If every station reported the same numbers they would not be independent
 * observations of anything. Distance along the ground track is what makes the
 * elevations and Doppler shifts differ, and that difference is the content.
 */
test("stations at different places report different geometry", () => {
  const q = quorum();
  const elevations = new Set(q.reports.map((r) => r.attestation.elevationMilliDeg));
  const dopplers = new Set(q.reports.map((r) => r.attestation.dopplerHz));
  assert.equal(elevations.size, 3, "elevations must all differ");
  assert.equal(dopplers.size, 3, "Doppler shifts must all differ");
  assert.ok(q.worstBoresightResidualDeg < 2, "every member must still match the satellite");
});

test("every member keeps its own digest", () => {
  const digests = new Set(quorum().reports.map((r) => r.digest));
  assert.equal(digests.size, 3);
});

test("a quorum needs more than one station", () => {
  assert.throws(
    () => runQuorum({ members: [member("connected-001")], catalog: CATALOG, domain: DOMAIN }),
    /at least two stations/,
  );
});

test("the same station cannot appear twice", () => {
  assert.throws(
    () =>
      runQuorum({
        members: [member("connected-001"), member("connected-001")],
        catalog: CATALOG,
        domain: DOMAIN,
      }),
    /appears twice/,
  );
});

test("two stations cannot share one operator address", () => {
  const a = member("connected-001");
  const b = { ...member("quorum-goonhilly-007"), operator: a.operator };
  assert.throws(
    () => runQuorum({ members: [a, b], catalog: CATALOG, domain: DOMAIN }),
    /operator .* appears twice/,
  );
});

test("a member observing a different second is rejected", () => {
  const a = member("connected-001");
  const b = member("handover-002"); // same satellite, 8.83 s later
  assert.throws(
    () => runQuorum({ members: [a, b], catalog: CATALOG, domain: DOMAIN }),
    /disagrees on the second/,
  );
});

test("a member observing a different satellite is rejected", () => {
  const a = member("connected-001");
  const b = member("obstructed-003"); // STARLINK-1526, and a different second
  assert.throws(
    () => runQuorum({ members: [a, b], catalog: CATALOG, domain: DOMAIN }),
    /disagrees on the (satellite|second)/,
  );
});

test("a member resolved against a different catalog is rejected", () => {
  const a = member("connected-001");
  const b = member("quorum-goonhilly-007");
  const q = runQuorum({ members: [a, b], catalog: CATALOG, domain: DOMAIN });
  // keep the satellite the quorum resolved to, drop the rest
  const trimmed = CATALOG.filter((t) => t.noradId === q.noradId);
  const other = runQuorum({ members: [a, b], catalog: trimmed, domain: DOMAIN });
  assert.notEqual(
    other.catalogHash,
    q.catalogHash,
    "dropping satellites must change what the quorum committed to",
  );
});

test("the committed quorum fixture matches what the pipeline produces", () => {
  const committed = vec("eip712", "attestations.json").quorum as {
    members: string[];
    noradId: number;
    timestamp: number;
    catalogHash: `0x${string}`;
  };
  const q = quorum();
  assert.deepEqual(committed.members, MEMBERS);
  assert.equal(committed.noradId, q.noradId);
  assert.equal(committed.timestamp, q.timestamp);
  assert.equal(committed.catalogHash, q.catalogHash);
});

test("quorum automatically performs multi-station triangulation and verifies FDOA residual", () => {
  const q = quorum();
  assert.ok(q.triangulation, "triangulation report must be present");
  assert.equal(q.triangulation.stationCount, 3);
  assert.equal(q.triangulation.isTriangulationVerified, true);
  // Differential Doppler residual across Atlantic stations is sub-Hertz
  assert.ok(q.triangulation.maxFdoaResidualHz < 3.0, `max residual: ${q.triangulation.maxFdoaResidualHz} Hz`);
  assert.ok(q.triangulation.precisionGainFactor > 4.0, "precision gain factor must be > 4x");
});

test("quorum rejects member if differential Doppler residual exceeds threshold", () => {
  const m1 = member("connected-001");
  const m2 = member("quorum-goonhilly-007");

  // If we set a very tight impossible tolerance (e.g. 0.001 Hz), triangulation must throw TriangulationError
  assert.throws(
    () =>
      runQuorum({
        members: [m1, m2],
        catalog: CATALOG,
        domain: DOMAIN,
        triangulationToleranceHz: 0.001,
      }),
    /exceeds tolerance/,
  );
});
