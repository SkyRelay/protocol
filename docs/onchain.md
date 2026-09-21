# What lives on BNB Smart Chain

`SkyRelayBeacon` does not own the bond or the registry: replacing either is a new beacon, not an upgrade of this one. `SkyRelayEntropy` is a fourth contract. It holds the beacon and the bond by immutable address and does not write sightings. External contracts read the ledger through `ISkyRelay` and request randomness through `ISkyRelayEntropy`.

Measured with `forge test --match-test <name> --gas-report --isolate`, solc 0.8.24, optimizer 200 runs, Foundry default EVM. These are the isolated call costs from the tests named below, not an average across reverts. A same-day `verifyAndRecord` figure is the cheaper of the two calls in that test (the `--gas-report` minimum). The first-of-day figure is the single call in the other test.

## Contracts

| Contract | Role |
|---|---|
| `SkyRelayBeacon` | EIP-712 verify, attester set, quorum, TTL, replay, `StationReport`, windowed counts, relay claims |
| `SkyRelayBond` | native-BNB bond, unbonding delay, equivocation slash |
| `CatalogRegistry` | `catalogHash → locator` hint; `isRegistered` |
| `SkyRelayEntropy` | commit-reveal beacon; a sighting admits a bonded signer, the secrets are the seed |
| `ISkyRelay` | read-only beacon ABI a consumer imports |
| `ISkyRelayEntropy` | `requestRandomness`, `randomWords`, `seedOf`, `reservice`; same file as `ISkyRelay` |

`MockCoverageEscrow` under `contracts/test/mock/` is a demonstration, not a product: a funder locks BNB, the operator collects after `toTs` if `beaconCountInWindow` meets `minBeacons`. `MockRandomnessConsumer` requests words from `SkyRelayEntropy` and settles on the first once the serving round has a seed.

A verified sighting is an admission ticket, not entropy: the satellite contributes none. The beacon is secure if at least one participant is honest and reveals. The last revealer, having seen the other reveals, can withhold theirs: that drops their contribution and forces the seed the round would have had without them, and it does not let them pick a different one; the cost is `revealDeposit`, so manipulation is bounded by that deposit. This is not a VRF. If a consumer needs randomness with stronger guarantees than one honest participant, Chainlink VRF exists on BSC and is the appropriate tool.

The `SkyRelayAttestation` type string is unchanged. Digests in `vectors/eip712/attestations.json` are still what `hashAttestation` produces. Relay claims use a **separate** type, `SkyRelayRelayClaim`.

## Storage

Immutables sit in bytecode, not in the slots below. Layout from `forge inspect <Contract> storageLayout`.

### `SkyRelayBeacon`

Immutables: `orbitalVault`, `catalogRegistry`, `bond`, plus the EIP-712 name/version hashes.

| Slot | Offset | Name | Type |
|---|---|---|---|
| 0 | 0 | `owner` | address |
| 1 | 0 | `pendingOwner` | address |
| 1 | 20 | `paused` | bool |
| 2 |  | `isAttester` | mapping(address ⇒ bool) |
| 3 | 0 | `attesterCount` | uint8 |
| 3 | 1 | `quorumThreshold` | uint8 |
| 4 |  | `attesterEligibleAt` | mapping(address ⇒ uint64) |
| 5 | 0 | `pendingQuorumThreshold` | uint8 |
| 5 | 1 | `quorumThresholdEligibleAt` | uint64 |
| 6 |  | `totalBeacons` | uint256 |
| 7 |  | `totalEnergy` | uint256 |
| 8 |  | `userBeaconCount` | mapping(address ⇒ uint256) |
| 9 |  | `usedDigest` | mapping(bytes32 ⇒ bool) |
| 10 |  | `beaconsByDay` | mapping(address ⇒ mapping(uint32 ⇒ uint32)) |
| 11 |  | `_summaries` | mapping(uint256 ⇒ BeaconSummary) |
| 12 |  | `_relayClaims` | mapping(uint256 ⇒ mapping(address ⇒ StoredRelayClaim)) |
| 13 |  | `_claimers` | mapping(uint256 ⇒ address[]) |

`beaconsByDay` keys `uint32(attestation.timestamp / 86400)` — the sighting's time, not `block.timestamp`. `userBeaconCount` remains a lifetime total; a consumer that cares about a window asks `beaconCountInWindow`.

