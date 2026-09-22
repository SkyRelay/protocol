# SkyRelay Protocol v0.3.0 开发者与用户指南 (中文版)

本指南详细介绍在 Commit `e1e8298` 中合入的三个核心功能的使用方法、工作原理与集成代码：
1. **相对论多普勒时间锚 (Relativistic Doppler Time Anchor)**
2. **链上双签作恶罚没猎人 (On-Chain Equivocation Slashing & Bounty)**
3. **自主 AI 空间网关 (Autonomous AI Space Invariant Gateway)**

英文原版请参阅：[NEW-FEATURES-GUIDE.md](./NEW-FEATURES-GUIDE.md)

---

## 一、安装与环境准备

在项目根目录或您的 Node.js / TypeScript 项目中引入 `@skyrelay/core`：

```bash
# 使用 pnpm
pnpm add @skyrelay/core ethers

# 或使用 npm / yarn
npm install @skyrelay/core ethers
```

支持 Node.js 22+ 及现代浏览器 ESM 规范。

---

## 二、功能 1：相对论多普勒时间锚 (Anti-MEV 物理时间基准)

### 1. 解决的痛点
在传统的区块链交互中，节点依赖本机 NTP 时间或区块时间戳（Block Timestamp），极易被验证节点或 MEV 搜索者微调几个区块秒数进行时间抢跑（Time Bandit Attack）。

星链卫星在 550 公里近地轨道（LEO）以 7.56 km/s 高速飞越，根据狭义与广义相对论，其星载原子钟每 24 小时产生约 **-22.7 微秒** 的净相对论时间漂移（动钟变慢主导），并且过顶时刻的多普勒斜率达到 **-4,050 Hz/s**。这一物理特征无法被任何地面黑客伪造。

### 2. 代码调用示例

```typescript
import {
  createRelativisticTimeAnchor,
  netRelativisticDilation,
  tcaDopplerRateHzS,
  KU_DOWNLINK_HZ,
} from "@skyrelay/core";

// 1. 计算相对论漂移参数
const orbitalVelocityKmS = 7.56; // 轨道速度 7.56 km/s
const altitudeKm = 550.0;        // 轨道高度 550 km

const dilation = netRelativisticDilation(orbitalVelocityKmS, altitudeKm);
console.log(`净相对论日漂移: ${dilation.netMicrosecondsPerDay.toFixed(2)} μs/day`);
// 输出: -22.73 μs/day (动钟变慢 -27.5 μs 抵消引力加速 +4.8 μs)

// 2. 计算过顶多普勒斜率 (过零点变化率)
const slope = tcaDopplerRateHzS(orbitalVelocityKmS, altitudeKm, KU_DOWNLINK_HZ);
console.log(`TCA 多普勒拐点斜率: ${slope.toFixed(1)} Hz/s`);
// 输出: 约 -4050.0 Hz/s

// 3. 生成物理防伪时间锚 (Time Anchor)
const anchor = createRelativisticTimeAnchor({
  noradId: 47352,             // 卫星编号 (STARLINK-1008)
  timestampSec: 1789934703,   // 观测时戳
  elevationDeg: 65.2,         // 仰角
  rangeKm: 620.0,             // 斜距
  rangeRateKmS: 0.12,         // 距离变化率
  dopplerHz: -4680,           // 实测多普勒频移
});

console.log("时间锚校验哈希:", anchor.timeAnchorDigestHex);
console.log("相对论膨胀系数:", anchor.dilationFactor);
```

---

## 三、功能 2：链上双签罚没与悬赏 (Equivocation Slashing)

### 1. 机制与收益
若某个中继节点（Operator）在**同一秒内**对相互矛盾的卫星数据进行了两次签名：
- 任何人（Watchtower / 仲裁者 / 社区用户）都可以捕获这两个签名。
- 组装成一份零争议的作恶证明。
- 提交至链上智能合约 `SkyRelayBond.sol` 的 `slashEquivocation(...)` 方法。
- **作恶节点质押的所有 BNB 将被瞬间罚没清零**，其中 **10% ~ 50% 的罚金作为 Bounty（赏金）直接发放给提交者的钱包**！

### 2. 自动化守卫脚本示例 (Watchtower)

```typescript
import {
  evaluateEquivocation,
  formatSlashEquivocationCall,
  type SkyRelayAttestation,
  type Eip712Domain,
} from "@skyrelay/core";
import { ethers } from "ethers";

const domain: Eip712Domain = {
  chainId: 56, // BNB Smart Chain 主网
  verifyingContract: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC",
};

async function inspectIncomingPair(attA: SkyRelayAttestation, sigA: `0x${string}`, attB: SkyRelayAttestation, sigB: `0x${string}`) {
  const evalResult = evaluateEquivocation(attA, sigA, attB, sigB, domain);

  if (evalResult.isSlashable && evalResult.proof) {
    console.log(`🚨 捕获到作恶节点: ${evalResult.proof.operator}`);
    const slashTxData = formatSlashEquivocationCall(evalResult.proof);

    const provider = new ethers.JsonRpcProvider("https://bsc-dataseed.binance.org/");
    const wallet = new ethers.Wallet(process.env.WATCHER_PRIVATE_KEY!, provider);
    const bondContract = new ethers.Contract(
      "0xYourSkyRelayBondContractAddress",
      [
        "function slashEquivocation(tuple(address operator, bytes32 telemetryHash, bytes32 catalogHash, uint32 noradId, int32 elevationMilliDeg, int32 dopplerHz, int32 snrMilliDb, uint32 asn, uint64 timestamp) a, bytes sigA, tuple(address operator, bytes32 telemetryHash, bytes32 catalogHash, uint32 noradId, int32 elevationMilliDeg, int32 dopplerHz, int32 snrMilliDb, uint32 asn, uint64 timestamp) b, bytes sigB) external"
      ],
      wallet
    );

    const tx = await bondContract.slashEquivocation(
      slashTxData.args[0],
      slashTxData.args[1],
      slashTxData.args[2],
      slashTxData.args[3]
    );
    console.log(`⚡️ 罚没交易已发送，交易哈希: ${tx.hash}`);
    await tx.wait();
    console.log("🎉 罚没成功！赏金 BNB 已入账。");
  }
}
```

---

## 四、功能 3：自主 AI 空间网关 (Autonomous AI Space Gateway)

### 1. AI 智能体接入物理世界
`AutonomousAIGateway` 允许 BNB Chain 上的 AI Agent 接入真实的物理宇宙常数：
- 获取特定地理基准站上空实时的天顶卫星轨道几何参数。
- 提取由多个地面站聚合生成的**不可预测、不可偏倚的物理空间真随机熵（Entropy Seed）**。

### 2. AI 智能体调用示例

```typescript
import {
  AutonomousAIGateway,
  parse3le,
  BASELINE_STATIONS,
} from "@skyrelay/core";
import * as fs from "node:fs";

const catalog = [parse3le(fs.readFileSync("./vectors/tle/starlink-1008.txt", "utf8"))];
const aiGateway = new AutonomousAIGateway(catalog);

// AI 查询物理空间状态
const spaceState = aiGateway.querySpaceState({
  noradId: 47352,
  timestampSec: Math.floor(Date.now() / 1000),
  station: BASELINE_STATIONS.VALENTIA_01,
});

// AI 申请多节点物理真随机熵
const entropy = aiGateway.resolvePhysicalEntropy({
  round: 10086n,
  revealedSecrets: [
    "0x1111111111111111111111111111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222222222222222222222222222",
  ],
});

console.log("物理真随机种子 (256-bit Seed):", entropy.seed);
```
