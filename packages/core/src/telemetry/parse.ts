/**
 * Parser for SpaceX Local Device API JSON (grpcurl / official device.proto).
 * Accepts camelCase (proto3 JSON) and a thin SkyRelay capture envelope.
 */

export type DishStatus = {
  snr?: number;
  snrDb?: number;
  downlinkThroughputBps?: number;
  uplinkThroughputBps?: number;
  popPingLatencyMs?: number;
  popPingDropRate?: number;
  boresightAzimuthDeg?: number;
  boresightElevationDeg?: number;
  obstructionStats?: { fractionObstructed?: number };
  deviceState?: { uptimeS?: number };
  deviceInfo?: { id?: string; hardwareVersion?: string; softwareVersion?: string };
  state?: string | number;
};

export type DishDiagnostics = {
  id?: string;
  hardwareVersion?: string;
  softwareVersion?: string;
  disablementCode?: string | number;
  utcOffsetS?: number;
  location?: { latitude?: number; longitude?: number; altitudeMeters?: number };
};

export type Egress = {
  asn: number;
  asOrg?: string;
  prefix?: string;
};

export type SkyCapture = {
  capturedAt: string;
  source: string;
  dishGetStatus: DishStatus;
  dishGetDiagnostics?: DishDiagnostics;
  egress: Egress;
};

function asRecord(v: unknown): Record<string, unknown> {
  if (!v || typeof v !== "object") throw new Error("expected object");
  return v as Record<string, unknown>;
}

function num(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v !== "" && Number.isFinite(Number(v))) return Number(v);
  return undefined;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

function pickStatus(raw: Record<string, unknown>): DishStatus {
  const inner =
    (raw.dishGetStatus as Record<string, unknown> | undefined) ??
    (raw.dish_get_status as Record<string, unknown> | undefined) ??
    raw;
  const info = asRecord(inner.deviceInfo ?? inner.device_info ?? {});
  const st = asRecord(inner.deviceState ?? inner.device_state ?? {});
  const obst = asRecord(inner.obstructionStats ?? inner.obstruction_stats ?? {});
  return {
    snr: num(inner.snr ?? inner.snrDb ?? inner.snr_db),
    snrDb: num(inner.snrDb ?? inner.snr_db ?? inner.snr),
    downlinkThroughputBps: num(inner.downlinkThroughputBps ?? inner.downlink_throughput_bps),
    uplinkThroughputBps: num(inner.uplinkThroughputBps ?? inner.uplink_throughput_bps),
    popPingLatencyMs: num(inner.popPingLatencyMs ?? inner.pop_ping_latency_ms),
    popPingDropRate: num(inner.popPingDropRate ?? inner.pop_ping_drop_rate),
    boresightAzimuthDeg: num(inner.boresightAzimuthDeg ?? inner.boresight_azimuth_deg),
    boresightElevationDeg: num(inner.boresightElevationDeg ?? inner.boresight_elevation_deg),
    obstructionStats: { fractionObstructed: num(obst.fractionObstructed ?? obst.fraction_obstructed) },
    deviceState: { uptimeS: num(st.uptimeS ?? st.uptime_s) },
    deviceInfo: {
      id: str(info.id),
      hardwareVersion: str(info.hardwareVersion ?? info.hardware_version),
      softwareVersion: str(info.softwareVersion ?? info.software_version),
    },
    state: (inner.state as string | number | undefined) ?? undefined,
  };
}

function pickDiagnostics(raw: Record<string, unknown>): DishDiagnostics | undefined {
  const inner = (raw.dishGetDiagnostics ?? raw.dish_get_diagnostics) as Record<string, unknown> | undefined;
  if (!inner) return undefined;
  const loc = asRecord(inner.location ?? {});
  return {
    id: str(inner.id),
    hardwareVersion: str(inner.hardwareVersion ?? inner.hardware_version),
    softwareVersion: str(inner.softwareVersion ?? inner.software_version),
    disablementCode: (inner.disablementCode ?? inner.disablement_code) as string | number | undefined,
    utcOffsetS: num(inner.utcOffsetS ?? inner.utc_offset_s),
    location: {
      latitude: num(loc.latitude),
      longitude: num(loc.longitude),
      altitudeMeters: num(loc.altitudeMeters ?? loc.altitude_meters),
    },
  };
}

export function parseCapture(input: unknown): SkyCapture {
  const raw = asRecord(input);
  const capturedAt = str(raw.capturedAt ?? raw.captured_at);
  if (!capturedAt) throw new Error("capture missing capturedAt");
  const egressRaw = asRecord(raw.egress ?? {});
  const asn = num(egressRaw.asn);
  if (asn === undefined) throw new Error("capture missing egress.asn");
  return {
    capturedAt,
    source: str(raw.source) ?? "unknown",
    dishGetStatus: pickStatus(raw),
    dishGetDiagnostics: pickDiagnostics(raw),
    egress: {
      asn,
      asOrg: str(egressRaw.asOrg ?? egressRaw.as_org),
      prefix: str(egressRaw.prefix),
    },
  };
}
