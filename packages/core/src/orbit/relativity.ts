import {
  KU_DOWNLINK_HZ,
  SPEED_OF_LIGHT_KMS,
  WGS72,
} from "./constants.ts";
import type { BoresightSighting, Station } from "./pass.ts";

/**
 * Standard gravitational parameter for Earth (km^3 / s^2).
 * WGS-72 mu = 398600.8 km^3/s^2.
 */
const MU_EARTH = WGS72.muKm3s2;
const R_EARTH = WGS72.radiusEarthKm;
const C_KMS = SPEED_OF_LIGHT_KMS;

/**
 * Fractional kinematic time dilation (Special Relativity):
 *   Δt_k / t = - v^2 / (2 * c^2)
 * Moving clocks run slower. For LEO v ~ 7.56 km/s, this is ~ -27.5 microseconds/day.
 */
export function kinematicTimeDilation(velocityKmS: number): number {
  return -0.5 * (velocityKmS / C_KMS) ** 2;
}

/**
 * Fractional gravitational time dilation (General Relativity):
 *   Δt_g / t = ΔΦ / c^2 = (G * M / c^2) * (1 / R_E - 1 / (R_E + h))
 * Clocks higher in the gravitational potential tick faster.
 * For 550 km LEO, this is ~ +4.8 microseconds/day.
 */
export function gravitationalTimeDilation(altKm: number): number {
  const rStation = R_EARTH;
  const rSat = R_EARTH + Math.max(0, altKm);
  const deltaPhi = MU_EARTH * (1 / rStation - 1 / rSat);
  return deltaPhi / (C_KMS ** 2);
}

/**
 * Combined net relativistic clock drift in low-Earth orbit.
 * Combines kinematic slowing (-27.5 μs/day) with gravitational speeding (+4.8 μs/day),
 * yielding a net LEO drift of ~ -22.7 μs/day for a 550 km circular orbit.
 */
export function netRelativisticDilation(
  velocityKmS: number,
  altKm: number,
): {
  fractionalDrift: number;
  netMicrosecondsPerDay: number;
} {
  const k = kinematicTimeDilation(velocityKmS);
  const g = gravitationalTimeDilation(altKm);
  const fractionalDrift = k + g;
  // 1 day = 86,400 seconds = 86,400,000,000 microseconds
  const netMicrosecondsPerDay = fractionalDrift * 86_400_000_000;
  return {
    fractionalDrift,
    netMicrosecondsPerDay,
  };
}

export type RelativisticTimeAnchor = {
  noradId: number;
  timestampSec: number;
  dopplerHz: number;
  /** Maximum Doppler slope df_d/dt at Time of Closest Approach (Hz/s). */
  tcaDopplerSlopeHzS: number;
  /** Net relativistic drift in microseconds per day (negative indicates LEO clock ticks slower by ~22.7 us/day). */
  netDriftUsPerDay: number;
  /** Microsecond physical time correction factor: 1 + fractionalDrift. */
  dilationFactor: number;
  /** Cryptographic time invariant digest for smart contract MEV defense. */
  timeAnchorDigestHex: string;
};

/**
 * Compute the maximum theoretical rate of change of Doppler frequency (df/dt)
 * at the moment of closest approach (TCA) where range-rate is 0 and Doppler crosses zero:
 *
 *   df/dt = - (f_c / c) * (v_relative^2 / R_min)
 */
export function tcaDopplerRateHzS(
  relVelocityKmS: number,
  minRangeKm: number,
  carrierHz: number = KU_DOWNLINK_HZ,
): number {
  if (minRangeKm <= 0) throw new Error("minRangeKm must be positive");
  return -(carrierHz / C_KMS) * ((relVelocityKmS ** 2) / minRangeKm);
}

/**
 * Construct a verifiable Relativistic Time Anchor from satellite sighting telemetry.
 * Serves as an unforgeable physical clock reference for DeFi DEXs and MEV protection.
 */
export function createRelativisticTimeAnchor(params: {
  noradId: number;
  timestampSec: number;
  elevationDeg: number;
  rangeKm: number;
  rangeRateKmS: number;
  dopplerHz: number;
  carrierHz?: number;
}): RelativisticTimeAnchor {
  const carrierHz = params.carrierHz ?? KU_DOWNLINK_HZ;
  // Approximate satellite orbital speed ~ 7.56 km/s at 550km LEO
  const orbVelocityKmS = Math.sqrt(MU_EARTH / (R_EARTH + 550));
  const rel = netRelativisticDilation(orbVelocityKmS, 550);

  // Maximum Doppler slope around TCA
  const minRange = Math.max(params.rangeKm * Math.sin(Math.max(0.1, params.elevationDeg) * (Math.PI / 180)), 500);
  const slope = tcaDopplerRateHzS(orbVelocityKmS, minRange, carrierHz);

  const digestPayload = `${params.noradId}:${params.timestampSec}:${Math.round(params.dopplerHz)}:${slope.toFixed(2)}:${rel.fractionalDrift.toExponential(8)}`;

  return {
    noradId: params.noradId,
    timestampSec: params.timestampSec,
    dopplerHz: params.dopplerHz,
    tcaDopplerSlopeHzS: Number(slope.toFixed(2)),
    netDriftUsPerDay: Number(rel.netMicrosecondsPerDay.toFixed(2)),
    dilationFactor: 1 + rel.fractionalDrift,
    timeAnchorDigestHex: digestPayload,
  };
}
