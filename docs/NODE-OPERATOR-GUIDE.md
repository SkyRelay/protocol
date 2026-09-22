# SkyRelay Node Operator Guide · Channel A (BYOD)

**Comprehensive technical handbook for connecting local Starlink phased-array terminals to the SkyRelay low-Earth orbit Doppler attestation network on BNB Smart Chain.**

- **Live Node Portal**: [https://skyrelay.link/nodes](https://skyrelay.link/nodes)
- **Web Guide**: [https://skyrelay.link/nodes/guide](https://skyrelay.link/nodes/guide)
- **Protocol Repository**: [https://github.com/SkyRelay/protocol](https://github.com/SkyRelay/protocol)

---

## 1. Physical Principle & Architecture

SkyRelay does **NOT** use Starlink as a generic internet Wi-Fi proxy. Routing transactions through an ISP is merely Web2 re-routing.

Instead, SkyRelay intercepts and measures **over-the-air RF microwave downlink carrier signals (Ku-band 11.325 GHz)** broadcast by low-Earth orbit satellites moving at 7.6 km/s at ~550 km altitude.

```
       [ Starlink Satellite (NORAD 58921) ]
                  \  v = 7.6 km/s
                   \
                    \ Ku-band 11.325 GHz Microwave Carrier
                     \ (Doppler S-curve: Δf = -f₀ · vᵣ / c)
                      ▼
        [ User Phased-Array Dish ]
           (Mini / Standard / Flat HP)
                      |
                      | Local LAN (Unencrypted gRPC)
                      ▼
           192.168.100.1:9200
                      |
        [ SkyRelay Station Daemon ]
           (SGP4 Celestrak TLE Invariant Check)
                      |
                      | EIP-712 Attestation Digest
                      ▼
           [ BNB Smart Chain (BSC) ]
        (Multi-Station Quorum & Automated Gas Refund)
```

### Key Invariants:
1. **Geometric Velocity**: Relative velocity between an orbital satellite and a fixed ground observer produces a deterministic Doppler S-curve ($\pm 25\text{ kHz}$).
2. **Physical Residual Tolerance**: Measured carrier frequency shift must match the theoretical SGP4 orbital propagation within $|\Delta f_{\text{obs}} - \Delta f_{\text{theo}}| < 12.0\text{ Hz}$.
3. **No Hardware Modification**: SpaceX user terminals natively expose a read-only gRPC telemetry service on the local subnet (`192.168.100.1:9200`). No jailbreaking or custom firmware is required.

---

## 2. Hardware Compatibility Matrix

| Hardware Model | Power Requirements | Interface / Cable | Compatibility Status |
| :--- | :--- | :--- | :--- |
| **Starlink Mini** | 12V – 48V DC (20W – 40W) | Integrated RJ-45 Ethernet port | **Native / Recommended** (Ideal for remote / off-grid) |
| **Starlink Standard Gen 3** | 100V – 240V AC | Dual RJ-45 LAN ports on router | **Native Plug & Play** |
| **Starlink Standard Actuated Gen 2** | 100V – 240V AC | Requires Starlink Ethernet Adapter | **Fully Supported via Adapter** |
| **Starlink Flat High Performance** | 100V – 240V AC | High-bandwidth gigabit Ethernet | **Native High-Precision Quorum** |

---

## 3. Quick-Start Instructions (3 Steps)

### Step 1: Verify Local Subnet Reachability
Connect your node computer (Raspberry Pi, industrial mini PC, or desktop) to the Starlink LAN. Verify ping to the dish gateway:

```bash
ping 192.168.100.1
```

You can also run the interactive diagnostic simulator on [skyrelay.link/nodes](https://skyrelay.link/nodes) to test gRPC socket connectivity.

### Step 2: Clone Protocol Repository
Ensure Node.js 20+ and pnpm are installed:

```bash
git clone https://github.com/SkyRelay/protocol.git
cd protocol
pnpm install
```

### Step 3: Launch Station Daemon
Run the station daemon with your custom call sign and BSC operator payout address:

```bash
pnpm run node:start \
  --dish-ip=192.168.100.1:9200 \
  --station=YOUR_STATION_CALLSIGN \
  --operator=YOUR_BSC_WALLET_ADDRESS \
  --interval=60
```

#### Command Arguments:
- `--dish-ip`: Starlink dish local gRPC socket (default: `192.168.100.1:9200`).
- `--station`: Custom station identifier (e.g. `ALPHA-STATION-01`).
- `--operator`: Your BSC wallet address for receiving automated gas refunds and verification yield.
- `--interval`: Orbital ephemeris synchronization cadence in seconds (default: `60`).

---

## 4. Economic Incentives & Gas Subsidies

SkyRelay permanently allocates **1.25% of total supply** into the **Hardware & Verification Reserve**:

1. **Automated Gas Reimbursement**: When your station's EIP-712 signature is committed to a BSC block as part of a multi-station quorum, the protocol vault executes an automated gas refund directly to your operator address.
2. **Verification Yield**: Active stations maintaining uptime and continuous SGP4 pass tracking share in the protocol's ongoing verification incentives.
3. **Channel B Hardware Grants**: Users without hardware can apply for one of 50 subsidized Starlink Mini terminals via Channel B on [skyrelay.link/nodes](https://skyrelay.link/nodes).

---

## 5. Security & Safety Principles

- **Read-Only Telemetry**: The daemon queries only azimuth, elevation, SNR, and downlink lock metrics. It never accesses, intercepts, or logs personal network traffic.
- **Audited Smart Contracts**: EIP-712 attestation hashes and quorum proofs are verified deterministically by Solidity contracts on BSC mainnet.
- **Open-Source Code**: All daemon and contract source code is publicly audited and available at [github.com/SkyRelay/protocol](https://github.com/SkyRelay/protocol).
