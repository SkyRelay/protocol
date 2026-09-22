# SkyRelay Protocol v0.3.0 Developer & Operator Guide

This handbook provides an end-to-end integration and operational guide for the breakthrough capabilities shipped in Commit `e1e8298`:

1. **Relativistic Doppler Time Anchor** (Anti-MEV physical timekeeping)
2. **On-Chain Equivocation Slashing Witness** (Fraud proofs & BNB bounty hunting)
3. **Autonomous AI Space Gateway** (Physical orbital telemetry & cosmic entropy for on-chain AI agents)

---

## 1. Quickstart & Installation

Install the protocol core package and web3 dependencies:

```bash
# Using pnpm
pnpm add @skyrelay/core ethers

# Or using npm / yarn
npm install @skyrelay/core ethers
```

Requires Node.js 22+ (or modern browser ESM runtime).

---

## 2. Relativistic Doppler Time Anchor (Anti-MEV)

### 2.1 The Problem It Solves
Traditional blockchains and DeFi smart contracts rely on validator-reported `block.timestamp` or web2 NTP time servers. Both are vulnerable to:
- **Time-bandit MEV**: Miners and validators manipulating timestamps by a few seconds to front-run or back-run liquidation orders.
- **NTP Spoofing**: Attackers poisoning centralized time servers to desynchronize consensus nodes.

### 2.2 The Physics & Mathematical Invariant
Starlink satellites orbit in Low-Earth Orbit (LEO) at ~550 km altitude with a linear speed of $v \approx 7.56\text{ km/s}$. Under Einstein's theories of relativity:
- **Special Relativity (Kinematic Dilation)**: Moving clocks tick slower:
  $$\Delta t_{\text{kin}} = -\frac{1}{2}\left(\frac{v}{c}\right)^2 \approx -27.5\ \mu\text{s/day}$$
- **General Relativity (Gravitational Dilation)**: Clocks higher in Earth's gravitational potential tick faster:
  $$\Delta t_{\text{grav}} = +\frac{\Delta \Phi}{c^2} \approx +4.8\ \mu\text{s/day}$$
- **Net Relativistic Drift**: 
  $$\Delta t_{\text{net}} \approx -22.7\ \mu\text{s/day}$$

At the Time of Closest Approach (TCA / zero-crossing), the Doppler inflection slope is uniquely defined by orbital mechanics:
$$\left.\frac{df}{dt}\right|_{\text{TCA}} = -\frac{f_0 \cdot v^2}{c \cdot R_0} \approx -4,050\text{ Hz/s}$$

This physical property **cannot be spoofed** by ground-based networks or software emulators.

### 2.3 Integration Code Example

```typescript
import {
  createRelativisticTimeAnchor,
  netRelativisticDilation,
  tcaDopplerRateHzS,
  KU_DOWNLINK_HZ,
} from "@skyrelay/core";

// 1. Calculate relativistic clock parameters for Starlink LEO orbit
const orbitalVelocityKmS = 7.56; // 7.56 km/s
const altitudeKm = 550.0;        // 550 km altitude

const dilation = netRelativisticDilation(orbitalVelocityKmS, altitudeKm);
console.log(`Net relativistic drift: ${dilation.netMicrosecondsPerDay.toFixed(2)} μs/day`);
// Output: -22.73 μs/day (Kinematic slowing dominates gravitational advance)

// 2. Compute the physical Doppler inflection rate at zero-crossing (TCA)
const slope = tcaDopplerRateHzS(orbitalVelocityKmS, altitudeKm, KU_DOWNLINK_HZ);
console.log(`TCA Doppler slope: ${slope.toFixed(1)} Hz/s`);
// Output: ~ -4050.0 Hz/s

// 3. Construct a verifiable Relativistic Time Anchor
const anchor = createRelativisticTimeAnchor({
  noradId: 47352,             // STARLINK-1008
  timestampSec: 1789934703,   // Attestation second
  elevationDeg: 65.2,         // Line-of-sight elevation
  rangeKm: 620.0,             // Slant range
  rangeRateKmS: 0.12,         // Range rate
  dopplerHz: -4680,           // Observed Doppler shift
});

console.log("Time Anchor Digest (Keccak256):", anchor.timeAnchorDigestHex);
console.log("Clock Dilation Factor:", anchor.dilationFactor);
```

---

## 3. On-Chain Equivocation Slashing & Bounty Hunting

### 3.1 Mechanism & Economics
To sign telemetry and earn protocol rewards, SkyRelay operators must bond BNB into the `SkyRelayBond.sol` contract.

If a rogue operator signs two contradictory spatial attestations for the exact same station-second (e.g., claiming to track two different satellites simultaneously, or falsifying Doppler metrics):
1. **Detection**: Any watcher node detects the contradiction off-chain (zero gas cost).
2. **Proof Assembly**: The watcher packages the two signed EIP-712 digests into an `EquivocationProof`.
3. **Execution**: The watcher submits `slashEquivocation(...)` on BNB Chain.
4. **Slashing & Bounty**: The rogue operator's bonded BNB is slashed to zero. The watcher receives `reporterBountyBps` (10%–50% of the slashed bond) **instantly in the same transaction as pure BNB profit**.

### 3.2 Automated Watchtower Bot Example

