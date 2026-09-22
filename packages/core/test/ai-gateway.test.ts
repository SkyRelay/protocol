import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { AutonomousAIGateway } from "../src/ai/gateway.ts";
import { parse3le, type Tle } from "../src/orbit/tle.ts";
import { BASELINE_STATIONS } from "../src/orbit/triangulation.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const CATALOG: Tle[] = readdirSync(join(root, "vectors/tle"))
  .filter((f) => f.startsWith("starlink-") && f.endsWith(".txt"))
  .sort()
  .map((f) => parse3le(readFileSync(join(root, "vectors/tle", f), "utf8")));

test("AutonomousAIGateway queries physical space state and derives relativistic time anchor", () => {
  const gateway = new AutonomousAIGateway(CATALOG);

  // Query STARLINK-1008 (NORAD 47352) above Valentia Island at committed fixture timestamp
  const state = gateway.querySpaceState({
    noradId: 47352,
    timestampSec: 1789934703,
    station: BASELINE_STATIONS.VALENTIA_01,
  });

  assert.equal(state.noradId, 47352);
  assert.equal(state.stationId, "VALENTIA-01");
  assert.ok(state.elevationDeg > 0, "satellite must be visible above horizon");
  assert.ok(state.slantRangeKm > 400 && state.slantRangeKm < 1500);

  // Check relativistic time anchor parameters
  const anchor = state.relativisticTimeAnchor;
  assert.equal(anchor.noradId, 47352);
  assert.ok(anchor.netDriftUsPerDay < -20 && anchor.netDriftUsPerDay > -25);
  assert.ok(anchor.tcaDopplerSlopeHzS < 0);
});

test("AutonomousAIGateway verifies physical space entropy seeds for on-chain AI consumers", () => {
  const gateway = new AutonomousAIGateway(CATALOG);

  const secrets = [
    "0x00000000000000000000000000000000000000000000000000000000000000aa" as `0x${string}`,
    "0x0000000000000000000000000000000000000000000000000000000000000055" as `0x${string}`,
  ];

  const entropyResult = gateway.resolvePhysicalEntropy({
    round: 100n,
    revealedSecrets: secrets,
  });

  assert.equal(entropyResult.contributorCount, 2);
  // 0xaa ^ 0x55 = 0xff
  assert.equal(entropyResult.accumulator, 0xffn);
  assert.match(entropyResult.seed, /^0x[a-f0-9]{64}$/);
});