`BeaconSummary` is three slots per id. `noradId`, `timestamp` and `quorum` share the first (13 bytes); `catalogHash` and `signersHash` each take a slot. `submitter` is not stored: nothing on chain read it, and an indexer takes it from `BeaconBroadcast`. The address is 20 bytes, so it does not fit beside those three fields — putting it back adds a fourth slot and a cold SSTORE on every sighting. `signersHash` is `keccak256(abi.encodePacked(signers))` over the recovered signers in submission order — order-sensitive. The hot path stores that one hash; `submitRelayClaim` re-supplies the array, checks it, and requires the claim signer appear in it.

`StoredRelayClaim` is two slots (`relayedTxRoot`, then `claimedAt`+`txCount`+`exists`). One claim per `(beaconId, attester)`.

### `SkyRelayBond`

Immutables: `minBond`, `unbondingPeriod`, `reporterBountyBps`, `vault`, `beacon`.

| Slot | Name | Type |
|---|---|---|
| 0 | `bonded` | mapping(address ⇒ uint256) |
| 1 | `unbondingAt` | mapping(address ⇒ uint64) |
| 2 | `slashed` | mapping(address ⇒ bool) |
| 3 | `proven` | mapping(bytes32 ⇒ bool) |

`unbondingAt == 0` means not unbonding. `proven` keys a sorted pair of digests so `(A,B)` and `(B,A)` pay the bounty once.

### `CatalogRegistry`

| Slot | Name | Type |
|---|---|---|
| 0 | `owner` | address |
| 1 | `pendingOwner` | address |
| 2 | `registrar` | address |
| 3 | `catalogs` | mapping(bytes32 ⇒ CatalogEntry) |

`CatalogEntry` is `{ uint64 registeredAt; string locator; }`. `isRegistered` is `registeredAt != 0`. The locator is an opaque string; the contract does not parse it.

### `SkyRelayEntropy`

Immutables: `roundSeconds`, `revealDeposit`, `vault`, `beacon`, `bond`.

| Slot | Name | Type |
|---|---|---|
| 0 | `owner` | address |
| 1 | `pendingOwner` | address |
| 2 | `rounds` | mapping(uint64 ⇒ Round) |
| 3 | `commitmentOf` | mapping(uint64 ⇒ mapping(address ⇒ bytes32)) |
| 4 | `revealedIn` | mapping(uint64 ⇒ mapping(address ⇒ bool)) |
| 5 | `_committers` | mapping(uint64 ⇒ address[]) |
| 6 | `forfeitsSwept` | mapping(uint64 ⇒ bool) |
| 7 | `requests` | mapping(bytes32 ⇒ Request) |
| 8 | `requestNonce` | uint256 |

`Round` is three slots: `accumulator`, then `commitCount` + `revealCount` + `finalized` (9 bytes), then `seed`. `Request` is one slot: `requester` (20) + `servingRound` (8) + `numWords` (4). Layout from `solc --storage-layout`, solc 0.8.24.

`accumulator` is the XOR of revealed secrets. It is not a seed. `finalize` stores `keccak256(abi.encode(accumulator, round, revealCount))`. A finalized round with `revealCount == 0` leaves `seed` at zero, and `seedOf` reverts `NoSeed` — that zero word is not a seed.

`_committers` exists so `sweepForfeited` can name each forfeit. The sweep sends `(commitCount - revealCount) * revealDeposit` to `vault`, not the contract balance.

## Events an indexer reads

Rebuild a station's pass from `StationReport` alone (`timestamp`, `elevationMilliDeg`, `dopplerHz`) — that is what `checkPassShape` consumes, and it needs nothing else.

