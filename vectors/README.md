# Test vectors

These fixtures let `pnpm verify` and `forge test` reproduce the full pipeline **without a Starlink dish**. Regenerate everything with `pnpm run vectors`.

| Path | What it is |
|------|------------|
| `tle/vanguard.txt` | Vallado AIAA 2006-6753 Vanguard-1 TLE (SGP4 numerical lock, position **and** velocity) |
| `tle/starlink-*.txt` | CelesTrak GP two-line elements, epoch **2026-263** (2026-09-20), fetched from `gp.php?GROUP=starlink`. All three form the catalog every frame is matched against. |
| `frames/connected-001.json` | Connected UT mid-pass on STARLINK-2034 over Valentia Island, SNR 8.7 dB, AS14593, GPS present (privacy-strip test) |
| `frames/handover-002.json` | Same UT 8.83 s later, 40 ms past the UTC `:12` beam switch |
| `frames/obstructed-003.json` | Low elevation on STARLINK-1526 from Pleumeur-Bodou, obstructed sky, SNR 3.1 dB |
| `frames/roam-004.json` | Maritime roam from a vessel in the North Atlantic, STARLINK-1008, **AS45700** (allowed) |
| `frames/quorum-goonhilly-007.json` | Second member of the quorum: Goonhilly Downs, 460 km from Valentia, same satellite and same second |
| `frames/quorum-pleumeur-009.json` | Third member: Pleumeur-Bodou in Brittany, 640 km out, on AS45700 |
| `frames/bad-asn-005.json` | Negative: valid geometry, terrestrial egress AS15169 — the ASN gate must reject it |
| `frames/bad-geometry-006.json` | Negative: Starlink ASN, boresight swung 25° off — the SGP4 match must reject it |
| `tracks/valentia-01-47352.json` | One whole STARLINK-2034 pass over VALENTIA-01, sampled every 60 s, for the pass-shape check |
| `eip712/domain.json` | Canonical EIP-712 domain |
| `eip712/attestations.json` | Generated. Attestation fields + the digest TypeScript computes for each positive frame, plus the three-station quorum grouping; `contracts/test/Eip712Vectors.t.sol` recomputes every digest with solc and re-checks that the quorum would satisfy the on-chain agreement rule |

## Provenance

- **TLE**: public CelesTrak general-perturbations catalog. Not SpaceX telemetry.
- **Dish JSON**: field names and ranges follow the official Local Device API (`device.proto`) and published community captures (e.g. starlink-rs `GetStatus` dumps). GPS/UTID values are synthetic so the stripper can be tested; they are **not** a live user terminal identifier.
- **Geometry is not synthetic.** Each frame sits on an actual pass of its element set over its station: `scripts/build-vectors.ts` propagates the TLE, writes the boresight the terminal would have reported at that instant plus a small fixed offset, and refuses to emit a frame whose satellite is below the horizon. The two negative frames are perturbations of a positive one, so each gate has a fixture that provably trips it.
- **ASN**: AS14593 / AS45700 are the documented Starlink customer autonomous systems.

## The quorum fixture

`connected-001`, `quorum-goonhilly-007` and `quorum-pleumeur-009` are the same instant — 2026-09-20T20:05:03.210Z — seen from three places:

| Station | Elevation | Doppler | ASN |
|---|---|---|---|
| VALENTIA-01 (Valentia Island, Ireland) | 47.24° | +173 690 Hz | 14593 |
| GOONHILLY-02 (Goonhilly Downs, Cornwall) | 30.35° | +220 040 Hz | 14593 |
| PLEUMEUR-03 (Pleumeur-Bodou, Brittany) | 25.21° | +215 966 Hz | 45700 |

They disagree on every measured number and agree on `noradId`, `timestamp` and `catalogHash`, which is exactly the shape `SkyRelayBeacon.verifyAndRecord` demands. `pnpm verify` fails if the three ever report identical geometry, because a quorum of identical reports is one measurement copied three times.

Do not treat these JSON files as a hardware root of trust. They prove the **parser, filter, SGP4 binding, catalog commitment and EIP-712 encoding** are deterministic — and, through `bad-geometry-006`, that the binding is load-bearing.
