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

`CatalogRegistry` stores that hash with an opaque `locator` (a BNB Greenfield object reference in practice). The contract does not parse or validate the locator: the keccak hash is the commitment, the locator is a hint about where to look. An object fetched from it that does not hash to `catalogHash` is the wrong object. `verifyAndRecord` refuses a hash the registry does not hold.

The registry moves the trust rather than removing it. A dishonest registrar can register a doctored catalog. What the hash prevents is substitution after the fact — entries are immutable once written.

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

- an attacker must compromise *k* independent keys *and* lock *k* × `minBond` instead of one;
- a dishonest minority cannot push through data the honest members contradict.

It does **not** stop a single party who holds every key, posts every bond, and is willing to run SGP4 — that party can fabricate *k* mutually consistent reports. Anyone reading "quorum" as "unforgeable" is reading too much into it.

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

function beaconCountInWindow(address operator, uint64 fromTs, uint64 toTs)
    external view returns (uint256 count);

function submitRelayClaim(
    uint256 beaconId, bytes32 relayedTxRoot, uint32 txCount,
    uint64 timestamp, bytes calldata signature, address[] calldata signers
) external;

function wasClaimedSpaceRelayed(bytes32 txHash, uint256 beaconId, bytes32[] calldata proof)
    external view returns (bool claimed, address attester, uint64 claimedAt, uint32 noradId);