| Event | Where | Why |
|---|---|---|
| `BeaconBroadcast(beaconId, noradId, submitter, timestamp, catalogHash, quorum)` | beacon | one sighting, one row |
| `StationReport(beaconId, operator, elevationMilliDeg, dopplerHz, snrMilliDb, asn, telemetryHash, digest)` | beacon | per-member geometry; the pass-shape input |
| `VaultDeposit(from, amount)` | beacon | optional `msg.value` forwarded with a beacon |
| `RelayClaimed(beaconId, attester, relayedTxRoot, txCount, timestamp)` | beacon | a bonded attester asserted a tx root against a verified sighting |
| `Bonded(attester, amount, total)` | bond | stake posted |
| `UnbondRequested(attester, at, amount)` | bond | attester is inactive from this block |
| `Withdrawn(attester, amount)` | bond | stake returned after the delay |
| `Equivocation(attester, reporter, digestA, digestB, amount)` | bond | slash paid; attester permanently ineligible |
| `CatalogRegistered(catalogHash, locator, at)` | registry | hash is now admissible; locator is a fetch hint |
| `AttesterScheduled` / `AttesterActivated` / `AttesterRemoved` | beacon | set membership |
| `QuorumThresholdScheduled` / `QuorumThresholdSet` | beacon | how many signatures a sighting needs |
| `PausedSet` | beacon | emergency stop |
| `OwnershipTransferStarted` / `OwnershipTransferred` | beacon, registry | two-step owner move |
| `RegistrarSet` | registry | who may call `register` |
| `Committed(round, attester, commitment)` | entropy | a bonded key locked a secret for round R, during R-2 |
| `Revealed(round, attester, beaconId)` | entropy | the secret was opened against a sighting in that round |
| `Finalized(round, seed, contributors)` | entropy | `contributors == 0` means the round is unseeded, not that the seed is zero |
| `DepositForfeited(round, attester, amount)` | entropy | an unrevealed `revealDeposit`, swept to the vault |
| `RandomnessRequested(requestId, requester, servingRound, numWords)` | entropy | a request during R, served by R+1 |
| `RequestReserviced(requestId, servingRound)` | entropy | an unseeded request pointed at a later round |

## Measured gas

Figures in this section come from `forge test --gas-report --isolate` and are transaction-level, including the 21 000 intrinsic gas and cold account access.

| Call | Tests | First of day | Same day, subsequent |
|---|---|---|---|
| `verifyAndRecord` — one attester | `test_recordsABeacon`, `test_secondBeaconSameDayIsCheaper` | 243 530 | 175 142 |
| `verifyAndRecord` — three-member quorum | `test_quorumOfThreeIsRecordedOnce`, `test_secondQuorumOfThreeSameDayIsCheaper` | 434 271 | 297 483 |

| Call | Test | Gas |
|---|---|---|
| `submitRelayClaim` — first claim on a beacon | `test_submitRelayClaim` | 137 211 |
| `beaconCountInWindow` — 1 day | `test_beaconCountInWindow_1day` | 3 587 |
| `beaconCountInWindow` — 30 days | `test_beaconCountInWindow_30days` | 74 927 |
| `beaconCountInWindow` — 366 days | `test_beaconCountInWindow_366days` | 901 487 |
| `slashEquivocation` — valid report | `test_genuineEquivocationSlashesPaysAndEjects` | 114 681 |
| `bond()` first lock of `minBond` | same suites, first `bond` | 49 744 |
| `CatalogRegistry.register` | first write of a hash | 94 754 |
| `requestUnbond` | `test_requestUnbondDeactivatesImmediately` | 49 776 |
| `SkyRelayEntropy.commit` — first commit of a round | `test_gasCommit` | 123 582 |
| `SkyRelayEntropy.reveal` — one signer, deposit refunded | `test_gasReveal` | 97 969 |
| `SkyRelayEntropy.finalize` — one reveal | `test_gasFinalize` | 53 273 |

The three-member call is not 3× the single: the shared header (pause, TTL, quorum size, the three-slot `BeaconSummary` write) is paid once; each extra member adds a catalog lookup, an `isActive` call, a digest slot, a signature recover, a `StationReport`, and a day-bucket increment. Membership is one shared `signersHash`, not a slot per member.

The two `verifyAndRecord` figures differ because a storage slot going from zero pays a cold SSTORE — 20 000 gas, plus 2 100 when the slot is cold — and updating a non-zero slot costs 2 900. The gap is 17 100 per slot. The first beacon in the table is also the first beacon on the contract, so the zero slots are `beaconsByDay` and `userBeaconCount` for each operator, plus `totalBeacons` and `totalEnergy`: four slots for one attester (68 400) and eight for a quorum of three (136 800). The measured gaps, 68 388 and 136 788, are 12 gas of calldata off that arithmetic. A later beacon the same day updates those slots. On a later day the only new zero slot is that day's `beaconsByDay`, 17 100 gas per operator. That is the once-a-day surcharge. `userBeaconCount` is paid once per operator, and `totalBeacons` / `totalEnergy` once per contract.

