/**
 * Regenerate the synthetic capture fixtures under vectors/frames/.
 *
 * The dish payloads are schema-faithful reconstructions, not recordings: no
 * Starlink hardware is involved anywhere in this repository. What is real is
 * the geometry — every frame is placed on an actual pass of the public
 * CelesTrak element sets in vectors/tle/, so the boresight a frame reports is
 * the boresight a terminal at that station would have had at that instant.
 *
 * The two negative frames are perturbations of a positive one, so each gate
 * (ASN allow-set, boresight match) has a fixture that provably trips it.
 *
 *   pnpm run vectors
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parse3le } from "../packages/core/src/orbit/tle.ts";
import { observe, type Station } from "../packages/core/src/orbit/pass.ts";
import { runPipeline } from "../packages/core/src/pipeline.ts";
import { OPERATOR, readCatalog, readDomain } from "./shared.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

const GENESIS_01: Station = {
  id: "GENESIS-01",
  name: "南溟一号",
  latDeg: 18.23,
  lonDeg: 109.51,
  altKm: 0.05,
};

const MV_ANYUAN: Station = {
  id: "MV-ANYUAN",
  name: "MV Anyuan (maritime roam)",
  latDeg: 15.8,
  lonDeg: 113.2,
  altKm: 0.012,
};

type Scenario = {
  id: string;
  capturedAt: string;
  tle: string;
  station: Station;
  notes: string;
  /** Boresight reporting offset in degrees, so the residual is never exactly zero. */
  jitter: { az: number; el: number };
  status: Record<string, unknown>;
  diagnostics?: Record<string, unknown>;
  egress: { asn: number; asOrg: string; prefix: string };
  /** Applied after the geometry is computed, to build negative fixtures. */
  corrupt?: (frame: Record<string, any>) => void;
  /** Negative fixtures are written but produce no attestation vector. */
  negative?: boolean;
};

const UT = {
  id: "ut01000000-00000000-00e1c9f7",
  hardwareVersion: "rev4_panda_prod1",
  softwareVersion: "2026.07.06.mr81950",
};

const scenarios: Scenario[] = [
  {
    id: "connected-001",
    capturedAt: "2026-09-20T15:30:03.210Z",
    tle: "starlink-1008",
    station: GENESIS_01,
    notes:
      "Nominal connected terminal, mid-pass on STARLINK-1008. GPS is present in diagnostics so the privacy stripper has something to remove.",
    jitter: { az: 0.08, el: -0.06 },
    status: {
      deviceInfo: UT,
      deviceState: { uptimeS: 26115 },
      state: "Connected",
      snr: 8.7,
      downlinkThroughputBps: 186400000,
      uplinkThroughputBps: 18400000,
      popPingLatencyMs: 38.857143,
      popPingDropRate: 0.002,
      obstructionStats: { fractionObstructed: 0.0064355433 },
    },
    diagnostics: {
      ...UT,
      utcOffsetS: 28800,
      disablementCode: "OKAY",
      location: { latitude: 18.2301, longitude: 109.5102, altitudeMeters: 47.2 },
    },
    egress: { asn: 14593, asOrg: "SPACEX-STARLINK", prefix: "98.97.12.0/24" },
  },
  {
    id: "handover-002",
    capturedAt: "2026-09-20T15:30:12.040Z",
    tle: "starlink-1008",
    station: GENESIS_01,
    notes:
      "Same terminal 8.83 s later, captured 40 ms after the globally aligned :12 beam reassignment. SNR and throughput step as the terminal retargets.",
    jitter: { az: -0.11, el: 0.05 },
    status: {
      deviceInfo: UT,
      deviceState: { uptimeS: 26124 },
      state: "Connected",
      snr: 7.4,
      downlinkThroughputBps: 95800000,
      uplinkThroughputBps: 9200000,
      popPingLatencyMs: 52.1,
      popPingDropRate: 0.041,
      obstructionStats: { fractionObstructed: 0.0065 },
    },
    diagnostics: { ...UT, disablementCode: "OKAY" },
    egress: { asn: 14593, asOrg: "SPACEX-STARLINK", prefix: "98.97.12.0/24" },
  },
  {
    id: "obstructed-003",
    capturedAt: "2026-09-20T14:06:27.880Z",
    tle: "starlink-1526",
    station: GENESIS_01,
    notes:
      "Low elevation on STARLINK-1526 with a partially obstructed sky: SNR 3.1 dB, larger pointing residual, throughput collapsed.",
    jitter: { az: 0.14, el: -0.12 },
    status: {
      deviceInfo: UT,
      deviceState: { uptimeS: 26680 },
      state: "Connected",
      snr: 3.1,
      downlinkThroughputBps: 12300000,
      uplinkThroughputBps: 1900000,
      popPingLatencyMs: 91.4,
      popPingDropRate: 0.178,
      obstructionStats: { fractionObstructed: 0.0913 },
    },
    diagnostics: { ...UT, disablementCode: "OKAY" },
    egress: { asn: 14593, asOrg: "SPACEX-STARLINK", prefix: "98.97.12.0/24" },
  },
  {
    id: "roam-004",
    capturedAt: "2026-09-20T18:53:42.500Z",
    tle: "starlink-2034",
    station: MV_ANYUAN,
    notes:
      "Maritime roam on AS45700 from a vessel in the South China Sea, tracking STARLINK-2034. Larger pointing residual from deck motion.",
    jitter: { az: -0.09, el: 0.07 },
    status: {
      deviceInfo: { ...UT, hardwareVersion: "rev3_proto2" },
      deviceState: { uptimeS: 401233 },
      state: "Connected",
      snr: 9.2,
      downlinkThroughputBps: 142700000,
      uplinkThroughputBps: 14100000,
      popPingLatencyMs: 44.2,
      popPingDropRate: 0.007,
      obstructionStats: { fractionObstructed: 0.0011 },
    },
    diagnostics: { ...UT, hardwareVersion: "rev3_proto2", disablementCode: "OKAY" },
    egress: { asn: 45700, asOrg: "IDNIC-STARLINK-AS-ID", prefix: "103.152.0.0/22" },
  },
  {
    id: "bad-asn-005",
    negative: true,
    capturedAt: "2026-09-20T15:30:03.210Z",
    tle: "starlink-1008",
    station: GENESIS_01,
    notes:
      "Negative: geometry is valid but the egress is terrestrial broadband (AS15169). The ASN allow-set must reject it.",
    jitter: { az: 0.08, el: -0.06 },
    status: {
      deviceInfo: UT,
      deviceState: { uptimeS: 26115 },
      state: "Connected",
      snr: 8.7,
      downlinkThroughputBps: 186400000,
      uplinkThroughputBps: 18400000,
      popPingLatencyMs: 38.857143,
      popPingDropRate: 0.002,
      obstructionStats: { fractionObstructed: 0.0064355433 },
    },
    egress: { asn: 15169, asOrg: "GOOGLE", prefix: "8.8.8.0/24" },
  },
  {
    id: "bad-geometry-006",
    negative: true,
    capturedAt: "2026-09-20T15:30:03.210Z",
    tle: "starlink-1008",
    station: GENESIS_01,
    notes:
      "Negative: Starlink ASN and a plausible-looking dish payload, but the boresight is swung 25 deg away from any satellite in the catalog. The SGP4 match must reject it.",
    jitter: { az: 0.08, el: -0.06 },
    status: {
      deviceInfo: UT,
      deviceState: { uptimeS: 26115 },
      state: "Connected",
      snr: 8.7,
      downlinkThroughputBps: 186400000,
      uplinkThroughputBps: 18400000,
      popPingLatencyMs: 38.857143,
      popPingDropRate: 0.002,
      obstructionStats: { fractionObstructed: 0.0064355433 },
    },
    egress: { asn: 14593, asOrg: "SPACEX-STARLINK", prefix: "98.97.12.0/24" },
    corrupt: (frame) => {
      frame.dishGetStatus.boresightAzimuthDeg = round3(frame.dishGetStatus.boresightAzimuthDeg + 25);
    },
  },
];

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

