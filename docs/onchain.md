# What lives on BNB Smart Chain

Three contracts, deployed together, referenced by address. `SkyRelayBeacon` does not own the other two: replacing the bond or the registry is a new beacon, not an upgrade of this one.

Measured with `forge test --match-test <name> --gas-report --isolate`, solc 0.8.24, optimizer 200 runs, Foundry default EVM. These are the isolated call costs from the tests named below, not an average across reverts.

## Contracts

| Contract | Role |
|---|---|
| `SkyRelayBeacon` | EIP-712 verify, attester set, quorum, TTL, replay, `StationReport` |
| `SkyRelayBond` | native-BNB bond, unbonding delay, equivocation slash |
| `CatalogRegistry` | `catalogHash → locator` hint; `isRegistered` |

The EIP-712 type string is unchanged. Digests in `vectors/eip712/attestations.json` are still what `hashAttestation` produces.

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
| `verifyAndRecord` — one attester | `test_recordsABeacon` | 152 435 |
| `verifyAndRecord` — three-member quorum | `test_quorumOfThreeIsRecordedOnce` | 296 028 |
| `slashEquivocation` — valid report | `test_genuineEquivocationSlashesPaysAndEjects` | 114 399 |
| `bond()` first lock of `minBond` | same suites, first `bond` | 49 744 |
| `CatalogRegistry.register` | first write of a hash | 94 754 |
| `requestUnbond` | `test_requestUnbondDeactivatesImmediately` | 49 776 |

The three-member call is not 3× the single: the shared header (pause, TTL, quorum size) is paid once; each extra member adds a catalog lookup, an `isActive` call, a digest slot, a signature recover, and a `StationReport`.

## Cost arithmetic

**Assumption, not a measurement:** gas price 3 gwei, BNB at $600. BSC fees move; recompute `gas × gasPrice × bnbUsd` with whatever the mempool is actually offering.

| Call | BNB at 3 gwei | USD at $600 / BNB |
|---|---|---|
| `verifyAndRecord` (1) | 0.000457 BNB | $0.27 |
| `verifyAndRecord` (3) | 0.000888 BNB | $0.53 |
| `slashEquivocation` | 0.000343 BNB | $0.21 |
| `bond()` | 0.000149 BNB | $0.09 |
| `register` | 0.000284 BNB | $0.17 |

The bond itself (`minBond`, default 1 BNB in `Deploy.s.sol`) is the capital lock, separate from these fees. Controlling a quorum of k costs k × `minBond` locked, plus k keys the owner has admitted.

## What the chain does not do

It does not propagate an orbit, check a boresight, or decide that a catalog is the real CelesTrak file. It checks signatures, set membership, an active bond, a registered hash, TTL, replay, and the one fraud proof in `slashEquivocation`: same signer, same operator, same timestamp, different digests.