Removing `submitter` deleted the fourth summary slot. One-attester first-of-day went from 265 719 to 243 530 (−22 189); the three-member call from 456 461 to 434 271 (−22 190). `submitRelayClaim` is unchanged at 137 211.

`beaconCountInWindow` is one SLOAD per day in the inclusive span (~2 460 gas/day after the 1-day baseline). `MAX_WINDOW_DAYS` stays 366 so a long off-chain read stays legal; `RECOMMENDED_WINDOW_DAYS` is 30 (~75k gas). A year on chain is ~900k and close to unusable for an escrow — split longer settlement into several claims.

## Cost arithmetic

**Assumption, not a measurement:** gas price 3 gwei, BNB at $600. BSC fees move; recompute `gas × gasPrice × bnbUsd` with whatever the mempool is actually offering.

| Call | BNB at 3 gwei | USD at $600 / BNB |
|---|---|---|
| `verifyAndRecord` (1), first of day | 0.000731 BNB | $0.44 |
| `verifyAndRecord` (1), same day | 0.000525 BNB | $0.32 |
| `verifyAndRecord` (3), first of day | 0.001303 BNB | $0.78 |
| `verifyAndRecord` (3), same day | 0.000892 BNB | $0.54 |
| `submitRelayClaim` | 0.000412 BNB | $0.25 |
| `beaconCountInWindow` (30 days) | 0.000225 BNB | $0.13 |
| `slashEquivocation` | 0.000344 BNB | $0.21 |
| `bond()` | 0.000149 BNB | $0.09 |
| `register` | 0.000284 BNB | $0.17 |
| `commit` | 0.000371 BNB | $0.22 |
| `reveal` | 0.000294 BNB | $0.18 |
| `finalize` | 0.000160 BNB | $0.10 |

The bond itself (`minBond`, default 1 BNB in `Deploy.s.sol`) is the capital lock, separate from these fees. Controlling a quorum of k costs k × `minBond` locked, plus k keys the owner has admitted. Withholding a reveal forfeits `revealDeposit` (default 0.01 BNB in `Deploy.s.sol`); that deposit, not the gas, is the price of the last-revealer abort.

## Cadence

The table above is per call. A station that anchors every minute pays the same-day figure 525 600 times a year. A station that anchors once per pass — a few minutes of visibility, then nothing until the next orbit — pays it roughly 35 000 times a year. The first beacon of each UTC day also pays the day-bucket surcharge, 17 100 gas per operator (51 300 for this quorum). Over 365 days that is 18 724 500 gas: 0.00187 BNB ($1.12) at 0.1 gwei, 0.0187 BNB ($11.23) at 1 gwei, 0.0562 BNB ($33.70) at 3 gwei.

**Assumptions, not measurements:** the three-member same-day gas above (297 483), BNB at $600, and the gas prices in the columns. Recompute when any of those move.

| Cadence | writes / year | at 0.1 gwei | at 1 gwei | at 3 gwei |
|---|---|---|---|---|
| one beacon / minute | 525 600 | 15.6 BNB / $9 380 | 156 BNB / $93 800 | 469 BNB / $281 000 |
| one beacon / pass | ~35 000 | 1.04 BNB / $625 | 10.4 BNB / $6 250 | 31.2 BNB / $18 700 |

The per-minute cadence does not survive any of those gas prices. It was a demo default, not a protocol requirement. The anchoring rate has to be derived from cost.

## What the chain does not do

It does not propagate an orbit, check a boresight, or decide that a catalog is the real CelesTrak file. It checks signatures, set membership, an active bond, a registered hash, TTL, replay, and the one fraud proof in `slashEquivocation`: same signer, same operator, same timestamp, different digests.

It does not verify that any transaction took a satellite path. A relay claim is a bonded assertion bound to a sighting the chain *did* verify and to a bond that can be taken. `wasClaimedSpaceRelayed` returning true means a bonded attester signed a statement that this transaction was relayed during that sighting. The routing itself is the attester's word.

`SkyRelayEntropy` does not read a sighting's geometry, and it does not treat the satellite as a source of entropy. A sighting admits a bonded signer to a round. The seed is `keccak256` of the XOR of the secrets that signer set actually revealed, the round, and the reveal count. A round nobody revealed into does not become `bytes32(0)`; `seedOf` reverts `NoSeed`. The beacon is secure if at least one participant is honest and reveals, and the last revealer can still force the seed that excludes them by forfeiting `revealDeposit`. That is not a VRF.