```typescript
import {
  evaluateEquivocation,
  formatSlashEquivocationCall,
  type SkyRelayAttestation,
  type Eip712Domain,
} from "@skyrelay/core";
import { ethers } from "ethers";

const DOMAIN: Eip712Domain = {
  chainId: 56, // BNB Smart Chain Mainnet (97 for Testnet)
  verifyingContract: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC", // SkyRelayBeacon
};

async function inspectIncomingPair(
  attA: SkyRelayAttestation,
  sigA: `0x${string}`,
  attB: SkyRelayAttestation,
  sigB: `0x${string}`
) {
  // 1. Off-chain zero-gas evaluation
  const result = evaluateEquivocation(attA, sigA, attB, sigB, DOMAIN);

  if (result.isSlashable && result.proof) {
    console.log(`🚨 Equivocation detected from operator: ${result.proof.operator}`);

    // 2. Format on-chain calldata
    const call = formatSlashEquivocationCall(result.proof);

    // 3. Submit transaction to claim the BNB bounty
    const provider = new ethers.JsonRpcProvider("https://bsc-dataseed.binance.org/");
    const signer = new ethers.Wallet(process.env.WATCHER_PRIVATE_KEY!, provider);

    const bondContract = new ethers.Contract(
      "0xSkyRelayBondAddress",
      [
        "function slashEquivocation(tuple(address operator, bytes32 telemetryHash, bytes32 catalogHash, uint32 noradId, int32 elevationMilliDeg, int32 dopplerHz, int32 snrMilliDb, uint32 asn, uint64 timestamp) a, bytes sigA, tuple(address operator, bytes32 telemetryHash, bytes32 catalogHash, uint32 noradId, int32 elevationMilliDeg, int32 dopplerHz, int32 snrMilliDb, uint32 asn, uint64 timestamp) b, bytes sigB) external"
      ],
      signer
    );

    const tx = await bondContract.slashEquivocation(
      call.args[0],
      call.args[1],
      call.args[2],
      call.args[3]
    );

    console.log(`⚡️ Slashing transaction submitted: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log("🎉 Slashing confirmed! BNB Bounty received in your wallet.");
  }
}
```

---

## 4. Autonomous AI Space Invariant Gateway

### 4.1 Grounding On-Chain AI in Physical Reality
Autonomous AI agents deployed on BNB Chain (e.g., ElizaOS agents, autonomous DeFi risk managers, algorithmic gaming bots) are traditionally trapped inside synthetic, easily-manipulated software environments.

`AutonomousAIGateway` bridges autonomous agents directly to physical space:
- **Physical Geometry Telemetry**: Real-time azimuth, elevation, Doppler shift, and line-of-sight status for any satellite pass over any reference ground station.
- **Physical Space Entropy**: Generating unbiasable, unmanipulable 256-bit randomness seeds extracted from physical multi-station microwave downlinks.

### 4.2 Autonomous Agent Integration Example

```typescript
import {
  AutonomousAIGateway,
  parse3le,
  BASELINE_STATIONS,
  type Tle,
} from "@skyrelay/core";
import * as fs from "node:fs";

// 1. Initialize Gateway with verified TLE catalog
const rawTle = fs.readFileSync("./vectors/tle/starlink-1008.txt", "utf8");
const catalog: Tle[] = [parse3le(rawTle)];
const aiGateway = new AutonomousAIGateway(catalog);

// 2. Query real-time physical space telemetry for an AI agent's decision loop
const spaceState = aiGateway.querySpaceState({
  noradId: 47352,                     // Target satellite
  timestampSec: Math.floor(Date.now() / 1000),
  station: BASELINE_STATIONS.VALENTIA_01, // Valentia Island, Ireland
});

console.log(`🤖 AI Agent Space Context:
  Satellite: ${spaceState.satelliteName}
  Visible Overhead: ${spaceState.isOverhead}
  Elevation: ${spaceState.elevationDeg}° | Azimuth: ${spaceState.azimuthDeg}°
  Slant Range: ${spaceState.slantRangeKm} km
  Relativistic Time Anchor: ${spaceState.relativisticTimeAnchor.timeAnchorDigestHex}
`);

// 3. Resolve verified physical entropy seeds for non-deterministic AI decisions
const entropy = aiGateway.resolvePhysicalEntropy({
  round: 10086n,
  revealedSecrets: [
    "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "0x5555555555555555555555555555555555555555555555555555555555555555",
  ],
});

console.log("Physical Space Randomness Seed (256-bit):", entropy.seed);
```

---

## 5. Running Verification Tests

You can verify all three modules locally using the built-in test suites:

```bash
# Clone the repository
git clone https://github.com/SkyRelay/protocol.git
cd protocol

# Install dependencies
pnpm install

# Run all 83 TypeScript core protocol tests
pnpm --filter @skyrelay/core test

# Run individual test suites
node --test --loader ts-node/esm packages/core/test/relativity.test.ts
node --test --loader ts-node/esm packages/core/test/slashing.test.ts
node --test --loader ts-node/esm packages/core/test/ai-gateway.test.ts

# Run all 122 Foundry Solidity smart contract tests
pnpm --filter contracts test
```

---

## 6. Summary of Exported APIs

| Module | Export | Purpose |
| :--- | :--- | :--- |
| **Relativity** | `netRelativisticDilation(v, h)` | Computes net Special + General relativity clock drift in $\mu\text{s/day}$ |
| **Relativity** | `tcaDopplerRateHzS(v, h, f)` | Computes Doppler inflection rate ($\text{Hz/s}$) at zero-crossing |
| **Relativity** | `createRelativisticTimeAnchor(opts)` | Builds verifiable anti-MEV physical time anchor struct |
| **Slashing** | `evaluateEquivocation(a, sA, b, sB, d)` | Checks whether two signed attestations constitute a slashable double-signature |
| **Slashing** | `formatSlashEquivocationCall(proof)` | Prepares canonical calldata for `SkyRelayBond.slashEquivocation` |
| **AI Gateway** | `AutonomousAIGateway` | Query physical space coordinates & extract unbiasable entropy for AI agents |
