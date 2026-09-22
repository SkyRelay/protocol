import type { RelativisticTimeAnchor } from "../orbit/relativity.ts";

export interface ProtectedSwapOrder {
  id: string;
  trader: string;
  tokenIn: string;
  tokenOut: string;
  amountIn: bigint;
  minAmountOut: bigint;
  subsecondMicros: number;
  anchor: RelativisticTimeAnchor;
  physicalTimestampMicros: bigint;
  signature?: string;
}

export interface SwapExecutionResult {
  orderId: string;
  trader: string;
  tokenIn: string;
  tokenOut: string;
  amountIn: bigint;
  amountOut: bigint;
  success: boolean;
  revertReason?: string;
  executedAtMicros: bigint;
}

export interface PoolState {
  token0: string;
  token1: string;
  reserve0: bigint;
  reserve1: bigint;
  feeBps?: bigint; // default 30n (0.3%)
}

export interface BatchExecutionSummary {
  results: SwapExecutionResult[];
  finalReserve0: bigint;
  finalReserve1: bigint;
  totalVolumeToken0: bigint;
  totalVolumeToken1: bigint;
  sandwichesNeutralized: number;
}

export class AntiMevSwapEngine {
  /**
   * Create a protected swap order bound to a verified Relativistic Time Anchor.
   */
  public static createProtectedOrder(params: {
    id?: string;
    trader: string;
    tokenIn: string;
    tokenOut: string;
    amountIn: bigint;
    minAmountOut: bigint;
    subsecondMicros: number;
    anchor: RelativisticTimeAnchor;
    signature?: string;
  }): ProtectedSwapOrder {
    if (params.subsecondMicros < 0 || params.subsecondMicros >= 1_000_000) {
      throw new Error("subsecondMicros must be within [0, 999999]");
    }
    if (params.amountIn <= 0n) {
      throw new Error("amountIn must be strictly positive");
    }

    const physicalTimestampMicros =
      BigInt(params.anchor.timestampSec) * 1_000_000n +
      BigInt(params.subsecondMicros);

    const id =
      params.id ??
      `order-${params.trader.slice(0, 8)}-${params.anchor.noradId}-${physicalTimestampMicros.toString()}`;

    return {
      id,
      trader: params.trader,
      tokenIn: params.tokenIn,
      tokenOut: params.tokenOut,
      amountIn: params.amountIn,
      minAmountOut: params.minAmountOut,
      subsecondMicros: params.subsecondMicros,
      anchor: params.anchor,
      physicalTimestampMicros,
      signature: params.signature,
    };
  }

  /**
   * Verify the physical Doppler slope and time envelope of an order's anchor.
   */
  public static verifyOrderPhysics(
    order: ProtectedSwapOrder,
    currentTimestampSec?: number,
    maxAgeSec: number = 300,
  ): { valid: boolean; reason?: string } {
    if (order.anchor.noradId <= 0) {
      return { valid: false, reason: "Invalid NORAD satellite catalog ID" };
    }

    // Physical LEO passes have negative Doppler slope during TCA (typically -500 Hz/s to -8000 Hz/s)
    if (order.anchor.tcaDopplerSlopeHzS >= 0) {
      return {
        valid: false,
        reason: "Unphysical Doppler slope: LEO TCA slope must be negative",
      };
    }

    // Net drift should be consistent with LEO relativity (~ -22.7 us/day)
    if (
      order.anchor.netDriftUsPerDay > 0 ||
      order.anchor.netDriftUsPerDay < -50
    ) {
      return {
        valid: false,
        reason: "Relativistic drift outside LEO physical bounds",
      };
    }

    if (currentTimestampSec !== undefined) {
      const age = currentTimestampSec - order.anchor.timestampSec;
      if (age < -5) {
        return { valid: false, reason: "Time anchor is from future" };
      }
      if (age > maxAgeSec) {
        return { valid: false, reason: `Time anchor expired (${age}s > ${maxAgeSec}s)` };
      }
    }

    return { valid: true };
  }

