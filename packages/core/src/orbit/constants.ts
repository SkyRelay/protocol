/**
 * WGS-72 constants as used by NORAD SGP4 (Vallado et al., AIAA 2006-6753).
 * SGP4 TLEs are fitted in this frame; substituting WGS-84 here would bias
 * TEME positions by hundreds of metres.
 */
export const WGS72 = Object.freeze({
  radiusEarthKm: 6378.135,
  muKm3s2: 398600.8,
  j2: 0.001082616,
  j3: -0.00000253881,
  j4: -0.00000165597,
});

/**
 * WGS-72 flattening. A station must be placed on the ellipsoid, not on a
 * sphere: at mid latitudes the two differ by ~21 km radially and, more
 * importantly, the local vertical tilts by up to f*sin(2*phi) ~ 0.19 deg,
 * which is a hundred times the milli-degree resolution the attestation stores.
 */
export const WGS72_FLATTENING = 1 / 298.26;

/** Earth rotation rate (rad/s) for the TEME -> ECEF velocity transport term. */
export const EARTH_ROTATION_RAD_S = 7.292115146706979e-5;

/** xke = 60 / sqrt(Re^3 / mu)  [rad / min] */
export const XKE = 60 / Math.sqrt(WGS72.radiusEarthKm ** 3 / WGS72.muKm3s2);
export const TUMIN = 1 / XKE;
export const J3OJ2 = WGS72.j3 / WGS72.j2;
export const CK2 = 0.5 * WGS72.j2;
export const CK4 = -0.375 * WGS72.j4;

export const TWO_PI = 2 * Math.PI;
export const DEG2RAD = Math.PI / 180;
export const RAD2DEG = 180 / Math.PI;
export const MINUTES_PER_DAY = 1440;
export const X2O3 = 2 / 3;

/** Ku-band Starlink user-downlink centre used for Doppler (Hz). */
export const KU_DOWNLINK_HZ = 11.7e9;
export const SPEED_OF_LIGHT_KMS = 299792.458;

/** SpaceX customer ASNs accepted by the attestation filter. */
export const STARLINK_ASN = Object.freeze({
  PRIMARY: 14593,
  INDONESIA: 45700,
} as const);

export const ALLOWED_ASN: ReadonlySet<number> = new Set([
  STARLINK_ASN.PRIMARY,
  STARLINK_ASN.INDONESIA,
]);

/** Globally synchronised Starlink UT–satellite reassignment offsets (UTC seconds). */
export const HANDOVER_UTC_OFFSETS = Object.freeze([12, 27, 42, 57]);

export const ATTESTATION_TTL_SEC = 120;
