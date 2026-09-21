import { KU_DOWNLINK_HZ, SPEED_OF_LIGHT_KMS } from "./constants.ts";

/**
 * Classical two-way-independent downlink Doppler:
 *   f_d = − (ṙ / c) f_c
 * ṙ is the geometric range-rate (km/s), positive when the satellite recedes.
 * f_c defaults to the Starlink Ku user-downlink centre 11.7 GHz.
 *
 * Relativistic and ionospheric terms are omitted; they are ~10⁻⁸ relative
 * at LEO Ku and sit well below SGP4's kilometre-class geometric error.
 */
export function dopplerHz(
  rangeRateKmS: number,
  carrierHz: number = KU_DOWNLINK_HZ,
): number {
  return -(rangeRateKmS / SPEED_OF_LIGHT_KMS) * carrierHz;
}
