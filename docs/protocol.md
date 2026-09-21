# SkyRelay attestation protocol

## Pipeline

```
 Starlink UT gRPC JSON        physical filter        SGP4 boresight match        chain
192.168.100.1:9200  →  SNR, handover, AS14593  →  NORAD, ε, f_d  →  EIP-712  →  SkyRelayBeacon
```

Four functions, four failure modes:

| Step | Code | Rejects |
|------|------|---------|
| 1 Ingest | `parseCapture` + `stripPrivateFields` | malformed proto JSON; GPS and the raw terminal id never leave the LAN |
| 2 Features | `extractFeatures` + `assertStarlinkAsn` | ASN ∉ {14593, 45700}; missing SNR; unparseable timestamp |
| 3 Geometry | `matchBoresight` | period ≥ 225 min (SDP4); decayed; nothing above the horizon; no catalog satellite within tolerance of the reported boresight |
| 4 Digest | `hashTypedData` = `hashAttestation` | encoding mismatch is a test failure, not a runtime guess |

There is no degraded path. Step 3 never substitutes a number the terminal reported about itself for one it failed to derive.

## Step 3 in detail

The terminal reports where it is pointing (`boresightAzimuthDeg`, `boresightElevationDeg`). SGP4 says where every satellite in the public catalog was, seen from the operator-declared station, at the second the attestation commits to. `matchBoresight` picks the satellite with the smallest angular separation and refuses the capture when even the best is further than `DEFAULT_BORESIGHT_TOLERANCE_DEG` (2°).

That budget covers three things:

| Source | Magnitude |
|--------|-----------|
| Attestation timestamps are whole seconds, so the geometry is evaluated up to 1 s away from the capture instant. A 550 km satellite near zenith sweeps ~0.9°/s. | ≤ ~1° |
| Terminal reporting quantisation and tracking error | ~0.1° |
| SGP4 along-track error at a half-day-old element set | ~0.1° |

The committed fixtures sit at 0.09°–0.38°; `bad-geometry-006` is 16.7° out and is rejected.

This is the protocol's only check a forger cannot satisfy by editing a field. It still does not prove the capture came from Starlink silicon, or that the operator was at the station it declares.

## EIP-712

```
SkyRelayAttestation(
  address operator,
  bytes32 telemetryHash,
  uint32  noradId,
  int32   elevationMilliDeg,
  int32   dopplerHz,
  uint32  snrMilliDb,
  uint32  asn,
  uint64  timestamp
)
```

Domain: `name = "SkyRelay"`, `version = "1"`, `chainId`, `verifyingContract`.

`operator` is the only address the contract accepts as `msg.sender`. Without it the digest says nothing about who broadcasts the beacon, and anyone watching the mempool could copy a signed attestation, take the credit, and leave the rightful sender reverting on `Replay`.

`telemetryHash` is `keccak256(utf8(timestamp|snr|downlink|asn|az|el|handoverSlot))` over the **integer** feature vector, so the chain never sees floats.

Type hashes are computed in TypeScript (`packages/core/src/crypto/eip712.ts`) with an in-repo Keccak-256 (Ethereum padding `0x01`, not NIST SHA3) and in Solidity with `keccak256(bytes(...))`. Compatibility is not asserted, it is tested: `vectors/eip712/attestations.json` carries the digests the TypeScript side produces, `contracts/test/Eip712Vectors.t.sol` recomputes each one with solc, and `packages/core/test/pipeline.test.ts` fails if the committed file drifts from what the pipeline produces.

## On-chain verifier (`SkyRelayBeacon.sol`)

1. `att.operator == msg.sender`
2. `asn ∈ {14593, 45700}`
3. `elevationMilliDeg > 0`
4. `timestamp ∈ (now − 120, now + 30]`
5. `digest` unused (replay)
6. `ecrecover(digest, sig) == attester`
7. `totalBeacons++`, `totalEnergy += snrMilliDb`
8. `msg.value` is forwarded to `orbitalVault` or the call reverts

Signature malleability is not screened, and does not need to be: the replay key is the digest, not the signature, so a flipped `s` produces the same digest and reverts on `Replay`.

No slash, no SNR mining, no self-reported ASN as calldata without the attester key.

## Trust model

Checks 2–4 above run on fields the attester signed. They bound a *buggy* attester, not a dishonest one: an attester that lies simply signs consistent lies. The protocol as implemented reduces to one immutable EOA.

Making that assumption smaller is a protocol change, not a code change. The direction with teeth is a quorum: several independent stations attesting the same satellite at the same second, where the Doppler and elevation each station reports must be mutually consistent with one orbit. That is not implemented here.

## Privacy

`stripPrivateFields` drops `location.{lat,lon,alt}` and replaces UT `id` with `utidHash = keccak256(id)[:8]`. Diagnostics from the official proto embed GPS; stripping is mandatory before a capture leaves the LAN.

This protects the *capture*, not the operator. The attestation itself publishes `(noradId, elevationMilliDeg, dopplerHz, timestamp)`, and against a public TLE that tuple constrains the observer to a narrow locus; a handful of beacons from one station pin it. Treat the station location as public.

## Attester key

Foundry tests use `vm.sign`. Production attester is an operator EOA / Safe. The TypeScript pipeline **does not** need secp256k1 at runtime: it produces the digest; the chain does ecrecover.
