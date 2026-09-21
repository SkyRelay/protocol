# SkyRelay — open-source feasibility repository

**physical telemetry → EIP-712 → BSC. No web app, no Postgres, no Docker.**

| | |
|--|--|
| Object | Prove, in one command, that Starlink UT JSON + public TLEs can be bound into an EIP-712 digest that `SkyRelayBeacon` ecrecovers on BSC |
| Non-object | Frontend, RPC gateway, DePIN mining, “blocks in space”, SpaceX affiliation |
| Site | <https://skyrelay.link> |
| Source | <https://github.com/SkyRelay/protocol> |
| Run | `pnpm install && pnpm verify`, or `pnpm typecheck` / `pnpm test` / `cd contracts && forge test` |

Architecture, math, trust model, and vectors: `README.md`, `docs/protocol.md`, `docs/orbital-proof.md`, `vectors/README.md`.

The honest summary is in two lines: the encoding and the geometry are verified against sources outside this repository, and the trust model is one signing key. See “Known limits” in `README.md` before building anything on it.
