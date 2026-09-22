import assert from "node:assert/strict";
import { test } from "node:test";
import { AntiMevSwapEngine } from "../src/dex/fair-swap.ts";
import { createRelativisticTimeAnchor } from "../src/orbit/relativity.ts";

const baseAnchor = createRelativisticTimeAnchor({
  noradId: 47352,
  timestampSec: 1718000000,
  elevationDeg: 45,
  rangeKm: 780,
  rangeRateKmS: 3.2,
  dopplerHz: -12450,
});

const TOKEN_WBNB = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c";
const TOKEN_SKYRELAY = "0x1cde8ED6aa84468BfbEd56dEacC264C7C1bB7777";

test("creates protected orders with exact microsecond sequence", () => {
  const order = AntiMevSwapEngine.createProtectedOrder({
    trader: "0x1111111111111111111111111111111111111111",
    tokenIn: TOKEN_WBNB,
    tokenOut: TOKEN_SKYRELAY,
    amountIn: 1000000000000000000n, // 1 BNB
    minAmountOut: 900000000000000000000n,
    subsecondMicros: 450123,
    anchor: baseAnchor,
  });

  assert.equal(order.subsecondMicros, 450123);
  assert.equal(order.physicalTimestampMicros, 1718000000450123n);
  assert.equal(order.anchor.noradId, 47352);
});

test("enforces physical validity of relativistic anchor", () => {
  const validOrder = AntiMevSwapEngine.createProtectedOrder({
    trader: "0x1111111111111111111111111111111111111111",
    tokenIn: TOKEN_WBNB,
    tokenOut: TOKEN_SKYRELAY,
    amountIn: 1000000000000000000n,
    minAmountOut: 1n,
    subsecondMicros: 100,
    anchor: baseAnchor,
  });

  const check = AntiMevSwapEngine.verifyOrderPhysics(validOrder, 1718000010, 30);
  assert.equal(check.valid, true);

  // Unphysical positive Doppler slope (violates TCA Doppler mechanics)
  const spoofedAnchor = { ...baseAnchor, tcaDopplerSlopeHzS: 1200 };
  const invalidOrder = { ...validOrder, anchor: spoofedAnchor };
  const spoofCheck = AntiMevSwapEngine.verifyOrderPhysics(invalidOrder);
  assert.equal(spoofCheck.valid, false);
  assert.ok(spoofCheck.reason?.includes("Unphysical Doppler slope"));
});

test("sorts orders strictly by physical microsecond timestamp, overriding gas bribes", () => {
  // Victim submits earlier in physical reality (t = 100.120000s)
  const victimOrder = AntiMevSwapEngine.createProtectedOrder({
    id: "victim-order",
    trader: "0xVictim0000000000000000000000000000000001",
    tokenIn: TOKEN_WBNB,
    tokenOut: TOKEN_SKYRELAY,
    amountIn: 5000000000000000000n, // 5 BNB
    minAmountOut: 1n,
    subsecondMicros: 120000,
    anchor: baseAnchor,
  });

  // MEV bot sees victim in mempool, tries to submit order with higher gas price,
  // but its physical satellite sighting is slightly later (t = 100.150000s)
  const mevBotOrder = AntiMevSwapEngine.createProtectedOrder({
    id: "mev-bot-order",
    trader: "0xMevBot00000000000000000000000000000000002",
    tokenIn: TOKEN_WBNB,
    tokenOut: TOKEN_SKYRELAY,
    amountIn: 20000000000000000000n, // 20 BNB frontrun
    minAmountOut: 1n,
    subsecondMicros: 150000,
    anchor: baseAnchor,
  });

  // Even if MEV bot is placed first in the raw batch array (e.g. via block builder bribery)
  const rawBatch = [mevBotOrder, victimOrder];
  const sorted = AntiMevSwapEngine.sortOrdersByPhysicalMicrosecond(rawBatch);

  // Victim MUST be ordered first because 120000 < 150000 microseconds!
  assert.equal(sorted[0].id, "victim-order");
  assert.equal(sorted[1].id, "mev-bot-order");
});

