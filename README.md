# SkyRelay

**Starlink user-terminal telemetry → physical features → EIP-712 → BNB Smart Chain.**

[skyrelay.link](https://skyrelay.link) · [github.com/SkyRelay/protocol](https://github.com/SkyRelay/protocol)

An open-source **feasibility proof**: in-repo SGP4 (WGS-72), Ku-band Doppler, AS14593/AS45700 filtering, Ethereum Keccak-256, and a Solidity verifier. No dish required. No Postgres, no Docker, no cloud.

[![CI](https://github.com/SkyRelay/protocol/actions/workflows/ci.yml/badge.svg)](https://github.com/SkyRelay/protocol/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-a3e635.svg)](LICENSE)
[![BSC](https://img.shields.io/badge/BSC-Mainnet%20%2F%20Chapel-f0b90b.svg)](https://www.bnbchain.org)
[![Starlink UT](https://img.shields.io/badge/Starlink-UT%20gRPC%20%3A9200-7c3aed.svg)](https://github.com/SpaceExplorationTechnologies/enterprise-api)

## How Starlink and BNB Smart Chain relate

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/trust-dark.svg">
  <img alt="Three independent inputs — the Starlink terminal, the CelesTrak catalog and the ASN registry — feed an off-chain pipeline; one attester key signs the digest; the contract verifies it on BNB Smart Chain." src="docs/img/trust-light.svg">
</picture>

Read that diagram before anything else, because the interesting part is what is **missing** from it.

There is no wire between SpaceX and the chain. A Starlink terminal serves an unauthenticated JSON blob over gRPC on your own LAN; SpaceX neither signs it nor knows this protocol exists. Taken alone that blob proves nothing — anyone can type numbers into a file.

What makes a capture expensive to fabricate is the other two inputs, and neither belongs to SpaceX or to us:

- **The CelesTrak GP catalog** says where every Starlink satellite actually was. Anyone can fetch the same file and recompute the same geometry.
- **The public ASN registry** says which network an egress IP really sits on.

So a forged frame has to be simultaneously consistent with a real orbit, a real ground station, and a real instant in time. That is the whole of the physical binding, and it is genuinely non-trivial — but it is not hardware attestation, and the trust boundary in the diagram is real: everything on chain is one signing key's word.

## Quickstart

Requires Node 20+ and [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
pnpm install && pnpm verify
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/pipeline-dark.svg">
  <img alt="Four pipeline stages — ingest, features, geometry, digest — with the negative fixture that trips each gate, feeding the on-chain verifier." src="docs/img/pipeline-light.svg">
</picture>

Other entry points:

```bash
pnpm typecheck        # tsc, zero errors
pnpm test             # node:test unit suite
pnpm run vectors      # regenerate vectors/frames + vectors/eip712/attestations.json
cd contracts && forge test
```

## What that one command prints

Not a claim — the actual output, reproducible on your machine with no hardware:

```
SkyRelay feasibility pipeline
=============================

  ok   SGP4 Vanguard-1 TEME residual r=6.82e-9 km  v=6.38e-10 km/s
  eip712 typehash 0x3ef74e5ab3e68a910b640f4b2d211ddb61f06e52f18da48417abca1644024a79
  eip712 domain   0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f
  ok   catalog STARLINK-1008(44714) STARLINK-1526(46029) STARLINK-2034(47352)
  ok   bad-asn-005.json rejected: ASN 15169 is outside {14593, 45700}
  ok   bad-geometry-006.json rejected: boresight 261.03/48.30 deg is 16.68 deg from
       the nearest catalog satellite (NORAD 44714); tolerance is 2 deg
  ok   connected-001.json   NORAD 44714  el=48.23°  fd=171617 Hz   SNR=8.70 dB  residual 0.136°
  ok   handover-002.json    NORAD 44714  el=54.33°  fd=145345 Hz   SNR=7.40 dB  residual 0.093°
  ok   obstructed-003.json  NORAD 46029  el=19.34°  fd=-226572 Hz  SNR=3.10 dB  residual 0.374°
  ok   roam-004.json        NORAD 47352  el=39.45°  fd=155900 Hz   SNR=9.20 dB  residual 0.348°

RESULT  positive=4  negative=2  forge=pass
```

Every number there is derived, not stored: the NORAD id is the satellite the boresight resolved to, the elevation and Doppler come out of SGP4 at the second the attestation commits to, and the residual is how far the terminal's reported pointing sat from that satellite.

## The geometry gate

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/geometry-dark.svg">
  <img alt="A station on the WGS-72 ellipsoid, the elevation angle to STARLINK-1008, the boresight tolerance cone, and the resulting Ku-band Doppler shift." src="docs/img/geometry-light.svg">
</picture>

`matchBoresight` asks one question: is there a satellite in the public catalog within 2° of where this terminal says it is pointing, at this exact second? `bad-geometry-006.json` is the same capture with the boresight swung 25°, and it is rejected at 16.68°.

The 2° budget is mostly the whole-second timestamp: a satellite near zenith sweeps about 0.9°/s, so committing an integer second costs up to ~1° of pointing on its own. Terminal quantisation and SGP4 along-track drift make up the rest.

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

**The one geometric binding:** a capture is only attested if some satellite in the public catalog was actually where the terminal says it was pointing, at the second the attestation commits to.

**Does not prove:** that a given JSON was signed by SpaceX silicon; that the operator was physically at the station it declares; that BSC validators live in orbit; affiliation with SpaceX/Starlink.

## Known limits

- **One attester.** `attester` is a single immutable EOA. Every on-chain check runs on data that key signed, so the checks defend against a *buggy* attester, never a lying one. A quorum of independent stations — where several receivers must agree on the Doppler of the same satellite — is the obvious next step and is not implemented here.
- **The attestation is a location fingerprint.** Stripping GPS from the capture does not hide much: `(noradId, elevation, doppler, timestamp)` against a public TLE constrains the observer to a narrow region, and a few beacons pin it.
- **`dishGetStatus.snr` is deprecated.** Recent terminal firmware stopped populating it, so `extractFeatures` will reject captures from a current dish until the feature set moves to a field that is still served. The fixtures use the documented field.
- **`usedDigest` grows without bound** — one permanent storage slot per beacon, load-bearing only for the 120 s TTL.

Independent protocol. Not affiliated with SpaceX.

## License

MIT. SGP4 follows the published Vallado/CelesTrak algorithm (AIAA 2006-6753). TLEs in `vectors/tle/starlink-*.txt` are from the public CelesTrak GP catalog.
