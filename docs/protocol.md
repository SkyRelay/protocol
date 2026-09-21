# SkyRelay attestation protocol

## Pipeline

```
 Starlink UT gRPC JSON        physical filter        SGP4 boresight match        chain
192.168.100.1:9200  →  SNR, handover, AS14593  →  NORAD, ε, f_d, catalog  →  EIP-712  →  SkyRelayBeacon
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

The committed fixtures sit at 0.05°–0.40°; `bad-geometry-006` is 16.9° out and is rejected.

This is the protocol's only check a forger cannot satisfy by editing a field. It still does not prove the capture came from Starlink silicon, or that the operator was at the station it declares.

## Committing to the catalog

`catalogHash` is `keccak256` over the element sets the sighting was resolved against: entries sorted by NORAD id, each as its two 69-column lines, joined by newlines. Sorting makes the hash independent of the order files were read in.

Without it the chain sees only a NORAD id, and an attestation computed from a doctored element set is indistinguishable from one computed against the real catalog — "consistent with a real orbit" would rest entirely on the operator having used the real orbit. With it, a verifier can re-fetch the archived CelesTrak elements for that epoch, recompute the hash, and recompute the geometry.

What it does **not** do is prove the committed catalog is the true one. It makes the choice auditable after the fact, not enforced at signing time.

## EIP-712

```
SkyRelayAttestation(
  address operator,
  bytes32 telemetryHash,
  bytes32 catalogHash,
  uint32  noradId,
  int32   elevationMilliDeg,
  int32   dopplerHz,
  uint32  snrMilliDb,
  uint32  asn,
  uint64  timestamp
)
```

Domain: `name = "SkyRelay"`, `version = "1"`, `chainId`, `verifyingContract`.

`operator` is a station operator, and one of the operators in a submitted set must be `msg.sender`. Without it the digest says nothing about who broadcasts the beacon, and anyone watching the mempool could copy a signed attestation, take the credit, and leave the rightful sender reverting on `Replay`.

`telemetryHash` is `keccak256(utf8(timestamp|snr|downlink|asn|az|el|handoverSlot))` over the **integer** feature vector, so the chain never sees floats.

Type hashes are computed in TypeScript (`packages/core/src/crypto/eip712.ts`) with an in-repo Keccak-256 (Ethereum padding `0x01`, not NIST SHA3) and in Solidity with `keccak256(bytes(...))`. Compatibility is not asserted, it is tested: `vectors/eip712/attestations.json` carries the digests the TypeScript side produces, `contracts/test/Eip712Vectors.t.sol` recomputes each one with solc, and `packages/core/test/pipeline.test.ts` fails if the committed file drifts from what the pipeline produces.

## Quorum

A sighting may be attested by several stations at once. `runQuorum` resolves each member through the ordinary pipeline and then requires the members to agree on *what they saw*: same `noradId`, same `timestamp`, same `catalogHash`, distinct stations, distinct operators.

`vectors/eip712/attestations.json` carries a worked three-station quorum — Valentia Island, Goonhilly Downs and Pleumeur-Bodou, three historic satellite ground-station sites on the Atlantic seaboard, all seeing STARLINK-2034 at the same second:

| Station | Elevation | Doppler | ASN |
|---|---|---|---|
| VALENTIA-01 | 47.24° | +173 690 Hz | 14593 |
| GOONHILLY-02 | 30.35° | +220 040 Hz | 14593 |
| PLEUMEUR-03 | 25.21° | +215 966 Hz | 45700 |

The numbers differ because the stations are hundreds of kilometres apart; they are all consistent with one orbit because there is one orbit. A set in which every station reported the same figures would not be independent observation of anything, and `pnpm verify` fails if the committed quorum ever becomes that.

**What a quorum is worth, precisely.** The off-chain check is the conjunction of independent per-station checks against one shared orbit, so it is not a stronger *mathematical* statement than a single station makes. Its value is operational:

- an attacker must compromise *k* independent keys instead of one;
- a dishonest minority cannot push through data the honest members contradict.

It does **not** stop a single party who holds every key and is willing to run SGP4 — that party can fabricate *k* mutually consistent reports. Anyone reading "quorum" as "unforgeable" is reading too much into it.

## Pass tracks

A quorum spreads one instant across several stations. A *track* spreads one station across a whole pass, and it constrains a different thing: not who signed, but whether the numbers move the way orbital mechanics says they must.

`checkPassShape` requires, over a sequence of sightings from one station of one satellite:

- timestamps strictly increasing;
- Doppler **strictly falling** — range-rate rises monotonically from approach to recession, and \(f_d = -\dot\rho f_c / c\);
- elevation rising to exactly one maximum, then falling;
- every sample above the horizon and inside the LEO Ku envelope.

These were checked against eight real passes covering three satellites, two stations and peak elevations from 6.5° to 74°; all eight satisfy them exactly.

The committed track is `vectors/tracks/valentia-01-47352.json`: nine samples of STARLINK-2034 over VALENTIA-01, 480 s apart end to end, peaking at 75.74°, Doppler 263 245 → −263 449 Hz through zero. The quorum above is one sample inside this same pass.

### Why this one is worth more than it looks

```ts
type PassSample = { timestamp: number; elevationMilliDeg: number; dopplerHz: number };
```

That is precisely the content of the `StationReport` event. The shape check therefore needs **nothing that is not already public**: no captures, no element sets, no cooperation from the station. Anyone indexing the chain can rebuild a station's track and test it.

That changes what forgery costs. A fabricated beacon must now sit inside a fabricated *stream*, the stream is visible to everyone, and the constraints linking its members are fixed by physics rather than by policy.

It remains an **off-chain audit**. The contract accepts beacons one at a time and has no view of a track; nothing here makes the shape binding at submission. Treat it as something a verifier runs, not something the protocol enforces.

## On-chain verifier (`SkyRelayBeacon.sol`)

One entry point takes a set; a single-attester deployment is the degenerate case where the set has one member, so there is one code path to audit rather than two.

```solidity
function verifyAndRecord(SkyRelayAttestation[] calldata atts, bytes[] calldata sigs)
    external payable returns (uint256 beaconId);
