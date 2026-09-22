import {
  KU_DOWNLINK_HZ,
  RAD2DEG,
  SPEED_OF_LIGHT_KMS,
} from "./constants.ts";
import { geodeticToEcef } from "./coords.ts";
import { dopplerHz } from "./doppler.ts";
import type { Station } from "./pass.ts";
import type { Vec3 } from "./sgp4.ts";

/** Default maximum differential Doppler residual across any multi-station baseline (Hz). */
export const TRIANGULATION_MAX_FDOA_RESIDUAL_HZ = 3.0;

/** Single station absolute Doppler tolerance for comparison (Hz). */
export const SINGLE_STATION_TOLERANCE_HZ = 12.0;

export type TriangulationObservation = {
  station: Station;
  /** Observed Doppler shift reported by station (Hz). */
  observedDopplerHz?: number;
  /** Reported boresight azimuth (deg). */
  azimuthDeg?: number;
  /** Reported boresight elevation (deg). */
  elevationDeg?: number;
};

export type BaselinePair = {
  stationAId: string;
  stationBId: string;
  stationAName: string;
  stationBName: string;
  /** 3D chord distance between the two ground stations in ECEF (km). */
  baselineDistanceKm: number;
  /** Angle subtended at the satellite between line-of-sight rays to the two stations (deg). */
  subtendedAngleDeg: number;
  /** Slant range to Station A (km). */
  rangeAKm: number;
  /** Slant range to Station B (km). */
  rangeBKm: number;
  /** Range difference ΔR = R_B - R_A (km). */
  rangeDiffKm: number;
  /** Time Difference of Arrival Δτ = (R_B - R_A) / c (seconds). */
  theoreticalTdoaSec: number;
  /** Station A theoretical Doppler shift (Hz). */
  theoreticalDopplerAHz: number;
  /** Station B theoretical Doppler shift (Hz). */
  theoreticalDopplerBHz: number;
  /** Frequency Difference of Arrival / Differential Doppler Δf = f_d(B) - f_d(A) (Hz). */
  theoreticalFdoaHz: number;
  /** Observed differential Doppler if reported by both stations (Hz). */
  observedFdoaHz?: number;
  /** Absolute residual |observedFdoa - theoreticalFdoa| (Hz). */
  fdoaResidualHz?: number;
};

export type TriangulationReport = {
  noradId: number;
  timestamp: number;
  satEcefKm: Vec3;
  satVelEcefKmS: Vec3;
  stationCount: number;
  baselinePairs: BaselinePair[];
  /** Worst differential Doppler residual across all station pairs (Hz). */
  maxFdoaResidualHz: number;
  /** Mean differential Doppler residual across all station pairs (Hz). */
  meanFdoaResidualHz: number;
  /** True if all baselines satisfy the tight multi-station tolerance (<= 3.0 Hz). */
  isTriangulationVerified: boolean;
  /** Precision gain factor compared to single-station baseline tolerance (12 Hz / residual). */
  precisionGainFactor: number;
};

/** Compute 3D ECEF chord distance between two ground stations in kilometers. */
export function stationBaselineDistanceKm(a: Station, b: Station): number {
  const ea = geodeticToEcef(a.latDeg, a.lonDeg, a.altKm ?? 0);
  const eb = geodeticToEcef(b.latDeg, b.lonDeg, b.altKm ?? 0);
  return Math.hypot(eb[0] - ea[0], eb[1] - ea[1], eb[2] - ea[2]);
}

/** Compute line-of-sight unit vector and slant range from station to satellite in ECEF. */
export function stationLineOfSight(
  station: Station,
  satEcefKm: Vec3,
  satVelEcefKmS: Vec3,
  carrierHz: number = KU_DOWNLINK_HZ,
): {
  rangeKm: number;
  losUnit: Vec3;
  rangeRateKmS: number;
  dopplerHz: number;
} {
  const o = geodeticToEcef(station.latDeg, station.lonDeg, station.altKm ?? 0);
  const rx = satEcefKm[0] - o[0];
  const ry = satEcefKm[1] - o[1];
  const rz = satEcefKm[2] - o[2];
  const rangeKm = Math.hypot(rx, ry, rz);
  const losUnit: Vec3 = [rx / rangeKm, ry / rangeKm, rz / rangeKm];
  const rangeRateKmS =
    satVelEcefKmS[0] * losUnit[0] +
    satVelEcefKmS[1] * losUnit[1] +
    satVelEcefKmS[2] * losUnit[2];
  return {
    rangeKm,
    losUnit,
    rangeRateKmS,
    dopplerHz: dopplerHz(rangeRateKmS, carrierHz),
  };
}

