import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { checkPassShape, runPassTrack, type PassSample } from "../src/track.ts";
import { parse3le, type Tle } from "../src/orbit/tle.ts";
import type { Station } from "../src/orbit/pass.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const CATALOG: Tle[] = readdirSync(join(root, "vectors/tle"))
  .filter((f) => f.startsWith("starlink-") && f.endsWith(".txt"))
  .sort()
  .map((f) => parse3le(readFileSync(join(root, "vectors/tle", f), "utf8")));

const DOMAIN = {
  chainId: 97,
  verifyingContract: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC" as `0x${string}`,
};
const OPERATOR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const;

const trackFixture = () =>
  JSON.parse(readFileSync(join(root, "vectors/tracks/genesis-01-44714.json"), "utf8")) as {
    station: Station;
    expectNoradId: number;
    frames: unknown[];
  };

const resolved = () => {
  const t = trackFixture();
  return runPassTrack({
    captures: t.frames,
    station: t.station,
    catalog: CATALOG,
    domain: DOMAIN,
    operator: OPERATOR,
  });
};

/** The three fields the chain publishes, which is all the shape check needs. */
const samples = (): PassSample[] =>
  resolved().reports.map((r) => ({
    timestamp: r.attestation.timestamp,
    elevationMilliDeg: r.attestation.elevationMilliDeg,
    dopplerHz: r.attestation.dopplerHz,
  }));

test("the committed track resolves to one satellite and forms a pass", () => {
  const t = resolved();
  assert.equal(t.noradId, trackFixture().expectNoradId);
  assert.equal(t.shape.sampleCount, 9);
  assert.ok(t.shape.crossesZeroDoppler, "the track must span closest approach");
  assert.ok(t.shape.peakIndex > 0 && t.shape.peakIndex < 8, "the peak must be inside the track");
  assert.ok(t.shape.peakElevationMilliDeg > 70_000, "this pass peaks above 70 degrees");
});

/**
 * The point of the shape check: it needs nothing but what `StationReport` puts
 * on chain. No captures, no element sets, nobody to trust.
 */
test("the shape check runs on chain-visible fields alone", () => {
  const shape = checkPassShape(samples());
  assert.equal(shape.sampleCount, 9);
  assert.equal(shape.durationSec, 480);
  assert.ok(shape.maxDopplerHz > 0 && shape.minDopplerHz < 0);
});

test("Doppler falls strictly from approach to recession", () => {
  const s = samples();
  for (let i = 1; i < s.length; i++) {
    assert.ok(s[i]!.dopplerHz < s[i - 1]!.dopplerHz, `sample ${i} did not fall`);
  }
});

// ── the negatives: each one is a forgery the shape check has to catch ───────

test("a track whose Doppler stops falling is rejected", () => {
  const s = samples();
  s[5]!.dopplerHz = s[4]!.dopplerHz + 1_000;
  assert.throws(() => checkPassShape(s), /Doppler must fall through a pass/);
});

test("a track with two elevation peaks is rejected", () => {
  const s = samples();
  // push a late sample back above its neighbour, inventing a second maximum
  s[7]!.elevationMilliDeg = s[6]!.elevationMilliDeg + 5_000;
  assert.throws(() => checkPassShape(s), /elevation does not fall monotonically/);
});

test("a track that dips on the way up is rejected", () => {
  const s = samples();
  s[2]!.elevationMilliDeg = s[1]!.elevationMilliDeg - 1;
  assert.throws(() => checkPassShape(s), /elevation does not rise monotonically/);
});

test("samples out of time order are rejected", () => {
  const s = samples();
  const swap = s[3]!;
  s[3] = s[4]!;
  s[4] = swap;
  assert.throws(() => checkPassShape(s), /not in time order|Doppler must fall/);
});

test("a sample below the horizon is rejected", () => {
  const s = samples();
  s[0]!.elevationMilliDeg = -1;
  assert.throws(() => checkPassShape(s), /below the horizon/);
});

test("a physically impossible Doppler is rejected", () => {
  const s = samples();
  s[0]!.dopplerHz = 5_000_000;
  assert.throws(() => checkPassShape(s), /exceeds the LEO Ku envelope/);
});

test("fewer than three samples have no shape", () => {
  assert.throws(() => checkPassShape(samples().slice(0, 2)), /at least three samples/);
});

test("a track spanning two satellites is rejected", () => {
  const t = trackFixture();
  const other = JSON.parse(
    readFileSync(join(root, "vectors/frames/obstructed-003.json"), "utf8"),
  );
  assert.throws(
    () =>
      runPassTrack({
        captures: [...t.frames.slice(0, 3), other],
        station: t.station,
        catalog: CATALOG,
        domain: DOMAIN,
        operator: OPERATOR,
      }),
    /one satellite|boresight/,
  );
});
