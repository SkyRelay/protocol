# What lives on BNB Smart Chain

Three contracts, deployed together, referenced by address. `SkyRelayBeacon` does not own the other two: replacing the bond or the registry is a new beacon, not an upgrade of this one. External contracts read the ledger through `ISkyRelay`; they do not write beacons.

Measured with `forge test --match-test <name> --gas-report --isolate`, solc 0.8.24, optimizer 200 runs, Foundry default EVM. These are the isolated call costs from the tests named below, not an average across reverts.

## Contracts

| Contract | Role |
|---|---|
| `SkyRelayBeacon` | EIP-712 verify, attester set, quorum, TTL, replay, `StationReport`, windowed counts, relay claims |
| `SkyRelayBond` | native-BNB bond, unbonding delay, equivocation slash |
| `CatalogRegistry` | `catalogHash → locator` hint; `isRegistered` |
| `ISkyRelay` | read-only ABI a consumer imports; not a fourth deployment |

`MockCoverageEscrow` under `contracts/test/mock/` is a demonstration, not a product: a funder locks BNB, the operator collects after `toTs` if `beaconCountInWindow` meets `minBeacons`.

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
| 12 |  | `beaconSignedBy` | mapping(uint256 ⇒ mapping(address ⇒ bool)) |
| 13 |  | `_relayClaims` | mapping(uint256 ⇒ mapping(address ⇒ StoredRelayClaim)) |
| 14 |  | `_claimers` | mapping(uint256 ⇒ address[]) |

`beaconsByDay` keys `uint32(attestation.timestamp / 86400)` — the sighting's time, not `block.timestamp`. `userBeaconCount` remains a lifetime total; a consumer that cares about a window asks `beaconCountInWindow`.

`BeaconSummary` is three slots per id (`noradId`+`timestamp`, `catalogHash`, `quorum`+`submitter`). That is the packing the ABI struct allows: `catalogHash` is 32 bytes, so it cannot share a slot.

`StoredRelayClaim` is two slots (`relayedTxRoot`, then `claimedAt`+`txCount`+`exists`). One claim per `(beaconId, attester)`. `beaconSignedBy` is the set that signed that beacon, recorded in `verifyAndRecord`, so a stranger cannot attach a claim to someone else's sighting.

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

## Measured gas

| Call | Test | Gas |
|---|---|---|
| `verifyAndRecord` — one attester | `test_recordsABeacon` | 265 529 |
| `verifyAndRecord` — three-member quorum | `test_quorumOfThreeIsRecordedOnce` | 500 610 |
| `submitRelayClaim` — first claim on a beacon | `test_submitRelayClaim` | 135 638 |
| `beaconCountInWindow` — 1 day | `test_beaconCountInWindow_1day` | 3 587 |
| `beaconCountInWindow` — 30 days | `test_beaconCountInWindow_30days` | 74 927 |
| `beaconCountInWindow` — 366 days | `test_beaconCountInWindow_366days` | 901 487 |
| `slashEquivocation` — valid report | `test_genuineEquivocationSlashesPaysAndEjects` | 114 681 |
| `bond()` first lock of `minBond` | same suites, first `bond` | 49 744 |
| `CatalogRegistry.register` | first write of a hash | 94 754 |
| `requestUnbond` | `test_requestUnbondDeactivatesImmediately` | 49 776 |

The three-member call is not 3× the single: the shared header (pause, TTL, quorum size, `BeaconSummary` write) is paid once; each extra member adds a catalog lookup, an `isActive` call, a digest slot, a signature recover, a `StationReport`, a day-bucket increment, and a `beaconSignedBy` bit.

Against the previous one-attester figure (152 435), the new writes add **113 094**: about 67 350 for the three-slot `BeaconSummary`, and about 45 744 per member for `beaconsByDay` plus `beaconSignedBy`. The three-member delta against 296 028 is 204 582, which is that same summary cost plus three member writes.

`beaconCountInWindow` is one SLOAD per day in the inclusive span (~2 460 gas/day after the 1-day baseline). The 366-day cap is what keeps that loop bounded.

## Cost arithmetic

**Assumption, not a measurement:** gas price 3 gwei, BNB at $600. BSC fees move; recompute `gas × gasPrice × bnbUsd` with whatever the mempool is actually offering.

| Call | BNB at 3 gwei | USD at $600 / BNB |
|---|---|---|
| `verifyAndRecord` (1) | 0.000797 BNB | $0.48 |
| `verifyAndRecord` (3) | 0.001502 BNB | $0.90 |
| `submitRelayClaim` | 0.000407 BNB | $0.24 |
| `beaconCountInWindow` (30 days) | 0.000225 BNB | $0.13 |
| `slashEquivocation` | 0.000344 BNB | $0.21 |
| `bond()` | 0.000149 BNB | $0.09 |
| `register` | 0.000284 BNB | $0.17 |

The bond itself (`minBond`, default 1 BNB in `Deploy.s.sol`) is the capital lock, separate from these fees. Controlling a quorum of k costs k × `minBond` locked, plus k keys the owner has admitted.

## What the chain does not do

It does not propagate an orbit, check a boresight, or decide that a catalog is the real CelesTrak file. It checks signatures, set membership, an active bond, a registered hash, TTL, replay, and the one fraud proof in `slashEquivocation`: same signer, same operator, same timestamp, different digests.

It does not verify that any transaction took a satellite path. A relay claim is a bonded assertion bound to a sighting the chain *did* verify and to a bond that can be taken. `wasClaimedSpaceRelayed` returning true means a bonded attester signed a statement that this transaction was relayed during that sighting. The routing itself is the attester's word.
