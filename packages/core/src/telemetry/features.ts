import { HANDOVER_UTC_OFFSETS } from "../orbit/constants.ts";
import { keccak256Hex, utf8 } from "../crypto/keccak.ts";
import { classifyAsn } from "./asn.ts";
import type { SkyCapture } from "./parse.ts";

export type PhysicalFeatures = {
  capturedAt: string;
  timestampSec: number;
  snrMilliDb: number;
  downlinkBps: number;
  uplinkBps: number;
  latencyMs: number;
  dropRate: number;
  boresightAzimuthMilliDeg: number;
  boresightElevationMilliDeg: number;
  obstructionFractionMilli: number;
  uptimeS: number;
  hardwareVersion: string;
  asn: number;
  asnAllowed: boolean;
  handoverSlot: number;
  secondsToHandover: number;
  telemetryHash: `0x${string}`;
};

function milli(n: number): number {
  return Math.round(n * 1000);
}

export function secondsToHandover(date: Date): { slot: number; secondsLeft: number } {
  const s = date.getUTCSeconds() + date.getUTCMilliseconds() / 1000;
  for (const slot of HANDOVER_UTC_OFFSETS) {
    if (s < slot - 1e-9) return { slot, secondsLeft: slot - s };
  }
  return { slot: HANDOVER_UTC_OFFSETS[0]!, secondsLeft: 60 + HANDOVER_UTC_OFFSETS[0]! - s };
}

/**
 * Reduce a capture to the integer fields that enter the attestation.
 * SNR is stored as millidB so the chain never sees floats.
 */
export function extractFeatures(capture: SkyCapture): PhysicalFeatures {
  const st = capture.dishGetStatus;
  const snr = st.snrDb ?? st.snr;
  if (snr === undefined) throw new Error("status missing SNR");
  const when = new Date(capture.capturedAt);
  if (Number.isNaN(when.getTime())) throw new Error(`bad capturedAt ${capture.capturedAt}`);
  const asnV = classifyAsn(capture.egress.asn);
  const ho = secondsToHandover(when);

  const timestampSec = Math.floor(when.getTime() / 1000);
  const snrMilliDb = milli(snr);
  const downlinkBps = Math.round(st.downlinkThroughputBps ?? 0);
  const boresightAzimuthMilliDeg = milli(st.boresightAzimuthDeg ?? 0);
  const boresightElevationMilliDeg = milli(st.boresightElevationDeg ?? 0);

  const canonical = [
    timestampSec,
    snrMilliDb,
    downlinkBps,
    capture.egress.asn,
    boresightAzimuthMilliDeg,
    boresightElevationMilliDeg,
    ho.slot,
  ].join("|");

  return {
    capturedAt: capture.capturedAt,
    timestampSec,
    snrMilliDb,
    downlinkBps,
    uplinkBps: Math.round(st.uplinkThroughputBps ?? 0),
    latencyMs: st.popPingLatencyMs ?? 0,
    dropRate: st.popPingDropRate ?? 0,
    boresightAzimuthMilliDeg,
    boresightElevationMilliDeg,
    obstructionFractionMilli: milli(st.obstructionStats?.fractionObstructed ?? 0),
    uptimeS: st.deviceState?.uptimeS ?? 0,
    hardwareVersion: st.deviceInfo?.hardwareVersion ?? capture.dishGetDiagnostics?.hardwareVersion ?? "",
    asn: capture.egress.asn,
    asnAllowed: asnV.allowed,
    handoverSlot: ho.slot,
    secondsToHandover: ho.secondsLeft,
    telemetryHash: keccak256Hex(utf8(canonical)),
  };
}