```

1. not paused
2. `atts.length == sigs.length`, non-empty, `≥ quorumThreshold`, `≤ MAX_QUORUM` (16)
3. TTL on `atts[0].timestamp`: within `(now − 120, now + 30]`
4. every member agrees on `noradId`, `timestamp`, `catalogHash`
5. every member: `asn ∈ {14593, 45700}`, `elevationMilliDeg > 0`, `catalogRegistry.isRegistered(catalogHash)`
6. operators pairwise distinct
7. each digest unused, then marked used
8. each signature recovers to a **registered** attester whose bond `isActive`, and signers are pairwise distinct
9. `msg.sender` is one of the operators
10. record: one beacon, one `BeaconSummary` (including `signersHash`), one `StationReport` per member, day-bucket write, `msg.value` forwarded to `orbitalVault`

`isAttester` is still required. Bonding is necessary but not sufficient: anyone can lock BNB, and that must not admit them to the set. The owner still decides who is in.

Signature malleability is not screened, and does not need to be: the replay key is the digest, not the signature, so a flipped `s` produces the same digest and reverts on `Replay`.

The contract never computes an orbit. SGP4, the boresight match and the ASN lookup are all off-chain; what it verifies is that *k* registered, bonded keys signed attestations describing the same sighting against a registered catalog.

The EIP-712 type string is unchanged. Storage, events and measured gas: [`onchain.md`](onchain.md).

### Windowed counts

`userBeaconCount` is a lifetime total. A consumer that needs "did this operator produce N verified sightings between T1 and T2" asks `beaconCountInWindow`, which sums `beaconsByDay[operator][timestamp / 86400]` from `fromTs` to `toTs` inclusive. The bucket is the attestation timestamp — when the sighting happened — not `block.timestamp`. The loop is bounded: a span of more than 366 day-buckets reverts `WindowTooLong`. Gas is roughly one SLOAD per day. `RECOMMENDED_WINDOW_DAYS` is 30; longer on-chain settlement should be split into several claims.

### Relay claims

An operator whose terminal relayed BSC transactions during a pass can say so, with a **separate** EIP-712 type:

```
SkyRelayRelayClaim(uint256 beaconId,bytes32 relayedTxRoot,uint32 txCount,uint64 timestamp)
```

Nothing is added to `SkyRelayAttestation`. The chain cannot verify that any transaction took a satellite path — a tx hash carries no route information. What it can do is bind the assertion to a sighting it *did* verify, to a signer who was in that beacon's attester set, and to a bond that can be taken. Membership is proven on the cold path: `verifyAndRecord` stores `signersHash = keccak256(abi.encodePacked(signers))` (order-sensitive); `submitRelayClaim` re-supplies the array, checks the hash, and requires the claim signer appear in it.

`wasClaimedSpaceRelayed` checks a sorted-pair Merkle inclusion proof against the stored root. `claimed` being true means exactly: a bonded attester signed a statement that this transaction was relayed during a sighting the chain verified geometrically. The routing is the attester's word.

### `ISkyRelay`

The beacon ABI an external contract imports is views only: `totalBeacons`, `getBeacon`, `beaconCountInWindow`, `wasClaimedSpaceRelayed`. `SkyRelayBeacon` declares `is ISkyRelay`. `MockCoverageEscrow` is the worked example of a consumer of that ledger; it is a demonstration, not a product.

`ISkyRelayEntropy`, in the same file, is the request surface for `SkyRelayEntropy`: `requestRandomness`, `randomWords`, `seedOf`, `reservice`. The beacon does not implement it. A verified sighting is an admission ticket, not entropy: the satellite contributes none.

## Bonds and equivocation

`SkyRelayBond` is a separate contract the beacon holds by immutable address. Attesters lock native BNB. `isActive` is `bonded >= minBond` and not unbonding. `requestUnbond` deactivates immediately — otherwise an attester could equivocate and unbond in the same block — and `withdraw` is allowed after `unbondingPeriod`.

Equivocation, exactly: two attestations from the **same signer**, with the **same `operator`** and the **same `timestamp`**, but **different digests**. That is two `ecrecover` calls and a comparison. A terminal is in one state at one second; signing two stories about one station at one instant is a contradiction.

What is **not** equivocation: the same `noradId` and `timestamp` with **different operators**. That is a quorum. Several stations at one instant report different elevation and Doppler because they are in different places; slashing that would punish honest members.

On a valid report the reporter receives `reporterBountyBps` of the bond, the vault receives the rest, the bond is zeroed, and the attester is permanently ineligible. The digest pair is recorded so the same report cannot collect a second bounty.

Two lies are provable on chain with no orbit computation: this one, and naming a catalog nobody registered.

## Commit-reveal randomness

`SkyRelayEntropy` is a separate contract. A verified sighting is an admission ticket, not entropy: the satellite contributes none. A bonded key can open a commitment in a round only if it signed a beacon whose timestamp falls inside that round — that is the sybil resistance, and it is the whole of what the sighting contributes. The seed is the participants' secrets. The contract never reads a sighting's geometry.

The beacon is secure if at least one participant is honest and reveals.

The last revealer, having seen the other reveals, can withhold theirs: that drops their contribution and forces the seed the round would have had without them, and it does not let them pick a different one; the cost is `revealDeposit`, so manipulation is bounded by that deposit.

This is not a VRF. If a consumer needs randomness with stronger guarantees than one honest participant, Chainlink VRF exists on BSC and is the appropriate tool.

### Ordering

Rounds are fixed epochs: `round = timestamp / roundSeconds`.

| Action | When |
|---|---|
| Commit for round R | during round R-2; closes when R-1 begins |
| Reveal for round R | during round R |
| A request made during round R | served by round R+1 |

The gap is two rounds on purpose. Commits for R+1 closed at the end of R-1, before the request existed, so no participant can pick a secret with the request in view. Reveals for R+1 happen after the request, so the requester cannot watch reveals accumulate and then decide whether to request. A one-round gap fails the second property: a requester could sit until most of the round's reveals were in and request only on a favourable partial seed.

### Opening a commitment

```solidity
commitment = keccak256(abi.encode(secret, attester, round))
```

The sender and the round sit in the preimage, so a copied commitment cannot be opened by another address or in another round. `commit` accepts it only when `round == currentRound() + 2`, the caller is `bond.isActive`, `msg.value == revealDeposit`, and that address has not already committed for the round. A zero commitment is refused: the mapping uses zero as "none".

`reveal` runs only during `round`. The stored commitment must equal `keccak256(abi.encode(secret, msg.sender, round))`. The sighting gate then requires a `beaconId` whose timestamp falls inside `round`, and `msg.sender` must be one of the attesters who signed it. The beacon stores that set as `signersHash` — one hash, not a slot per member — so the caller re-supplies the signer array in submission order, the same cold path as `submitRelayClaim`. On success the secret is XORed into the round accumulator (`accumulator ^= uint256(secret)`) and `revealDeposit` is refunded. XOR is commutative, so reveal order does not change the seed. The last revealer's only choice is to reveal, or to withhold and forfeit the deposit.

`finalize` is permissionless once the round has ended.

```solidity
seed = keccak256(abi.encode(accumulator, round, revealCount))
```

If `revealCount == 0` the round finalizes unseeded. `seedOf` reverts `NoSeed` rather than return `bytes32(0)`. A `Finalized` event with `contributors == 0` is that case, not a seed of zero.

```solidity
words[i] = uint256(keccak256(abi.encode(seed, requestId, i)))
```

`randomWords` reverts when the serving round is not finalized or has no seed.

Unrevealed deposits stay in the contract. After the round closes the owner sweeps `(commitCount - revealCount) * revealDeposit` to the vault — the accounted forfeits, not the contract balance — and emits `DepositForfeited` per address that committed and did not reveal.

### An empty round

A request whose serving round finalizes with no reveals does not resolve. It never reads as the zero seed. The requester may `reservice` it: the request is then served by `currentRound() + 1`, a later round whose reveals have not started, so the caller cannot pick a seed they have already watched. That later round's commits were not required to have closed before the original request — participants may have seen it — so a consumer who still needs the commit-before-request gap calls `requestRandomness` again instead. Anyone else calling `reservice` reverts; an outsider must not be able to pin the request to a round.

`MockRandomnessConsumer` is the worked example. It requests a draw, waits, and settles on the first word. It is a demonstration, not a product.

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

Every on-chain check runs on fields the attesters signed. They bound *buggy* attesters, and they bound one kind of dishonest attester: one that contradicts itself about a single station-second. An attester that lies *consistently* simply signs consistent lies, and the contract accepts them.

What the protocol offers is a dial — `quorumThreshold` — that sets how many independent keys must lie at once, and a price — `minBond` — on each of those keys. Controlling a quorum of k costs k bonds, not k free keys.

At `quorumThreshold = 1` the model reduces to a single bonded EOA, and the honest description is the one in README's *Known limits*. Raising it is an operational decision, not a code change, and the contract will not let it exceed the number of registered attesters.

A bonded attester with a real station that never contradicts itself can still lie about the physics. Bonding raises the cost of lying; it does not establish truth. The fraud proof that would establish it does not exist here.

The catalog registry moves trust to the registrar rather than removing it. A dishonest registrar can register a doctored catalog; the hash only prevents substitution after the fact.

Making the assumption genuinely small still needs something this repository does not have: attesters whose independence is externally verifiable, and a reason to believe they are not all the same person. k bonds can still be one person.

## Privacy

`stripPrivateFields` drops `location.{lat,lon,alt}` and replaces UT `id` with `utidHash = keccak256(id)[:8]`. Diagnostics from the official proto embed GPS; stripping is mandatory before a capture leaves the LAN.

This protects the *capture*, not the operator. The attestation itself publishes `(noradId, elevationMilliDeg, dopplerHz, timestamp)`, and against a public TLE that tuple constrains the observer to a narrow locus; a handful of beacons from one station pin it. A quorum makes this strictly worse: three stations reporting the same sighting triangulate each other. Treat every station location as public.

## Attester keys

Foundry tests use `vm.sign`. Production attesters are operator EOAs or Safes, and each must lock at least `minBond` in `SkyRelayBond` to be `isActive`. The TypeScript pipeline **does not** need secp256k1 at runtime: it produces the digest; the chain does ecrecover. Bonding is checked on chain, not in the pipeline.