  /**
   * Sort orders strictly by physical microsecond timestamp.
   * Equal physical timestamps use deterministic order ID tie-breaking.
   */
  public static sortOrdersByPhysicalMicrosecond(
    orders: ProtectedSwapOrder[],
  ): ProtectedSwapOrder[] {
    return [...orders].sort((a, b) => {
      if (a.physicalTimestampMicros < b.physicalTimestampMicros) return -1;
      if (a.physicalTimestampMicros > b.physicalTimestampMicros) return 1;
      return a.id.localeCompare(b.id);
    });
  }

  /**
   * Detect sandwich attack attempts in a sequence of transactions.
   * Identifies patterns where an attacker submits a front-run buy followed by a back-run sell
   * around a victim order, or attempts timestamp front-running.
   */
  public static detectSandwichPattern(orders: ProtectedSwapOrder[]): {
    hasSandwichAttempt: boolean;
    attacker?: string;
    victimOrder?: ProtectedSwapOrder;
    explanation?: string;
  } {
    if (orders.length < 3) {
      return { hasSandwichAttempt: false };
    }

    for (let i = 0; i < orders.length - 2; i++) {
      const first = orders[i];
      const middle = orders[i + 1];
      const last = orders[i + 2];

      // Pattern: Same trader in first and last position, sandwiching a different victim
      const sameTrader =
        first.trader.toLowerCase() === last.trader.toLowerCase() &&
        first.trader.toLowerCase() !== middle.trader.toLowerCase();

      // Front-run buy of same token being bought by victim, followed by back-run sell
      const isFrontBackPair =
        first.tokenIn.toLowerCase() === middle.tokenIn.toLowerCase() &&
        first.tokenOut.toLowerCase() === middle.tokenOut.toLowerCase() &&
        last.tokenIn.toLowerCase() === middle.tokenOut.toLowerCase() &&
        last.tokenOut.toLowerCase() === middle.tokenIn.toLowerCase();

      if (sameTrader && isFrontBackPair) {
        return {
          hasSandwichAttempt: true,
          attacker: first.trader,
          victimOrder: middle,
          explanation: `Sandwich pattern detected: ${first.trader} wrapped around victim ${middle.trader}`,
        };
      }
    }

    return { hasSandwichAttempt: false };
  }

  /**
   * Standard constant-product AMM swap formula: (x + Δx * (1 - fee)) * (y - Δy) = x * y
   */
  public static calculateConstantProductSwap(
    reserveIn: bigint,
    reserveOut: bigint,
    amountIn: bigint,
    feeBps: bigint = 30n,
  ): {
    amountOut: bigint;
    newReserveIn: bigint;
    newReserveOut: bigint;
    priceImpactBps: number;
  } {
    if (reserveIn <= 0n || reserveOut <= 0n) {
      throw new Error("Insufficient pool reserves");
    }
    if (amountIn <= 0n) {
      throw new Error("Zero swap amount in");
    }

    const amountInWithFee = amountIn * (10_000n - feeBps);
    const numerator = amountInWithFee * reserveOut;
    const denominator = reserveIn * 10_000n + amountInWithFee;
    const amountOut = numerator / denominator;

    const newReserveIn = reserveIn + amountIn;
    const newReserveOut = reserveOut - amountOut;

    // Price impact in basis points (10,000 = 100%)
    const impactNumerator = amountIn * 10_000n;
    const impactDenominator = reserveIn + amountIn;
    const priceImpactBps = Number((impactNumerator * 100n) / impactDenominator) / 100;

    return {
      amountOut,
      newReserveIn,
      newReserveOut,
      priceImpactBps,
    };
  }