const positives: { id: string; frame: Record<string, any>; station: Station }[] = [];

for (const s of scenarios) {
  const tle = parse3le(readFileSync(join(root, "vectors/tle", `${s.tle}.txt`), "utf8"));
  const look = observe(tle, s.station, new Date(s.capturedAt));
  if (look.elevationDeg <= 0) {
    throw new Error(`${s.id}: ${tle.name} is ${look.elevationDeg.toFixed(2)} deg below the horizon`);
  }
  const frame: Record<string, any> = {
    id: s.id,
    capturedAt: s.capturedAt,
    source: "lan-grpc://192.168.100.1:9200",
    method: "SpaceX.API.Device.Device/Handle",
    notes: s.notes,
    station: {
      id: s.station.id,
      latDeg: s.station.latDeg,
      lonDeg: s.station.lonDeg,
      altKm: s.station.altKm,
    },
    expectNoradId: tle.noradId,
    dishGetStatus: {
      ...s.status,
      boresightAzimuthDeg: round3(look.azimuthDeg + s.jitter.az),
      boresightElevationDeg: round3(look.elevationDeg + s.jitter.el),
    },
    ...(s.diagnostics ? { dishGetDiagnostics: s.diagnostics } : {}),
    egress: s.egress,
  };
  s.corrupt?.(frame);
  writeFileSync(join(root, "vectors/frames", `${s.id}.json`), `${JSON.stringify(frame, null, 2)}\n`);
  console.log(
    `${s.id.padEnd(18)} ${tle.name.padEnd(14)} el=${look.elevationDeg.toFixed(3).padStart(7)} ` +
      `az=${look.azimuthDeg.toFixed(3).padStart(7)} fd=${look.dopplerHz.toFixed(0).padStart(8)} Hz ` +
      `range=${look.rangeKm.toFixed(1)} km`,
  );
  if (!s.negative) positives.push({ id: s.id, frame, station: s.station });
}

/**
 * Cross-implementation digest vectors. The same rows are asserted by
 * packages/core/test/eip712.test.ts (TypeScript keccak + ABI encoder) and by
 * contracts/test/Eip712Vectors.t.sol (solc keccak256 + abi.encode). A field
 * reordered on either side breaks both.
 */
const domain = readDomain(root);
const catalog = readCatalog(root);
const attestations = positives.map(({ id, frame, station }) => {
  const out = runPipeline({ capture: frame, catalog, station, domain, operator: OPERATOR });
  return { id, ...out.attestation, digest: out.digest };
});
writeFileSync(
  join(root, "vectors/eip712/attestations.json"),
  `${JSON.stringify({ domain, count: attestations.length, attestations }, null, 2)}\n`,
);
console.log(`\nvectors/eip712/attestations.json  ${attestations.length} digest vectors`);
