import { runPipeline, type PipelineOutput } from "./pipeline.ts";
import { KU_DOWNLINK_HZ, SPEED_OF_LIGHT_KMS } from "./orbit/constants.ts";
import type { Eip712Domain } from "./crypto/eip712.ts";
import type { Station } from "./orbit/pass.ts";
import type { Tle } from "./orbit/tle.ts";

/**
 * One attested sighting, reduced to the three fields the chain publishes.
 *
 * These are exactly the members of the `StationReport` event, which is the
 * point: a third party indexing BSC can rebuild a track from public logs alone
 * and check its shape, with no captures, no element sets and nobody to trust.
 */
export type PassSample = {
  timestamp: number;
  elevationMilliDeg: number;
  dopplerHz: number;
};

export type PassShape = {
  sampleCount: number;
  durationSec: number;
  peakElevationMilliDeg: number;
  /** Index of the highest sample; the pass rises to it and falls after it. */
  peakIndex: number;
  minDopplerHz: number;
  maxDopplerHz: number;
  /** True when the track spans closest approach. */
  crossesZeroDoppler: boolean;
};

/** No real Ku downlink from low Earth orbit shifts further than this. */
const MAX_PLAUSIBLE_DOPPLER_HZ = Math.ceil((8 / SPEED_OF_LIGHT_KMS) * KU_DOWNLINK_HZ);

/**
 * Check that a sequence of sightings forms one physically coherent pass.
 *
 * A single beacon is three numbers, and three numbers are cheap to invent. A
 * pass is not: orbital mechanics fixes its shape, and the shape is checkable
 * without propagating anything.
 *
 *   - range-rate increases monotonically from approach to recession, so the
 *     Doppler shift falls strictly and crosses zero at most once;
 *   - elevation rises to exactly one maximum and then falls.
 *
 * Verified against eight real passes spanning three satellites, two stations
 * and peak elevations from 6.5 deg to 74 deg. A forger who picks plausible
 * numbers per beacon violates these almost immediately; matching them means
 * simulating the whole pass.
 *
 * This check is not part of what the contract verifies, and it cannot be — the
 * contract sees one beacon at a time. It is what an auditor can run afterwards
 * over the log a station has published.
 */
export function checkPassShape(samples: readonly PassSample[]): PassShape {
  if (samples.length < 3) {
    throw new Error(`a pass needs at least three samples to have a shape, got ${samples.length}`);
  }

  for (let i = 0; i < samples.length; i++) {
    const s = samples[i]!;
    if (s.elevationMilliDeg <= 0) {
      throw new Error(`sample ${i} is below the horizon (${s.elevationMilliDeg} millideg)`);
    }
    if (Math.abs(s.dopplerHz) > MAX_PLAUSIBLE_DOPPLER_HZ) {
      throw new Error(
        `sample ${i} Doppler ${s.dopplerHz} Hz exceeds the LEO Ku envelope of ` +
          `${MAX_PLAUSIBLE_DOPPLER_HZ} Hz`,
      );
    }
    if (i === 0) continue;
    const prev = samples[i - 1]!;
    if (s.timestamp <= prev.timestamp) {
      throw new Error(`samples are not in time order at ${i}: ${prev.timestamp} then ${s.timestamp}`);
    }
    // Range-rate rises monotonically through a pass, and f_d = -(rho_dot/c)*f_c.
    if (s.dopplerHz >= prev.dopplerHz) {
      throw new Error(
        `Doppler must fall through a pass: sample ${i - 1} is ${prev.dopplerHz} Hz ` +
          `and sample ${i} is ${s.dopplerHz} Hz`,
      );
    }
  }

  let peakIndex = 0;
  for (let i = 1; i < samples.length; i++) {
    if (samples[i]!.elevationMilliDeg > samples[peakIndex]!.elevationMilliDeg) peakIndex = i;
  }
  for (let i = 1; i <= peakIndex; i++) {
    if (samples[i]!.elevationMilliDeg <= samples[i - 1]!.elevationMilliDeg) {
      throw new Error(`elevation does not rise monotonically to its peak (sample ${i})`);
    }
  }
  for (let i = peakIndex + 1; i < samples.length; i++) {
    if (samples[i]!.elevationMilliDeg >= samples[i - 1]!.elevationMilliDeg) {
      throw new Error(`elevation does not fall monotonically after its peak (sample ${i})`);
    }
  }

  const first = samples[0]!;
  const last = samples[samples.length - 1]!;
  return {
    sampleCount: samples.length,
    durationSec: last.timestamp - first.timestamp,
    peakElevationMilliDeg: samples[peakIndex]!.elevationMilliDeg,
    peakIndex,
    minDopplerHz: last.dopplerHz,
    maxDopplerHz: first.dopplerHz,
    crossesZeroDoppler: first.dopplerHz > 0 && last.dopplerHz < 0,
  };
}

export type PassTrackInput = {
  /** Captures from one station, across one pass. */
  captures: unknown[];
  station: Station;
  catalog: Tle[];
  domain: Eip712Domain;
  operator: `0x${string}`;
  boresightToleranceDeg?: number;
};

export type PassTrackOutput = {
  noradId: number;
  reports: PipelineOutput[];
  shape: PassShape;
};

/**
 * Resolve every capture in a pass and then check the track they form.
 *
 * Each capture still has to match the boresight on its own; what this adds is
 * that the sequence has to be a pass, not a bag of individually plausible
 * instants.
 */
export function runPassTrack(input: PassTrackInput): PassTrackOutput {
  if (input.captures.length < 3) {
    throw new Error(`a pass needs at least three captures, got ${input.captures.length}`);
  }

  const reports = input.captures.map((capture) =>
    runPipeline({
      capture,
      catalog: input.catalog,
      station: input.station,
      domain: input.domain,
      operator: input.operator,
      boresightToleranceDeg: input.boresightToleranceDeg,
    }),
  );

  const noradId = reports[0]!.attestation.noradId;
  for (const r of reports) {
    if (r.attestation.noradId !== noradId) {
      throw new Error(
        `a track must follow one satellite: ${noradId} then ${r.attestation.noradId}`,
      );
    }
  }

  const shape = checkPassShape(
    reports.map((r) => ({
      timestamp: r.attestation.timestamp,
      elevationMilliDeg: r.attestation.elevationMilliDeg,
      dopplerHz: r.attestation.dopplerHz,
    })),
  );

  return { noradId, reports, shape };
}
