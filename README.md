# SkyRelay

**Starlink user-terminal telemetry → physical features → EIP-712 → BNB Smart Chain.**

[skyrelay.link](https://skyrelay.link) · [github.com/SkyRelay/protocol](https://github.com/SkyRelay/protocol)

An open-source **feasibility proof**: in-repo SGP4 (WGS-72), Ku-band Doppler, AS14593/AS45700 filtering, Ethereum Keccak-256, and a Solidity verifier. No dish required. No Postgres, no Docker, no cloud.

[![Site](https://img.shields.io/badge/skyrelay.link-0b1220.svg)](https://skyrelay.link)
[![License: MIT](https://img.shields.io/badge/License-MIT-a3e635.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-pnpm%20verify-22d3ee.svg)](#quickstart)
[![BSC](https://img.shields.io/badge/BSC-Mainnet%20%2F%20Chapel-f0b90b.svg)](https://www.bnbchain.org)
[![Starlink UT](https://img.shields.io/badge/Starlink-UT%20gRPC%20%3A9200-7c3aed.svg)](https://github.com/SpaceExplorationTechnologies/enterprise-api)

```
  ┌──────────────────────┐     ┌──────────────────────────┐
  │ 1  UT gRPC JSON      │     │ 2  Physical filter       │
  │  192.168.100.1:9200  │────▶│  SNR · handover · ASN    │
  │  get_status/diag     │     │  allow {14593, 45700}    │
  └──────────────────────┘     └────────────┬─────────────┘
                                            │
  ┌──────────────────────┐     ┌────────────▼─────────────┐
  │ 4  SkyRelayBeacon    │     │ 3  SGP4 boresight match  │
  │  ecrecover · TTL 120s│◀────│  which satellite is the  │
  │  operator · replay   │     │  dish actually pointing  │
  │  vault               │     │  at?  ε · f_d · NORAD    │
  └──────────────────────┘     └──────────────────────────┘
```

## Quickstart

Requires Node 20+ and [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
pnpm install && pnpm verify
```

That command:

1. Locks SGP4 position **and velocity** against the published Vallado verification output
2. Parses every JSON under `vectors/frames/`
3. Rejects the AS15169 fixture (ASN gate) and the swung-boresight fixture (geometry gate)
4. Resolves each remaining frame against the **whole** CelesTrak catalog in `vectors/tle/` and checks it found the satellite the frame claims
5. Prints the EIP-712 digest
6. Runs the unit tests, then `forge test` — including a cross-implementation check that solc reproduces every TypeScript digest

Other entry points:

```bash
pnpm typecheck        # tsc, zero errors
pnpm test             # node:test unit suite
pnpm run vectors      # regenerate vectors/frames + vectors/eip712/attestations.json
cd contracts && forge test
```

## Physics (short)

SGP4, WGS-72, near-Earth only (\(P<225\) min). Station coordinates are placed on the **WGS-72 ellipsoid**, not a sphere, because the local vertical tilts by up to \(f\sin 2\varphi \approx 0.19^\circ\) — a hundred times the milli-degree resolution the attestation stores.

Look angles come from TEME→ECEF via GMST. The velocity transform subtracts the transport term,

\[
\mathbf{v}_\mathrm{ECEF} = R(\theta)\,\mathbf{v}_\mathrm{TEME} - \boldsymbol\omega \times \mathbf{r}_\mathrm{ECEF},
\]

without which every range-rate — and therefore every Doppler shift — is wrong. Doppler at Ku centre \(f_c=11.7\,\mathrm{GHz}\):

\[
f_d = -\frac{\dot\rho}{c}\,f_c
\]

which puts a real overhead pass at \(|f_d| \lesssim 270\,\mathrm{kHz}\); the fixtures land between 145 and 227 kHz. Starlink beam reassignment is globally aligned to UTC seconds **12 / 27 / 42 / 57**. Full derivation: [`docs/orbital-proof.md`](docs/orbital-proof.md). Protocol: [`docs/protocol.md`](docs/protocol.md).

## Layout

```
packages/core/src/orbit/       SGP4, TLE, look angles, Doppler, boresight match
packages/core/src/telemetry/   gRPC JSON, privacy strip, ASN filter
packages/core/src/crypto/      Keccak-256 + ABI + EIP-712
contracts/src/SkyRelayBeacon.sol
scripts/build-vectors.ts       regenerates the fixtures and the digest vectors
vectors/                       dish frames + TLEs (no hardware)
scripts/verify-pipeline.ts     pnpm verify
```

Zero runtime npm dependencies in `@skyrelay/core`. `tsx` / `typescript` are install-time only.

## What this proves / does not prove

**Proves:** deterministic encoding from a Dishy-shaped JSON plus public TLEs into a digest `ecrecover` accepts, with ASN, TTL, replay, operator, and horizon checks — and that two independent implementations of Keccak-256 and EIP-712 (TypeScript here, solc in `contracts/`) agree byte for byte on every committed vector.

**The one geometric binding:** a capture is only attested if some satellite in the public catalog was actually where the terminal says it was pointing, at the second the attestation commits to. Fabricating a frame therefore means finding a station, an instant, and a real element set that agree — not just editing a number. `vectors/frames/bad-geometry-006.json` is the fixture that fails this gate (16.7° off, tolerance 2°).

**Does not prove:** that a given JSON was signed by SpaceX silicon; that the operator was physically at the station it declares; that BSC validators live in orbit; affiliation with SpaceX/Starlink.

## Known limits

- **One attester.** `attester` is a single immutable EOA. Every on-chain check runs on data that key signed, so the checks defend against a *buggy* attester, never a lying one. A quorum of independent stations — where several receivers must agree on the Doppler of the same satellite — is the obvious next step and is not implemented here.
- **The attestation is a location fingerprint.** Stripping GPS from the capture does not hide much: `(noradId, elevation, doppler, timestamp)` against a public TLE constrains the observer to a narrow region, and a few beacons pin it.
- **`dishGetStatus.snr` is deprecated.** Recent terminal firmware stopped populating it, so `extractFeatures` will reject captures from a current dish until the feature set moves to a field that is still served. The fixtures use the documented field.
- **`usedDigest` grows without bound** — one permanent storage slot per beacon, load-bearing only for the 120 s TTL.

Independent protocol. Not affiliated with SpaceX.

## License

MIT. SGP4 follows the published Vallado/CelesTrak algorithm (AIAA 2006-6753). TLEs in `vectors/tle/starlink-*.txt` are from the public CelesTrak GP catalog.
