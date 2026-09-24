# SRO-1: Recomputable Oracle Specification (可复算预言机技术标准)

> **Status**: Draft RFC · Revision 1.0  
> **Authors**: SkyRelay Protocol Research Group  
> **Classification**: BNB Chain Protocol Architectural Standard  
> **Reference Implementation**: `CatalogRegistry.sol`, `SkyRelayBeacon.sol`, `EquivocationBond.sol`

---

## 1. Abstract (摘要)

Current blockchain oracles rely almost exclusively on three trust paradigms:
1. **Trusted Committees (Multi-Sig)**: Trusting that reporters do not collude (e.g., Chainlink, Pyth).
2. **Optimistic Dispute Games**: Trusting token-weighted voting with multi-day challenge windows (e.g., UMA).
3. **Zero-Knowledge Proofs**: Trusting cryptographic circuits backed by expensive GPU provers.

**SRO-1 defines a Fourth Paradigm: The Recomputable Oracle (可复算预言机)**.  
When an oracle reports a value that is a deterministic function of public input data, consensus does not require committee arbitration or dispute games. Instead, **any third party can recompute the reported output offline in $O(1)$ time with zero privileged information**. Disagreements are settled by pure arithmetic rather than governance.

---

## 2. The Three-Tier Architecture (三级分级架构)

To ensure SRO-1 serves the entire BNB Chain ecosystem rather than a single specialized protocol, compliance is divided into three progressive tiers:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        SRO-1 TIER CLASSIFICATION                       │
├─────────┬──────────────────────────────────┬───────────────────────────┤
│ Tier    │ Architectural Requirements       │ Applicability Target      │
├─────────┼──────────────────────────────────┼───────────────────────────┤
│ Level A │ Input Commitment                 │ Any Oracle (Price, Weather│
│         │ On-chain report carries          │ Sports, Randomness)       │
│         │ hash of the input dataset        │                           │
├─────────┼──────────────────────────────────┼───────────────────────────┤
│ Level B │ Retrievable & Content-Addressed  │ Price Oracles, DEX TWAP,  │
│         │ Input raw batch stored on BNB    │ Cross-chain state roots   │
│         │ Greenfield / IPFS by hash        │ (The Real Practical Value)│
├─────────┼──────────────────────────────────┼───────────────────────────┤
│ Level C │ Full Deterministic Recomputation │ SkyRelay Orbital Passes,  │
│         │ Open-source client-side model,   │ Analytical Physics Feeds, │
│         │ continuous numerical residual    │ Zero-Prover Determinism   │
└─────────┴──────────────────────────────────┴───────────────────────────┘
```

### Level A: Committed (已承诺)
* **Requirement**: The oracle attestation must commit to the cryptographic digest (`bytes32 inputHash`) of the exact raw dataset from which the output was derived.
* **Cost**: Exactly 1 `bytes32` slot in the attestation struct.

### Level B: Retrievable (可取回)
* **Requirement**:
  1. Satisfies Level A.
  2. The input dataset must be published to a content-addressed storage layer (e.g., BNB Greenfield or IPFS) where `URI = protocol://{inputHash}`.
  3. The `inputHash` must be registered in an on-chain immutable registry (e.g., `CatalogRegistry.sol`) prior to, or at the time of, report submission.
* **Why Level B is the Core Value for BSC**:
  A financial price oracle cannot easily achieve Level C (spot prices are subjective observations across exchanges). However, **any price oracle can achieve Level B at virtually zero cost**: by publishing the raw signed exchange order-book snapshots to BNB Greenfield under their Keccak256 hash. This shifts the ecosystem from "blind trust in an averaged median" to "fully auditable raw historical observations".

### Level C: Recomputable (可复算)
* **Requirement**:
  1. Satisfies Level B.
  2. Output is a deterministic function: $f(\text{inputData}, \text{context}) \rightarrow \text{output}$.
  3. The verification pipeline must expose a **continuous numerical residual**, not a blunt boolean.
  4. Any observer can download the artifact and recompute the output in $O(1)$ time in a browser or CLI without private API keys.

---

## 3. Hard Invariant Rules (强制规范法则)

