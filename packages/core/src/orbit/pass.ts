import { DEG2RAD, RAD2DEG } from "./constants.ts";
import {
  epochToJulian,
  gstime,
  julianDate,
  lookAngles,
  temeToEcef,
  temeVelocityToEcef,
} from "./coords.ts";
import { dopplerHz } from "./doppler.ts";
import { initSgp4, propagate } from "./sgp4.ts";
import type { Tle } from "./tle.ts";

export type Station = {
  id: string;
  name: string;
  latDeg: number;
  lonDeg: number;
  altKm?: number;
};

export const GENESIS_01: Station = {
  id: "GENESIS-01",
  name: "南溟一号",
  latDeg: 18.23,
  lonDeg: 109.51,
  altKm: 0.05,
};

export type Overhead = {
  name: string;
  noradId: number;
  azimuthDeg: number;
  elevationDeg: number;
  dopplerHz: number;
  rangeKm: number;
  rangeRateKmS: number;
  tsinceMin: number;
};

function dateToJd(when: Date): number {
  return julianDate(
    when.getUTCFullYear(),
    when.getUTCMonth() + 1,
    when.getUTCDate(),
    when.getUTCHours(),
    when.getUTCMinutes(),
    when.getUTCSeconds() + when.getUTCMilliseconds() / 1000,
  );
}

export function observe(tle: Tle, station: Station, when: Date): Overhead {
  const epoch = epochToJulian(tle.epochYear, tle.epochDay);
  const jdNow = dateToJd(when);
  const tsinceMin = (jdNow - (epoch.jd + epoch.fr)) * 1440;
  const rv = propagate(initSgp4(tle), tsinceMin);
  const gmst = gstime(jdNow);
  const rEcef = temeToEcef(rv.positionKm, gmst);
  const vEcef = temeVelocityToEcef(rv.velocityKmS, rEcef, gmst);
  const look = lookAngles(station.latDeg, station.lonDeg, station.altKm ?? 0, rEcef, vEcef);
  return {
    name: tle.name || `NORAD-${tle.noradId}`,
    noradId: tle.noradId,
    azimuthDeg: look.azimuthDeg,
    elevationDeg: look.elevationDeg,
    dopplerHz: dopplerHz(look.rangeRateKmS),
    rangeKm: look.rangeKm,
    rangeRateKmS: look.rangeRateKmS,
    tsinceMin,
  };
}

/** Angular separation between two topocentric directions, in degrees. */
export function angularSeparationDeg(
  a: { azimuthDeg: number; elevationDeg: number },
  b: { azimuthDeg: number; elevationDeg: number },
): number {
  const e1 = a.elevationDeg * DEG2RAD;
  const e2 = b.elevationDeg * DEG2RAD;
  const da = (a.azimuthDeg - b.azimuthDeg) * DEG2RAD;
  const cos = Math.sin(e1) * Math.sin(e2) + Math.cos(e1) * Math.cos(e2) * Math.cos(da);
  return Math.acos(Math.min(1, Math.max(-1, cos))) * RAD2DEG;
}

/**
 * How far the reported boresight may sit from the propagated look angle before
 * the capture is rejected. A user terminal tracks its serving satellite to well
 * inside a degree; the budget here absorbs SGP4 along-track error at a
 * half-day-old element set plus the terminal's own reporting quantisation.
 */
export const DEFAULT_BORESIGHT_TOLERANCE_DEG = 2;

export type BoresightSighting = Overhead & {
  /** Angle between the terminal's reported boresight and this satellite. */
  boresightResidualDeg: number;
};

/**
 * Identify which catalog satellite actually explains the terminal's reported
 * boresight, and refuse the capture when none of them does.
 *
 * This is the only geometric binding the protocol has that a fabricated capture
 * cannot trivially satisfy: the forger must find a station, an instant, and a
 * real element set that together put a satellite where the dish claims to be
 * looking. Picking the highest satellite instead would accept any capture at
 * all, and falling back to the self-reported boresight would check nothing.
 */
export function matchBoresight(
  tles: Tle[],
  station: Station,
  when: Date,
  boresight: { azimuthDeg: number; elevationDeg: number },
  toleranceDeg: number = DEFAULT_BORESIGHT_TOLERANCE_DEG,
): BoresightSighting {
  if (tles.length === 0) throw new Error("empty TLE catalog");
  let best: BoresightSighting | undefined;
  for (const tle of tles) {
    const o = observe(tle, station, when);
    if (o.elevationDeg <= 0) continue;
    const boresightResidualDeg = angularSeparationDeg(o, boresight);
    if (!best || boresightResidualDeg < best.boresightResidualDeg) {
      best = { ...o, boresightResidualDeg };
    }
  }
  if (!best) {
    throw new Error(
      `no catalog satellite is above the horizon at ${station.id} on ${when.toISOString()}`,
    );
  }
  if (best.boresightResidualDeg > toleranceDeg) {
    throw new Error(
      `boresight ${boresight.azimuthDeg.toFixed(2)}/${boresight.elevationDeg.toFixed(2)} deg is ` +
        `${best.boresightResidualDeg.toFixed(2)} deg from the nearest catalog satellite ` +
        `(NORAD ${best.noradId}); tolerance is ${toleranceDeg} deg`,
    );
  }
  return best;
}
