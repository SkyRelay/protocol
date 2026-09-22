import assert from "node:assert/strict";
import { test } from "node:test";
import {
  BASELINE_STATIONS,
  computeBaselinePair,
  runTriangulationQuorum,
  stationBaselineDistanceKm,
  stationLineOfSight,
  TriangulationError,
  TRIANGULATION_MAX_FDOA_RESIDUAL_HZ,
} from "../src/orbit/triangulation.ts";
import { parse3le } from "../src/orbit/tle.ts";
import { initSgp4, propagate } from "../src/orbit/sgp4.ts";
import { epochToJulian, gstime, julianDate, temeToEcef, temeVelocityToEcef } from "../src/orbit/coords.ts";
import type { Vec3 } from "../src/orbit/sgp4.ts";
import { KU_DOWNLINK_HZ } from "../src/orbit/constants.ts";

const SAMPLE_STARLINK_TLE = `STARLINK-31042
1 58921U 24026B   24040.50000000  .00001234  00000-0  12345-3 0  9999
2 58921  53.0543 120.1234 0001452  85.1234 274.9876 15.06412345 12345`;

test("baseline distances between ground stations reflect physical European geography", () => {
  const dValentiaGoonhilly = stationBaselineDistanceKm(
    BASELINE_STATIONS.VALENTIA_01,
    BASELINE_STATIONS.GOONHILLY_02,
  );
  // Valentia Island, Kerry to Goonhilly, Cornwall is ~410 km chord length
  assert.ok(dValentiaGoonhilly > 380 && dValentiaGoonhilly < 440, `Valentia-Goonhilly baseline: ${dValentiaGoonhilly} km`);

  const dValentiaPleumeur = stationBaselineDistanceKm(
    BASELINE_STATIONS.VALENTIA_01,
    BASELINE_STATIONS.PLEUMEUR_03,
  );
  // Valentia to Pleumeur-Bodou across Celtic Sea is ~580 km
  assert.ok(dValentiaPleumeur > 540 && dValentiaPleumeur < 620, `Valentia-Pleumeur baseline: ${dValentiaPleumeur} km`);

  const dGoonhillyPleumeur = stationBaselineDistanceKm(
    BASELINE_STATIONS.GOONHILLY_02,
    BASELINE_STATIONS.PLEUMEUR_03,
  );
  // Goonhilly across English Channel to Pleumeur is ~190 km
  assert.ok(dGoonhillyPleumeur > 160 && dGoonhillyPleumeur < 220, `Goonhilly-Pleumeur baseline: ${dGoonhillyPleumeur} km`);
});

test("simultaneous line of sight from multiple stations yields differential Doppler (FDOA) and TDOA", () => {
  // Typical LEO satellite position 550km above Celtic Sea (between Ireland and UK)
  // ECEF coordinates roughly: Lat 51N, Lon -7W, Alt 550km
  const satEcefKm: Vec3 = [3950.0, -485.0, 5450.0];
  // Orbital velocity ~7.56 km/s predominantly heading southeast in inclined orbit
  const satVelEcefKmS: Vec3 = [-3.8, 5.2, 3.9];

  const losValentia = stationLineOfSight(BASELINE_STATIONS.VALENTIA_01, satEcefKm, satVelEcefKmS);
  const losGoonhilly = stationLineOfSight(BASELINE_STATIONS.GOONHILLY_02, satEcefKm, satVelEcefKmS);

  // Both stations should have slant range between 300 km and 1500 km
  assert.ok(losValentia.rangeKm > 300 && losValentia.rangeKm < 1500);
  assert.ok(losGoonhilly.rangeKm > 300 && losGoonhilly.rangeKm < 1500);

  // Doppler shifts at 11.7 GHz should be within physical LEO envelope (±250 kHz)
  assert.ok(Math.abs(losValentia.dopplerHz) < 250000);
  assert.ok(Math.abs(losGoonhilly.dopplerHz) < 250000);

  const baselinePair = computeBaselinePair(
    { station: BASELINE_STATIONS.VALENTIA_01 },
    { station: BASELINE_STATIONS.GOONHILLY_02 },
    satEcefKm,
    satVelEcefKmS,
  );

  // Subtended angle between rays should be between 10° and 60° for this geometry
  assert.ok(baselinePair.subtendedAngleDeg > 5 && baselinePair.subtendedAngleDeg < 80);
  // TDOA should be within theoretical bounds |Δτ| <= Baseline / c (~1.4 ms)
  assert.ok(Math.abs(baselinePair.theoreticalTdoaSec) < 0.002);
  // Differential Doppler (FDOA) exists and is non-zero because stations see different line-of-sight velocities
  assert.notEqual(baselinePair.theoreticalFdoaHz, 0);
});