test("detects sandwich attack patterns across multi-order batches", () => {
  const mevBot = "0xMevBot00000000000000000000000000000000002";
  const victim = "0xVictim0000000000000000000000000000000001";

  const frontrun = AntiMevSwapEngine.createProtectedOrder({
    trader: mevBot,
    tokenIn: TOKEN_WBNB,
    tokenOut: TOKEN_SKYRELAY,
    amountIn: 10000000000000000000n,
    minAmountOut: 1n,
    subsecondMicros: 100000,
    anchor: baseAnchor,
  });

  const victimOrder = AntiMevSwapEngine.createProtectedOrder({
    trader: victim,
    tokenIn: TOKEN_WBNB,
    tokenOut: TOKEN_SKYRELAY,
    amountIn: 2000000000000000000n,
    minAmountOut: 1n,
    subsecondMicros: 150000,
    anchor: baseAnchor,
  });

  const backrun = AntiMevSwapEngine.createProtectedOrder({
    trader: mevBot,
    tokenIn: TOKEN_SKYRELAY,
    tokenOut: TOKEN_WBNB,
    amountIn: 10000000000000000000000n,
    minAmountOut: 1n,
    subsecondMicros: 200000,
    anchor: baseAnchor,
  });

  const sandwich = AntiMevSwapEngine.detectSandwichPattern([frontrun, victimOrder, backrun]);
  assert.equal(sandwich.hasSandwichAttempt, true);
  assert.equal(sandwich.attacker, mevBot);
  assert.equal(sandwich.victimOrder?.trader, victim);
});

test("correctly computes constant product swaps and fair execution", () => {
  // Pool: 100 BNB, 100,000 SKYRELAY (1 BNB = 1000 SKYRELAY)
  const pool = {
    token0: TOKEN_WBNB,
    token1: TOKEN_SKYRELAY,
    reserve0: 100000000000000000000n, // 100 ether
    reserve1: 100000000000000000000000n, // 100,000 ether
    feeBps: 30n, // 0.3%
  };

  // Swap 1 BNB -> expecting ~ 987.15 SKYRELAY with 0.3% fee
  const swap = AntiMevSwapEngine.calculateConstantProductSwap(
    pool.reserve0,
    pool.reserve1,
    1000000000000000000n,
    30n,
  );

  // dx = 1e18, dy ~ 987158034397061298933
  assert.ok(swap.amountOut > 980000000000000000000n);
  assert.ok(swap.amountOut < 1000000000000000000000n);
  assert.ok(swap.priceImpactBps > 0.9);
});

test("executes fair batch and neutralizes frontrunning attempts", () => {
  const pool = {
    token0: TOKEN_WBNB,
    token1: TOKEN_SKYRELAY,
    reserve0: 100000000000000000000n, // 100 BNB
    reserve1: 100000000000000000000000n, // 100,000 SKYRELAY
    feeBps: 30n,
  };

  // Victim submits at t = 100.100s
  const victim = AntiMevSwapEngine.createProtectedOrder({
    id: "victim-trade",
    trader: "0xVictim0000000000000000000000000000000001",
    tokenIn: TOKEN_WBNB,
    tokenOut: TOKEN_SKYRELAY,
    amountIn: 2000000000000000000n, // 2 BNB
    minAmountOut: 1900000000000000000000n,
    subsecondMicros: 100000,
    anchor: baseAnchor,
  });

  // Bot tries to cut in front at t = 100.150s
  const bot = AntiMevSwapEngine.createProtectedOrder({
    id: "bot-trade",
    trader: "0xMevBot00000000000000000000000000000000002",
    tokenIn: TOKEN_WBNB,
    tokenOut: TOKEN_SKYRELAY,
    amountIn: 10000000000000000000n, // 10 BNB
    minAmountOut: 1n,
    subsecondMicros: 150000,
    anchor: baseAnchor,
  });

  // Submitting in reverse order: [bot, victim]
  const batch = AntiMevSwapEngine.batchExecuteFairSwaps([bot, victim], pool);

  assert.equal(batch.results.length, 2);
  // Victim must execute first!
  assert.equal(batch.results[0].orderId, "victim-trade");
  assert.equal(batch.results[0].success, true);

  // Bot executes second!
  assert.equal(batch.results[1].orderId, "bot-trade");
  assert.equal(batch.results[1].success, true);
});