### R1: Exact Scope Rule (全集承诺法则)
> *Lesson learned from the 25° search arc mainnet incident:*
The on-chain digest must commit to the canonical, registered dataset in its entirety. It **MUST NOT** be computed over an ephemeral, runtime-filtered candidate subset (e.g., satellites currently within an observer's line-of-sight). Subsetting introduces nondeterminism where failed transactions produce syntactically valid but unmatchable hashes.

### R2: Content-Addressed Naming (内容寻址法则)
The canonical URI stored in the registry must derive strictly from the content hash:
```
URI := "gnfd://skyrelay-catalog/" + hex(keccak256(rawBytes))
```
Storage locations indexed by mutable file paths, URLs, or block numbers are strictly prohibited.

### R3: Continuous Numerical Residuals (连续残差法则)
Verification functions must never reduce validation to a primitive `bool valid`:
```solidity
// FORBIDDEN by SRO-1:
function verify(uint256 beaconId) external view returns (bool matches);

// MANDATED by SRO-1:
function getObservationResidual(uint256 beaconId) external view returns (int32 residualMilliHz);
```
*Rationale*: An elevation discrepancy of $0.001^\circ$ (sensor jitter) and $4.0^\circ$ (forged satellite tracking) are both "out of tolerance," but their forensic significance is entirely different. Auditors require the continuous physical delta.

### R4: Self-Contained Third-Party Reproducibility (零特权复算法则)
The reference mathematical propagator (e.g., SGP4 for orbital tracking, or fixed-point VWAP for price feeds) must be open-sourced and runnable locally without network access once the raw input file is retrieved.

---

## 4. Minimal Reference Implementation: Level B Price Oracle

The following contract demonstrates how any standard BSC price oracle achieves **SRO-1 Level B compliance** with fewer than 30 lines of code:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IContentAddressedRegistry {
    function isRegistered(bytes32 rawDataHash) external view returns (bool);
}

/// @title SRO1LevelBPriceFeed
/// @notice Price oracle compliant with SRO-1 Level B: Input Committed & Content Addressed.
contract SRO1LevelBPriceFeed {
    IContentAddressedRegistry public immutable registry;

    struct AttestedPrice {
        uint256 priceUsd;
        uint64 timestamp;
        bytes32 rawTickBatchHash; // SRO-1 Level A: Raw exchange ticks digest
    }

    event PriceUpdated(uint256 price, uint64 timestamp, bytes32 indexed rawTickBatchHash);

    constructor(address registryAddress) {
        registry = IContentAddressedRegistry(registryAddress);
    }

    function postPrice(AttestedPrice calldata report, bytes calldata signature) external {
        // SRO-1 Level B: Ensure raw data is committed on-chain and retrievable on Greenfield
        require(registry.isRegistered(report.rawTickBatchHash), "SRO1: UnregisteredRawInput");

        // Verify reporter signature over (price, timestamp, rawTickBatchHash)...
        emit PriceUpdated(report.priceUsd, report.timestamp, report.rawTickBatchHash);
    }
}
```

---

## 5. Explicit Non-Goals (规范明确不提供的性质)

To ensure cryptographic and commercial integrity, SRO-1 explicitly documents what this architecture **DOES NOT** provide:

1. **Consistency $\neq$ Ground Truth**:  
   Recomputing a deterministic function proves that the reporter executed the declared algorithm on the declared input. It **does not prove the input was objectively true in the physical world**. If an attester feeds forged sensor logs that match SGP4 ephemeris, the math will recompute cleanly.
2. **Zero Secret Entropy / Unpredictability**:  
   Deterministic public functions generate zero cryptographic entropy. Satellite Doppler curves and TLE coordinates are publicly computable months in advance. SRO-1 feeds must never be used as unbiasable random beacons.
3. **No Proof of Physical Hardware**:  
   A script running in a cloud data center with public TLE data produces attestations mathematically identical to a physical $10,000 parabolic dish antenna. SRO-1 proves mathematical consistency, not physical hardware presence.
4. **No Transaction Ordering Priority**:  
   SRO-1 attestations are data points on a ledger. They carry no block builder sequencing priority and cannot eliminate MEV sandwich attacks on their own.
