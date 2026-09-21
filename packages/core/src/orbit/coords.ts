import {
  DEG2RAD,
  EARTH_ROTATION_RAD_S,
  RAD2DEG,
  TWO_PI,
  WGS72,
  WGS72_FLATTENING,
} from "./constants.ts";
import type { Vec3 } from "./sgp4.ts";

/** Vallado julian date (days from noon-based astronomical JD, UTC). */
export function julianDate(
  year: number,
  month: number,
  day: number,
  hour = 0,
  minute = 0,
  sec = 0,
): number {
  return (
    367 * year -
    Math.floor((7 * (year + Math.floor((month + 9) / 12))) * 0.25) +
    Math.floor((275 * month) / 9) +
    day +
    1721013.5 +
    ((sec / 60 + minute) / 60 + hour) / 24
  );
}

export function dayOfYearToMd(year: number, doy: number): { month: number; day: number } {
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  let d = Math.floor(doy);
  let m = 1;
  for (const n of dim) {
    if (d <= n) break;
    d -= n;
    m += 1;
  }
  return { month: m, day: d };
}

export function epochToJulian(year: number, epochDay: number): { jd: number; fr: number } {
  const { month, day } = dayOfYearToMd(year, epochDay);
  const frac = epochDay - Math.floor(epochDay);
  const hours = frac * 24;
  const h = Math.floor(hours);
  const minutes = (hours - h) * 60;
  const mi = Math.floor(minutes);
  const sec = (minutes - mi) * 60;
  const full = julianDate(year, month, day, h, mi, sec);
  const jd = Math.floor(full - 0.5) + 0.5;
  return { jd, fr: full - jd };
}

/** Greenwich mean sidereal time (rad) from Julian date. Vallado gstime. */
export function gstime(jd: number): number {
  const tut1 = (jd - 2451545.0) / 36525.0;
  let temp =
    -6.2e-6 * tut1 * tut1 * tut1 +
    0.093104 * tut1 * tut1 +
    (876600 * 3600 + 8640184.812866) * tut1 +
    67310.54841;
  temp = ((temp * Math.PI) / 180 / 240) % TWO_PI;
  if (temp < 0) temp += TWO_PI;
  return temp;
}

/** TEME (SGP4 frame) → ECEF by GMST rotation about Z. */
export function temeToEcef(rTeme: Vec3, gmst: number): Vec3 {
  const c = Math.cos(gmst);
  const s = Math.sin(gmst);
  return [c * rTeme[0] + s * rTeme[1], -s * rTeme[0] + c * rTeme[1], rTeme[2]];
}

/**
 * Geodetic (lat, lon, alt) -> ECEF on the WGS-72 ellipsoid. `latDeg` is the
 * geodetic latitude, so the local vertical is the ellipsoid normal, which is
 * the basis `lookAngles` builds its SEZ frame on.
 */
export function geodeticToEcef(latDeg: number, lonDeg: number, altKm = 0): Vec3 {
  const lat = latDeg * DEG2RAD;
  const lon = lonDeg * DEG2RAD;
  const sl = Math.sin(lat);
  const cl = Math.cos(lat);
  const e2 = WGS72_FLATTENING * (2 - WGS72_FLATTENING);
  const primeVertical = WGS72.radiusEarthKm / Math.sqrt(1 - e2 * sl * sl);
  const rxy = (primeVertical + altKm) * cl;
  return [rxy * Math.cos(lon), rxy * Math.sin(lon), (primeVertical * (1 - e2) + altKm) * sl];
}

/**
 * TEME velocity -> ECEF velocity.
 *
 * The GMST rotation alone is not enough. ECEF rotates, so the transport term
 * must be removed: v_ecef = R(theta) v_teme - omega x r_ecef. Omitting it
 * biases every range-rate by up to |omega| |r| ~ 0.5 km/s, which at Ku band is
 * a ~19 kHz Doppler error.
 */
export function temeVelocityToEcef(vTeme: Vec3, rEcef: Vec3, gmst: number): Vec3 {
  const c = Math.cos(gmst);
  const s = Math.sin(gmst);
  const vx = c * vTeme[0] + s * vTeme[1];
  const vy = -s * vTeme[0] + c * vTeme[1];
  return [
    vx + EARTH_ROTATION_RAD_S * rEcef[1],
    vy - EARTH_ROTATION_RAD_S * rEcef[0],
    vTeme[2],
  ];
}

export type LookAngles = {
  azimuthDeg: number;
  elevationDeg: number;
  rangeKm: number;
  rangeRateKmS: number;
};

/**
 * Topocentric look angles and range-rate from an ECEF observer to an ECEF
 * satellite state. Azimuth is clockwise from north, elevation from local
 * horizon. Range-rate is the line-of-sight derivative (km/s).
 */
export function lookAngles(
  observerLatDeg: number,
  observerLonDeg: number,
  observerAltKm: number,
  satEcefKm: Vec3,
  satVelEcefKmS: Vec3,
): LookAngles {
  const o = geodeticToEcef(observerLatDeg, observerLonDeg, observerAltKm);
  const rx = satEcefKm[0] - o[0];
  const ry = satEcefKm[1] - o[1];
  const rz = satEcefKm[2] - o[2];
  const range = Math.hypot(rx, ry, rz);
  const lat = observerLatDeg * DEG2RAD;
  const lon = observerLonDeg * DEG2RAD;
  const slat = Math.sin(lat);
  const clat = Math.cos(lat);
  const slon = Math.sin(lon);
  const clon = Math.cos(lon);
  const south = slat * clon * rx + slat * slon * ry - clat * rz;
  const east = -slon * rx + clon * ry;
  const up = clat * clon * rx + clat * slon * ry + slat * rz;
  // Clamp before asin: for a satellite at the zenith, up/range rounds to
  // slightly above 1 and asin returns NaN. The arithmetic is platform
  // dependent, so an unclamped call fails on some Node versions and not others.
  const sinElevation = Math.min(1, Math.max(-1, up / range));
  const elevationDeg = Math.asin(sinElevation) * RAD2DEG;
  let azimuthDeg = Math.atan2(east, -south) * RAD2DEG;
  if (azimuthDeg < 0) azimuthDeg += 360;
  const losX = rx / range;
  const losY = ry / range;
  const losZ = rz / range;
  const rangeRateKmS = satVelEcefKmS[0] * losX + satVelEcefKmS[1] * losY + satVelEcefKmS[2] * losZ;
  return { azimuthDeg, elevationDeg, rangeKm: range, rangeRateKmS };
}