test("consistent multi-station observations satisfy triangulation quorum within < 3 Hz tolerance", () => {
  const satEcefKm: Vec3 = [3950.0, -485.0, 5450.0];
  const satVelEcefKmS: Vec3 = [-3.8, 5.2, 3.9];

  // Ground truth theoretical Doppler for the 3 stations
  const losV = stationLineOfSight(BASELINE_STATIONS.VALENTIA_01, satEcefKm, satVelEcefKmS);
  const losG = stationLineOfSight(BASELINE_STATIONS.GOONHILLY_02, satEcefKm, satVelEcefKmS);
  const losP = stationLineOfSight(BASELINE_STATIONS.PLEUMEUR_03, satEcefKm, satVelEcefKmS);

  // Simulate realistic measurement noise (e.g. ±0.8 Hz)
  const obsV = {
    station: BASELINE_STATIONS.VALENTIA_01,
    observedDopplerHz: losV.dopplerHz + 0.5,
  };
  const obsG = {
    station: BASELINE_STATIONS.GOONHILLY_02,
    observedDopplerHz: losG.dopplerHz - 0.4,
  };
  const obsP = {
    station: BASELINE_STATIONS.PLEUMEUR_03,
    observedDopplerHz: losP.dopplerHz + 0.3,
  };

  const report = runTriangulationQuorum({
    noradId: 58921,
    timestamp: 1711000000,
    satEcefKm,
    satVelEcefKmS,
    observations: [obsV, obsG, obsP],
    maxToleranceHz: TRIANGULATION_MAX_FDOA_RESIDUAL_HZ,
  });

  assert.equal(report.stationCount, 3);
  // 3 stations produce 3 pairwise baselines: V-G, V-P, G-P
  assert.equal(report.baselinePairs.length, 3);
  assert.ok(report.isTriangulationVerified);
  // Max residual must be well within < 3 Hz
  assert.ok(report.maxFdoaResidualHz < 3.0, `Observed max residual: ${report.maxFdoaResidualHz} Hz`);
  // Precision gain factor should show significant tightening over 12 Hz single station
  assert.ok(report.precisionGainFactor >= 4.0, `Precision factor: ${report.precisionGainFactor}`);
});

test("an anomalous or spoofed station is mathematically rejected by triangulation", () => {
  const satEcefKm: Vec3 = [3950.0, -485.0, 5450.0];
  const satVelEcefKmS: Vec3 = [-3.8, 5.2, 3.9];

  const losV = stationLineOfSight(BASELINE_STATIONS.VALENTIA_01, satEcefKm, satVelEcefKmS);
  const losG = stationLineOfSight(BASELINE_STATIONS.GOONHILLY_02, satEcefKm, satVelEcefKmS);

  // Attacker at Goonhilly submits an uncoordinated Doppler frequency (deviating by 25 Hz)
  const obsV = {
    station: BASELINE_STATIONS.VALENTIA_01,
    observedDopplerHz: losV.dopplerHz,
  };
  const obsGSpoofed = {
    station: BASELINE_STATIONS.GOONHILLY_02,
    observedDopplerHz: losG.dopplerHz + 25.0, // 25 Hz spoof error
  };

  assert.throws(
    () => {
      runTriangulationQuorum({
        noradId: 58921,
        timestamp: 1711000000,
        satEcefKm,
        satVelEcefKmS,
        observations: [obsV, obsGSpoofed],
        maxToleranceHz: 3.0,
      });
    },
    (err: unknown) => {
      assert.ok(err instanceof TriangulationError);
      assert.match(err.message, /Triangulation FDOA residual/);
      assert.ok(err.residualHz! > 20);
      return true;
    },
  );
});

test("triangulation requires at least 2 stations", () => {
  const satEcefKm: Vec3 = [3950.0, -485.0, 5450.0];
  const satVelEcefKmS: Vec3 = [-3.8, 5.2, 3.9];

  assert.throws(
    () => {
      runTriangulationQuorum({
        noradId: 58921,
        timestamp: 1711000000,
        satEcefKm,
        satVelEcefKmS,
        observations: [{ station: BASELINE_STATIONS.VALENTIA_01 }],
      });
    },
    /at least 2 independent ground stations/,
  );
});
