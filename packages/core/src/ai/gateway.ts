import type { Station } from "../orbit/pass.ts";
import { observe } from "../orbit/pass.ts";
import type { Tle } from "../orbit/tle.ts";
import {
  createRelativisticTimeAnchor,
  type RelativisticTimeAnchor,
} from "../orbit/relativity.ts";
import {
  runTriangulationQuorum,
  type TriangulationObservation,
  type TriangulationReport,
} from "../orbit/triangulation.ts";
import {
  accumulateEntropySeeds,
  computeFinalizedSeed,
} from "../entropy/extractor.ts";
import type { Vec3 } from "../orbit/sgp4.ts";

export type AISpaceQuery = {
  noradId: number;
  timestampSec: number;
  station: Station;
};

export type AISpaceState = {
  noradId: number;
  satelliteName: string;
  timestampSec: number;
  stationId: string;
  azimuthDeg: number;
  elevationDeg: number;
  slantRangeKm: number;
  dopplerShiftHz: number;
  relativisticTimeAnchor: RelativisticTimeAnchor;
  isOverhead: boolean;
};

/**
 * Autonomous AI Space Invariant Gateway.
 *
 * Provides on-chain AI agents with verifiable physical telemetry,
 * relativistic orbital timestamps, and space entropy proofs.
 */
export class AutonomousAIGateway {
  public readonly catalog: Tle[];

  constructor(catalog: Tle[]) {
    if (catalog.length === 0) throw new Error("AIGateway requires non-empty TLE catalog");
    this.catalog = catalog;
  }

  /**
   * Query the physical space state of any LEO satellite for an autonomous agent.
   */
  public querySpaceState(query: AISpaceQuery): AISpaceState {
    const tle = this.catalog.find((t) => t.noradId === query.noradId);
    if (!tle) throw new Error(`NORAD ID ${query.noradId} not found in catalog`);

    const when = new Date(query.timestampSec * 1000);
    const overhead = observe(tle, query.station, when);

    const timeAnchor = createRelativisticTimeAnchor({
      noradId: overhead.noradId,
      timestampSec: query.timestampSec,
      elevationDeg: overhead.elevationDeg,
      rangeKm: overhead.rangeKm,
      rangeRateKmS: overhead.rangeRateKmS,
      dopplerHz: overhead.dopplerHz,
    });

    return {
      noradId: overhead.noradId,
      satelliteName: overhead.name,
      timestampSec: query.timestampSec,
      stationId: query.station.id,
      azimuthDeg: Number(overhead.azimuthDeg.toFixed(3)),
      elevationDeg: Number(overhead.elevationDeg.toFixed(3)),
      slantRangeKm: Number(overhead.rangeKm.toFixed(2)),
      dopplerShiftHz: Math.round(overhead.dopplerHz),
      relativisticTimeAnchor: timeAnchor,
      isOverhead: overhead.elevationDeg > 0,
    };
  }

  /**
   * Perform multi-station triangulation verification on behalf of an AI decision engine.
   */
  public verifyMultiStationGeometry(params: {
    noradId: number;
    timestampSec: number;
    satEcefKm: Vec3;
    satVelEcefKmS: Vec3;
    observations: TriangulationObservation[];
    maxToleranceHz?: number;
  }): TriangulationReport {
    return runTriangulationQuorum({
      noradId: params.noradId,
      timestamp: params.timestampSec,
      satEcefKm: params.satEcefKm,
      satVelEcefKmS: params.satVelEcefKmS,
      observations: params.observations,
      maxToleranceHz: params.maxToleranceHz,
    });
  }

  /**
   * Compute verified physical space entropy for on-chain AI randomness requirements.
   */
  public resolvePhysicalEntropy(params: {
    round: bigint;
    revealedSecrets: (`0x${string}` | bigint)[];
  }): {
    seed: `0x${string}`;
    accumulator: bigint;
    contributorCount: number;
  } {
    const accumulator = accumulateEntropySeeds(params.revealedSecrets);
    const seed = computeFinalizedSeed(accumulator, params.round, params.revealedSecrets.length);
    return {
      seed,
      accumulator,
      contributorCount: params.revealedSecrets.length,
    };
  }
}