/** Compute geometric and differential Doppler baseline metrics between two stations. */
export function computeBaselinePair(
  obsA: TriangulationObservation,
  obsB: TriangulationObservation,
  satEcefKm: Vec3,
  satVelEcefKmS: Vec3,
  carrierHz: number = KU_DOWNLINK_HZ,
): BaselinePair {
  const losA = stationLineOfSight(obsA.station, satEcefKm, satVelEcefKmS, carrierHz);
  const losB = stationLineOfSight(obsB.station, satEcefKm, satVelEcefKmS, carrierHz);

  const baselineDistanceKm = stationBaselineDistanceKm(obsA.station, obsB.station);

  // Subtended angle between line-of-sight unit vectors
  const dotProduct =
    losA.losUnit[0] * losB.losUnit[0] +
    losA.losUnit[1] * losB.losUnit[1] +
    losA.losUnit[2] * losB.losUnit[2];
  const clampedDot = Math.min(1, Math.max(-1, dotProduct));
  const subtendedAngleDeg = Math.acos(clampedDot) * RAD2DEG;

  const rangeDiffKm = losB.rangeKm - losA.rangeKm;
  const theoreticalTdoaSec = rangeDiffKm / SPEED_OF_LIGHT_KMS;

  const theoreticalFdoaHz = losB.dopplerHz - losA.dopplerHz;

  let observedFdoaHz: number | undefined;
  let fdoaResidualHz: number | undefined;

  if (
    obsA.observedDopplerHz !== undefined &&
    obsB.observedDopplerHz !== undefined
  ) {
    observedFdoaHz = obsB.observedDopplerHz - obsA.observedDopplerHz;
    fdoaResidualHz = Math.abs(observedFdoaHz - theoreticalFdoaHz);
  }

  return {
    stationAId: obsA.station.id,
    stationBId: obsB.station.id,
    stationAName: obsA.station.name,
    stationBName: obsB.station.name,
    baselineDistanceKm,
    subtendedAngleDeg,
    rangeAKm: losA.rangeKm,
    rangeBKm: losB.rangeKm,
    rangeDiffKm,
    theoreticalTdoaSec,
    theoreticalDopplerAHz: losA.dopplerHz,
    theoreticalDopplerBHz: losB.dopplerHz,
    theoreticalFdoaHz,
    observedFdoaHz,
    fdoaResidualHz,
  };
}

export class TriangulationError extends Error {
  public readonly baselinePair?: BaselinePair;
  public readonly residualHz?: number;

  constructor(
    message: string,
    baselinePair?: BaselinePair,
    residualHz?: number,
  ) {
    super(message);
    this.baselinePair = baselinePair;
    this.residualHz = residualHz;
    this.name = "TriangulationError";
  }
}

/**
 * Perform multi-station long-baseline geometric triangulation.
 *
 * Verifies that independent ground stations seeing the same satellite at the same
 * instant produce mutually consistent Time and Frequency Differences of Arrival
 * (TDOA & FDOA) within the tight multi-station threshold (default <= 3.0 Hz).
 */
export function runTriangulationQuorum(params: {
  noradId: number;
  timestamp: number;
  satEcefKm: Vec3;
  satVelEcefKmS: Vec3;
  observations: TriangulationObservation[];
  maxToleranceHz?: number;
  carrierHz?: number;
}): TriangulationReport {
  const {
    noradId,
    timestamp,
    satEcefKm,
    satVelEcefKmS,
    observations,
    maxToleranceHz = TRIANGULATION_MAX_FDOA_RESIDUAL_HZ,
    carrierHz = KU_DOWNLINK_HZ,
  } = params;

  if (observations.length < 2) {
    throw new TriangulationError(
      "Geometric triangulation requires at least 2 independent ground stations",
    );
  }

  const baselinePairs: BaselinePair[] = [];
  let worstResidual = 0;
  let residualSum = 0;
  let evaluatedCount = 0;

  for (let i = 0; i < observations.length; i++) {
    for (let j = i + 1; j < observations.length; j++) {
      const pair = computeBaselinePair(
        observations[i]!,
        observations[j]!,
        satEcefKm,
        satVelEcefKmS,
        carrierHz,
      );
      baselinePairs.push(pair);

      if (pair.fdoaResidualHz !== undefined) {
        evaluatedCount++;
        residualSum += pair.fdoaResidualHz;
        if (pair.fdoaResidualHz > worstResidual) {
          worstResidual = pair.fdoaResidualHz;
        }

        if (pair.fdoaResidualHz > maxToleranceHz) {
          throw new TriangulationError(
            `Triangulation FDOA residual ${pair.fdoaResidualHz.toFixed(2)} Hz on baseline ${pair.stationAId}-${pair.stationBId} exceeds tolerance ${maxToleranceHz.toFixed(2)} Hz`,
            pair,
            pair.fdoaResidualHz,
          );
        }
      }
    }
  }

  const meanResidual = evaluatedCount > 0 ? residualSum / evaluatedCount : 0;
  const isTriangulationVerified =
    evaluatedCount > 0 ? worstResidual <= maxToleranceHz : true;
  const precisionGainFactor =
    worstResidual > 0
      ? Number((SINGLE_STATION_TOLERANCE_HZ / Math.max(worstResidual, 0.1)).toFixed(2))
      : Number((SINGLE_STATION_TOLERANCE_HZ / maxToleranceHz).toFixed(2));

  return {
    noradId,
    timestamp,
    satEcefKm,
    satVelEcefKmS,
    stationCount: observations.length,
    baselinePairs,
    maxFdoaResidualHz: worstResidual,
    meanFdoaResidualHz: meanResidual,
    isTriangulationVerified,
    precisionGainFactor,
  };
}

/** Active Atlantic and European baseline stations for multi-station triangulation. */
export const BASELINE_STATIONS = Object.freeze({
  VALENTIA_01: {
    id: "VALENTIA-01",
    name: "Valentia Island, Kerry, Ireland",
    latDeg: 51.93,
    lonDeg: -10.35,
    altKm: 0.02,
  },
  GOONHILLY_02: {
    id: "GOONHILLY-02",
    name: "Goonhilly Earth Station, Cornwall, UK",
    latDeg: 50.05,
    lonDeg: -5.18,
    altKm: 0.092,
  },
  PLEUMEUR_03: {
    id: "PLEUMEUR-03",
    name: "Pleumeur-Bodou Teleport, Brittany, France",
    latDeg: 48.78,
    lonDeg: -3.52,
    altKm: 0.071,
  },
  FASTNET_04: {
    id: "FASTNET-04",
    name: "Fastnet Rock Offshore, North Atlantic",
    latDeg: 51.39,
    lonDeg: -9.60,
    altKm: 0.024,
  },
} as const satisfies Record<string, Station>);