```

1. not paused
2. `atts.length == sigs.length`, non-empty, `≥ quorumThreshold`, `≤ MAX_QUORUM` (16)
3. TTL on `atts[0].timestamp`: within `(now − 120, now + 30]`
4. every member agrees on `noradId`, `timestamp`, `catalogHash`
5. every member: `asn ∈ {14593, 45700}`, `elevationMilliDeg > 0`
6. operators pairwise distinct
7. each digest unused, then marked used
8. each signature recovers to a **registered** attester, and signers are pairwise distinct
9. `msg.sender` is one of the operators
10. record: one beacon, one `StationReport` per member, `msg.value` forwarded to `orbitalVault`

Signature malleability is not screened, and does not need to be: the replay key is the digest, not the signature, so a flipped `s` produces the same digest and reverts on `Replay`.

The contract never computes an orbit. SGP4, the boresight match and the ASN lookup are all off-chain; what it verifies is that *k* registered keys signed attestations describing the same sighting.

## Governance

One rule, applied consistently:

> **Expansions of signing power are timelocked. Contractions take effect immediately.**

| Action | Effect | Why |
|---|---|---|
| `scheduleAttester` → `activateAttester` | after `ROTATION_DELAY` (2 days) | a new key can sign; the addition is visible on chain before it bites |
| `removeAttester` | immediate | an operator who has just learned a key is compromised must not wait two days to revoke it |
| `setQuorumThreshold`, raising | immediate | strictly fewer signature sets become valid |
| `setQuorumThreshold`, lowering → `activateQuorumThreshold` | after `ROTATION_DELAY` | strictly more become valid |
| `pause` / `unpause` | immediate | emergency stop |
| `transferOwnership` → `acceptOwnership` | two-step | a typo in the new owner address does not brick governance |

`activateAttester` and `activateQuorumThreshold` are permissionless once the delay has run: the decision was the owner's, the clock is everybody's. `removeAttester` refuses to drop the set below `quorumThreshold`.

## Trust model

Every on-chain check runs on fields the attesters signed. They bound *buggy* attesters, not dishonest ones: an attester that lies simply signs consistent lies. What the protocol offers is a dial — `quorumThreshold` — that sets how many independent keys must lie at once.

At `quorumThreshold = 1` the model reduces to a single EOA, and the honest description is the one in README's *Known limits*. Raising it is an operational decision, not a code change, and the contract will not let it exceed the number of registered attesters.

Making the assumption genuinely small needs something this repository does not have: attesters whose independence is externally verifiable, and a reason to believe they are not all the same person.

## Privacy

`stripPrivateFields` drops `location.{lat,lon,alt}` and replaces UT `id` with `utidHash = keccak256(id)[:8]`. Diagnostics from the official proto embed GPS; stripping is mandatory before a capture leaves the LAN.

This protects the *capture*, not the operator. The attestation itself publishes `(noradId, elevationMilliDeg, dopplerHz, timestamp)`, and against a public TLE that tuple constrains the observer to a narrow locus; a handful of beacons from one station pin it. A quorum makes this strictly worse: three stations reporting the same sighting triangulate each other. Treat every station location as public.

## Attester keys

Foundry tests use `vm.sign`. Production attesters are operator EOAs or Safes. The TypeScript pipeline **does not** need secp256k1 at runtime: it produces the digest; the chain does ecrecover.
