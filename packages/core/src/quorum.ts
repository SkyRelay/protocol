import { runPipeline, type PipelineOutput } from "./pipeline.ts";
import type { Eip712Domain } from "./crypto/eip712.ts";
import type { Station } from "./orbit/pass.ts";
import type { Tle } from "./orbit/tle.ts";
import { epochToJulian, gstime, julianDate, temeToEcef, temeVelocityToEcef } from "./orbit/coords.ts";
import { initSgp4, propagate } from "./orbit/sgp4.ts";
import {
  runTriangulationQuorum,
  TRIANGULATION_MAX_FDOA_RESIDUAL_HZ,
  type TriangulationObservation,
  type TriangulationReport,
} from "./orbit/triangulation.ts";

export type QuorumMember = {
  capture: unknown;
  /** Operator-declared station. Never read from the capture: GPS is stripped. */
  station: Station;
  /** Address that will submit on this station's behalf. */
  operator: `0x${string}`;
};

export type QuorumInput = {
  members: QuorumMember[];
  catalog: Tle[];
  domain: Eip712Domain;
  boresightToleranceDeg?: number;
  /** Optional differential Doppler residual tolerance in Hz (default: 3.0 Hz). Set 0 to disable triangulation. */
  triangulationToleranceHz?: number;
};

export type QuorumOutput = {
  /** The satellite every member resolved to. */
  noradId: number;
  /** The second every member committed to. */
  timestamp: number;
  /** The element set every member was resolved against. */
  catalogHash: `0x${string}`;
  reports: PipelineOutput[];
  /** Worst per-station pointing residual in the set. */
  worstBoresightResidualDeg: number;
  /** Multi-station long-baseline triangulation and differential Doppler geometric report. */
  triangulation?: TriangulationReport;
};

/**
 * Resolve several stations' captures of the same sighting.
 *
 * Each member goes through the ordinary pipeline, so each one's reported
 * boresight has to match the same satellite, propagated from the same element
 * set, at the same second. On top of that the members must agree on *what they
 * saw*: same NORAD id, same timestamp, same catalog, distinct stations,
 * distinct operators. `SkyRelayBeacon.verifyAndRecord` enforces the agreement
 * half of that on chain; the geometry half necessarily stays here, because the
 * contract does not propagate orbits.
 *
 * What this is worth, precisely: the check is the conjunction of independent
 * per-station checks against one shared orbit, so it is not a stronger
 * *mathematical* statement than a single station makes. Its value is
 * operational — the k signatures have to come from k separate keys, so a
 * quorum costs an attacker k compromises instead of one, and a dishonest
 * minority cannot get data past the stations that contradict it. It does not
 * stop a single party who holds every key and is willing to run SGP4.
 */
export function runQuorum(input: QuorumInput): QuorumOutput {
  const { members } = input;
  if (members.length < 2) {
    throw new Error("a quorum needs at least two stations; use runPipeline for one");
  }

  const reports = members.map((m) =>
    runPipeline({
      capture: m.capture,
      catalog: input.catalog,
      station: m.station,
      domain: input.domain,
      operator: m.operator,
      boresightToleranceDeg: input.boresightToleranceDeg,
    }),
  );

  const first = reports[0]!;
  for (let i = 1; i < reports.length; i++) {
    const r = reports[i]!;
    if (r.attestation.noradId !== first.attestation.noradId) {
      throw new Error(
        `quorum disagrees on the satellite: ${first.attestation.noradId} vs ${r.attestation.noradId}`,
      );
    }
    if (r.attestation.timestamp !== first.attestation.timestamp) {
      throw new Error(
        `quorum disagrees on the second: ${first.attestation.timestamp} vs ${r.attestation.timestamp}`,
      );
    }
    if (r.catalogHash !== first.catalogHash) {
      throw new Error("quorum disagrees on the element set");
    }
  }

  const stationIds = new Set<string>();
  const operators = new Set<string>();
  for (const m of members) {
    if (stationIds.has(m.station.id)) throw new Error(`station ${m.station.id} appears twice`);
    stationIds.add(m.station.id);
    const operator = m.operator.toLowerCase();
    if (operators.has(operator)) throw new Error(`operator ${m.operator} appears twice`);
    operators.add(operator);
  }

  let triangulation: TriangulationReport | undefined;
  if (input.triangulationToleranceHz !== 0) {
    const tle = input.catalog.find((t) => t.noradId === first.attestation.noradId);
    if (tle) {
      const epoch = epochToJulian(tle.epochYear, tle.epochDay);
      const when = new Date(first.attestation.timestamp * 1000);
      const jdNow = julianDate(
        when.getUTCFullYear(),
        when.getUTCMonth() + 1,
        when.getUTCDate(),
        when.getUTCHours(),
        when.getUTCMinutes(),
        when.getUTCSeconds() + when.getUTCMilliseconds() / 1000,
      );
      const tsinceMin = (jdNow - (epoch.jd + epoch.fr)) * 1440;
      const rv = propagate(initSgp4(tle), tsinceMin);
      const gmst = gstime(jdNow);
      const satEcefKm = temeToEcef(rv.positionKm, gmst);
      const satVelEcefKmS = temeVelocityToEcef(rv.velocityKmS, satEcefKm, gmst);

      const observations: TriangulationObservation[] = members.map((m, idx) => ({
        station: m.station,
        observedDopplerHz: reports[idx]!.attestation.dopplerHz,
        azimuthDeg: reports[idx]!.sighting.azimuthDeg,
        elevationDeg: reports[idx]!.sighting.elevationDeg,
      }));

      const maxTol = input.triangulationToleranceHz ?? TRIANGULATION_MAX_FDOA_RESIDUAL_HZ;
      triangulation = runTriangulationQuorum({
        noradId: first.attestation.noradId,
        timestamp: first.attestation.timestamp,
        satEcefKm,
        satVelEcefKmS,
        observations,
        maxToleranceHz: maxTol,
      });
    }
  }

  return {
    noradId: first.attestation.noradId,
    timestamp: first.attestation.timestamp,
    catalogHash: first.catalogHash,
    reports,
    worstBoresightResidualDeg: Math.max(...reports.map((r) => r.sighting.boresightResidualDeg)),
    triangulation,
  };
}
