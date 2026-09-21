import { assertStarlinkAsn } from "./telemetry/asn.ts";
import { extractFeatures, type PhysicalFeatures } from "./telemetry/features.ts";
import { parseCapture, type SkyCapture } from "./telemetry/parse.ts";
import { stripPrivateFields } from "./telemetry/privacy.ts";
import {
  hashTypedData,
  type Eip712Domain,
  type SkyRelayAttestation,
} from "./crypto/eip712.ts";
import {
  matchBoresight,
  type BoresightSighting,
  type Station,
} from "./orbit/pass.ts";
import type { Tle } from "./orbit/tle.ts";

export type PipelineInput = {
  capture: unknown;
  /** Public element sets the sighting is resolved against. */
  catalog: Tle[];
  /** Operator-declared station. Never taken from the capture: GPS is stripped. */
  station: Station;
  domain: Eip712Domain;
  /** Address that will submit the beacon; committed to by the digest. */
  operator: `0x${string}`;
  boresightToleranceDeg?: number;
};

export type PipelineOutput = {
  capture: SkyCapture;
  features: PhysicalFeatures;
  sighting: BoresightSighting;
  attestation: SkyRelayAttestation;
  digest: `0x${string}`;
};

/**
 * Four-step feasibility pipeline:
 *   1. parse Starlink UT gRPC JSON, strip GPS and the raw terminal id
 *   2. reduce to integer physical features, enforce the Starlink ASN allow-set
 *   3. resolve the reported boresight against the public catalog with SGP4
 *   4. EIP-712 digest, byte-identical to SkyRelayBeacon.hashAttestation
 *
 * Every step throws rather than degrading: there is no path where a capture
 * that fails the geometry is attested using numbers the terminal reported
 * about itself.
 */
export function runPipeline(input: PipelineInput): PipelineOutput {
  const capture = stripPrivateFields(parseCapture(input.capture));
  const features = extractFeatures(capture);
  assertStarlinkAsn(features.asn);

  const sighting = matchBoresight(
    input.catalog,
    input.station,
    new Date(features.timestampSec * 1000),
    {
      azimuthDeg: features.boresightAzimuthMilliDeg / 1000,
      elevationDeg: features.boresightElevationMilliDeg / 1000,
    },
    input.boresightToleranceDeg,
  );

  const attestation: SkyRelayAttestation = {
    operator: input.operator,
    telemetryHash: features.telemetryHash,
    noradId: sighting.noradId,
    elevationMilliDeg: Math.round(sighting.elevationDeg * 1000),
    dopplerHz: Math.round(sighting.dopplerHz),
    snrMilliDb: features.snrMilliDb,
    asn: features.asn,
    timestamp: features.timestampSec,
  };
  return { capture, features, sighting, attestation, digest: hashTypedData(attestation, input.domain) };
}
