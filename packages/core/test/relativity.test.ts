import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createRelativisticTimeAnchor,
  gravitationalTimeDilation,
  kinematicTimeDilation,
  netRelativisticDilation,
  tcaDopplerRateHzS,
} from "../src/orbit/relativity.ts";
import { KU_DOWNLINK_HZ } from "../src/orbit/constants.ts";

test("kinematic time dilation matches Special Relativity for LEO orbital velocity", () => {
  // At 7.56 km/s, kinematic dilation is negative (moving clocks tick slower)
  const k = kinematicTimeDilation(7.56);
  assert.ok(k < 0, "kinematic dilation must be negative");

  // In microseconds per day: -0.5 * (7.56 / 299792.458)^2 * 86,400 * 1e6 ≈ -27.5 microseconds/day
  const usPerDay = k * 86_400_000_000;
  assert.ok(usPerDay > -29.0 && usPerDay < -26.0, `kinematic drift: ${usPerDay} us/day`);
});

test("gravitational time dilation matches General Relativity for 550km LEO altitude", () => {
  // At 550 km, gravitational dilation is positive (clocks higher in potential tick faster)
  const g = gravitationalTimeDilation(550);
  assert.ok(g > 0, "gravitational dilation must be positive");

  // In microseconds per day: ΔΦ / c^2 * 86,400 * 1e6 ≈ +4.77 microseconds/day
  const usPerDay = g * 86_400_000_000;
  assert.ok(usPerDay > 4.0 && usPerDay < 6.0, `gravitational drift: ${usPerDay} us/day`);
});

test("net relativistic dilation reflects combined Einsteinian clock advance", () => {
  const net = netRelativisticDilation(7.56, 550);
  // Net LEO drift is ~ -22.7 microseconds/day (kinematic slowing exceeds gravitational gain in LEO)
  assert.ok(
    net.netMicrosecondsPerDay > -24.0 && net.netMicrosecondsPerDay < -21.0,
    `net drift: ${net.netMicrosecondsPerDay} us/day`,
  );
  assert.ok(net.fractionalDrift < 0);
});

test("tcaDopplerRateHzS computes maximum Doppler inflection rate at zero-crossing", () => {
  // At 7.56 km/s and 550 km minimum slant range, df/dt ≈ -4050 Hz/s at 11.7 GHz
  const slope = tcaDopplerRateHzS(7.56, 550, KU_DOWNLINK_HZ);
  assert.ok(slope < -3500 && slope > -4500, `TCA slope: ${slope} Hz/s`);
});

test("createRelativisticTimeAnchor produces verifiable anchor parameters", () => {
  const anchor = createRelativisticTimeAnchor({
    noradId: 47352,
    timestampSec: 1789934703,
    elevationDeg: 65.2,
    rangeKm: 620,
    rangeRateKmS: 0.12,
    dopplerHz: -4680,
  });

  assert.equal(anchor.noradId, 47352);
  assert.equal(anchor.timestampSec, 1789934703);
  assert.ok(anchor.tcaDopplerSlopeHzS < 0);
  assert.ok(anchor.netDriftUsPerDay < -20 && anchor.netDriftUsPerDay > -25);
  assert.ok(anchor.dilationFactor > 0.999 && anchor.dilationFactor < 1.0);
  assert.ok(anchor.timeAnchorDigestHex.length > 20);
});
