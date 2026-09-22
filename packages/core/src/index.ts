export { keccak256, keccak256Hex, utf8, bytesToHex, hexToBytes } from "./crypto/keccak.ts";
export {
  hashTypedData,
  hashStruct,
  hashDomain,
  ATTESTATION_TYPEHASH,
  ATTESTATION_TYPE_STRING,
  DOMAIN_TYPEHASH,
} from "./crypto/eip712.ts";
export type { SkyRelayAttestation, Eip712Domain } from "./crypto/eip712.ts";

export { parseTle, parse3le, catalogHash } from "./orbit/tle.ts";
export type { Tle } from "./orbit/tle.ts";
export { initSgp4, propagate, propagateTle } from "./orbit/sgp4.ts";
export type { Sgp4Result, Sgp4State, Vec3 } from "./orbit/sgp4.ts";
export {
  geodeticToEcef,
  gstime,
  lookAngles,
  temeToEcef,
  temeVelocityToEcef,
} from "./orbit/coords.ts";
export type { LookAngles } from "./orbit/coords.ts";
export {
  observe,
  matchBoresight,
  angularSeparationDeg,
  DEFAULT_BORESIGHT_TOLERANCE_DEG,
  VALENTIA_01,
} from "./orbit/pass.ts";
export type { Station, Overhead, BoresightSighting } from "./orbit/pass.ts";
export { dopplerHz } from "./orbit/doppler.ts";
export {
  TRIANGULATION_MAX_FDOA_RESIDUAL_HZ,
  SINGLE_STATION_TOLERANCE_HZ,
  BASELINE_STATIONS,
  TriangulationError,
  stationBaselineDistanceKm,
  stationLineOfSight,
  computeBaselinePair,
  runTriangulationQuorum,
} from "./orbit/triangulation.ts";
export type {
  TriangulationObservation,
  BaselinePair,
  TriangulationReport,
} from "./orbit/triangulation.ts";

export { parseCapture } from "./telemetry/parse.ts";
export type { SkyCapture, DishStatus, DishDiagnostics, Egress } from "./telemetry/parse.ts";
export { extractFeatures, secondsToHandover } from "./telemetry/features.ts";
export type { PhysicalFeatures } from "./telemetry/features.ts";
export { classifyAsn, assertStarlinkAsn } from "./telemetry/asn.ts";
export { stripPrivateFields } from "./telemetry/privacy.ts";

export { runPipeline } from "./pipeline.ts";
export type { PipelineInput, PipelineOutput } from "./pipeline.ts";
export { runQuorum } from "./quorum.ts";
export { checkPassShape, runPassTrack } from "./track.ts";
export type { PassSample, PassShape, PassTrackInput, PassTrackOutput } from "./track.ts";
export type { QuorumInput, QuorumMember, QuorumOutput } from "./quorum.ts";

export {
  derivePhysicalSecret,
  abiEncodeCommitment,
  computeEntropyCommitment,
  verifyEntropyCommitment,
  accumulateEntropySeeds,
  abiEncodeFinalize,
  computeFinalizedSeed,
  calculateRound,
  calculateTargetCommitRound,
} from "./entropy/extractor.ts";
export type { PhysicalEntropyInputs } from "./entropy/extractor.ts";

export {
  kinematicTimeDilation,
  gravitationalTimeDilation,
  netRelativisticDilation,
  tcaDopplerRateHzS,
  createRelativisticTimeAnchor,
} from "./orbit/relativity.ts";
export type { RelativisticTimeAnchor } from "./orbit/relativity.ts";

export {
  computeEquivocationPairKey,
  evaluateEquivocation,
  formatSlashEquivocationCall,
} from "./crypto/slashing.ts";
export type { EquivocationProof } from "./crypto/slashing.ts";

export { AutonomousAIGateway } from "./ai/gateway.ts";
export type { AISpaceQuery, AISpaceState } from "./ai/gateway.ts";
export { AntiMevSwapEngine } from "./dex/fair-swap.ts";
export type {
  ProtectedSwapOrder,
  SwapExecutionResult,
  PoolState,
  BatchExecutionSummary,
} from "./dex/fair-swap.ts";
export {
  ALLOWED_ASN,
  STARLINK_ASN,
  KU_DOWNLINK_HZ,
  HANDOVER_UTC_OFFSETS,
  ATTESTATION_TTL_SEC,
  WGS72,
  WGS72_FLATTENING,
  EARTH_ROTATION_RAD_S,
} from "./orbit/constants.ts";