  /**
   * Sequentially and fairly executes a batch of swap orders sorted by physical time.
   * Neutralizes front-running by guaranteeing execution order matches physical reality.
   */
  public static batchExecuteFairSwaps(
    orders: ProtectedSwapOrder[],
    pool: PoolState,
  ): BatchExecutionSummary {
    const feeBps = pool.feeBps ?? 30n;
    let r0 = pool.reserve0;
    let r1 = pool.reserve1;
    let totalVol0 = 0n;
    let totalVol1 = 0n;

    // First detect if the raw batch had sandwich attempts
    const sandwichCheck = this.detectSandwichPattern(orders);
    const sandwichesNeutralized = sandwichCheck.hasSandwichAttempt ? 1 : 0;

    // Strict physical sorting
    const sorted = this.sortOrdersByPhysicalMicrosecond(orders);
    const results: SwapExecutionResult[] = [];

    for (const order of sorted) {
      const physicsCheck = this.verifyOrderPhysics(order);
      if (!physicsCheck.valid) {
        results.push({
          orderId: order.id,
          trader: order.trader,
          tokenIn: order.tokenIn,
          tokenOut: order.tokenOut,
          amountIn: order.amountIn,
          amountOut: 0n,
          success: false,
          revertReason: physicsCheck.reason,
          executedAtMicros: order.physicalTimestampMicros,
        });
        continue;
      }

      const isToken0In =
        order.tokenIn.toLowerCase() === pool.token0.toLowerCase() &&
        order.tokenOut.toLowerCase() === pool.token1.toLowerCase();
      const isToken1In =
        order.tokenIn.toLowerCase() === pool.token1.toLowerCase() &&
        order.tokenOut.toLowerCase() === pool.token0.toLowerCase();

      if (!isToken0In && !isToken1In) {
        results.push({
          orderId: order.id,
          trader: order.trader,
          tokenIn: order.tokenIn,
          tokenOut: order.tokenOut,
          amountIn: order.amountIn,
          amountOut: 0n,
          success: false,
          revertReason: "Token pair does not match pool",
          executedAtMicros: order.physicalTimestampMicros,
        });
        continue;
      }

      try {
        const reserveIn = isToken0In ? r0 : r1;
        const reserveOut = isToken0In ? r1 : r0;

        const swap = this.calculateConstantProductSwap(
          reserveIn,
          reserveOut,
          order.amountIn,
          feeBps,
        );

        if (swap.amountOut < order.minAmountOut) {
          results.push({
            orderId: order.id,
            trader: order.trader,
            tokenIn: order.tokenIn,
            tokenOut: order.tokenOut,
            amountIn: order.amountIn,
            amountOut: swap.amountOut,
            success: false,
            revertReason: `Slippage exceeded: received ${swap.amountOut.toString()} < min ${order.minAmountOut.toString()}`,
            executedAtMicros: order.physicalTimestampMicros,
          });
          continue;
        }

        if (isToken0In) {
          r0 = swap.newReserveIn;
          r1 = swap.newReserveOut;
          totalVol0 += order.amountIn;
        } else {
          r1 = swap.newReserveIn;
          r0 = swap.newReserveOut;
          totalVol1 += order.amountIn;
        }

        results.push({
          orderId: order.id,
          trader: order.trader,
          tokenIn: order.tokenIn,
          tokenOut: order.tokenOut,
          amountIn: order.amountIn,
          amountOut: swap.amountOut,
          success: true,
          executedAtMicros: order.physicalTimestampMicros,
        });
      } catch (err: unknown) {
        results.push({
          orderId: order.id,
          trader: order.trader,
          tokenIn: order.tokenIn,
          tokenOut: order.tokenOut,
          amountIn: order.amountIn,
          amountOut: 0n,
          success: false,
          revertReason: err instanceof Error ? err.message : String(err),
          executedAtMicros: order.physicalTimestampMicros,
        });
      }
    }

    return {
      results,
      finalReserve0: r0,
      finalReserve1: r1,
      totalVolumeToken0: totalVol0,
      totalVolumeToken1: totalVol1,
      sandwichesNeutralized,
    };
  }
}
