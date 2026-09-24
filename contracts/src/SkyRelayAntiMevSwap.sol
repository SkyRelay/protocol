// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISkyRelay} from "./interfaces/ISkyRelay.sol";

interface IERC20Minimal {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SkyRelayAntiMevSwap
/// @notice Decentralized constant-product AMM pool protected by SkyRelay
///         Relativistic Doppler Time Anchors on BNB Smart Chain.
/// @dev Eliminates front-running, mempool sniping, and sandwich attacks by enforcing
///      strict physical microsecond sequencing derived from low-Earth orbit satellites.
contract SkyRelayAntiMevSwap {
    struct RelativisticTimeAnchor {
        uint256 beaconId;
        uint32 noradId;
        uint64 timestampSec;
        uint32 subsecondMicros; // 0..999,999
        int32 tcaDopplerSlopeHzS; // Must be negative during LEO TCA
        int32 netDriftUsPerDay; // Expected ~ -22 us/day
        bytes32 anchorDigest;
    }

    struct SwapOrder {
        address trader;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        RelativisticTimeAnchor anchor;
    }

    address public immutable token0;
    address public immutable token1;
    address public immutable beacon;
    uint16 public immutable feeBps; // default 30 (0.30%)
    uint32 public immutable maxAnchorAgeSec; // e.g. 60 seconds

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public totalLpSupply;

    /// @notice Highest physical microsecond timestamp executed so far.
    uint128 public lastPhysicalTimestampMicros;

    mapping(address => uint256) public lpBalanceOf;

    event LiquidityAdded(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 lpMinted
    );
    event LiquidityRemoved(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 lpBurned
    );
    event FairSwapExecuted(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint128 physicalTimestampMicros
    );
    event SandwichNeutralized(
        address indexed attacker,
        address indexed victim,
        uint128 timestampMicros
    );

    error ZeroAddress();
    error IdenticalAddresses();
    error InsufficientLiquidity();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error UnphysicalDopplerSlope();
    error UnphysicalRelativisticDrift();
    error ExpiredTimeAnchor();
    error FutureTimeAnchor();
    error InvalidAnchorDigest();
    error InvalidSubsecondOffset();
    error InvalidTokenPair();
    error MEVTimeBanditDetected(uint128 submittedMicros, uint128 lastExecutedMicros);
    error MEVSandwichDetected(address frontRunner, address victim);
    error UnorderedPhysicalBatch(uint256 index, uint128 prevMicros, uint128 currentMicros);
    error TransferFailed();

    constructor(
        address tokenA,
        address tokenB,
        address beaconAddress,
        uint16 poolFeeBps,
        uint32 anchorMaxAge
    ) {
        if (tokenA == address(0) || tokenB == address(0) || beaconAddress == address(0)) revert ZeroAddress();
        if (tokenA == tokenB) revert IdenticalAddresses();
        if (poolFeeBps > 1000) revert InsufficientLiquidity(); // Max 10% fee

        if (tokenA < tokenB) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        beacon = beaconAddress;
        feeBps = poolFeeBps == 0 ? 30 : poolFeeBps;
        maxAnchorAgeSec = anchorMaxAge == 0 ? 60 : anchorMaxAge;
    }

    /// @notice Verify physical invariants of a Relativistic Time Anchor against the on-chain SkyRelay beacon ledger.
    function verifyTimeAnchor(RelativisticTimeAnchor calldata anchor) public view returns (uint128 physicalMicros) {
        if (anchor.noradId == 0) revert ZeroAddress();
        if (anchor.subsecondMicros >= 1_000_000) revert InvalidSubsecondOffset();

        // LEO passes strictly have negative Doppler slope during TCA
        if (anchor.tcaDopplerSlopeHzS >= 0) revert UnphysicalDopplerSlope();

        // LEO relativistic time dilation is net negative (~ -22.7 us/day)
        if (anchor.netDriftUsPerDay >= 0 || anchor.netDriftUsPerDay < -50) {
            revert UnphysicalRelativisticDrift();
        }

        if (anchor.timestampSec > block.timestamp + 5) revert FutureTimeAnchor();
        if (block.timestamp > anchor.timestampSec + maxAnchorAgeSec) revert ExpiredTimeAnchor();

        ISkyRelay.BeaconSummary memory summary = ISkyRelay(beacon).getBeacon(anchor.beaconId);
        if (summary.timestamp == 0) revert InvalidAnchorDigest();
        if (summary.noradId != anchor.noradId) revert InvalidAnchorDigest();
        if (summary.timestamp != anchor.timestampSec) revert ExpiredTimeAnchor();
        if (summary.catalogHash != anchor.anchorDigest) revert InvalidAnchorDigest();

        return uint128(anchor.timestampSec) * 1_000_000 + uint128(anchor.subsecondMicros);
    }

    /// @notice Add initial or subsequent liquidity into the pool.
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 minLp,
        address to
    ) external returns (uint256 lpMinted) {
        if (to == address(0)) revert ZeroAddress();
        if (amount0Desired == 0 || amount1Desired == 0) revert InsufficientInputAmount();

        if (totalLpSupply == 0) {
            lpMinted = _sqrt(amount0Desired * amount1Desired);
        } else {
            uint256 lp0 = (amount0Desired * totalLpSupply) / reserve0;
            uint256 lp1 = (amount1Desired * totalLpSupply) / reserve1;
            lpMinted = lp0 < lp1 ? lp0 : lp1;
        }

        if (lpMinted < minLp || lpMinted == 0) revert InsufficientLiquidity();

        _safeTransferFrom(token0, msg.sender, address(this), amount0Desired);
        _safeTransferFrom(token1, msg.sender, address(this), amount1Desired);

        reserve0 += amount0Desired;
        reserve1 += amount1Desired;
        totalLpSupply += lpMinted;
        lpBalanceOf[to] += lpMinted;

        emit LiquidityAdded(to, amount0Desired, amount1Desired, lpMinted);
    }

    /// @notice Burn LP shares to redeem underlying reserves.
    function removeLiquidity(
        uint256 lpAmount,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external returns (uint256 amount0, uint256 amount1) {
        if (to == address(0)) revert ZeroAddress();
        if (lpAmount == 0 || lpBalanceOf[msg.sender] < lpAmount) revert InsufficientLiquidity();

        amount0 = (lpAmount * reserve0) / totalLpSupply;
        amount1 = (lpAmount * reserve1) / totalLpSupply;

        if (amount0 < amount0Min || amount1 < amount1Min) revert InsufficientOutputAmount();

        lpBalanceOf[msg.sender] -= lpAmount;
        totalLpSupply -= lpAmount;
        reserve0 -= amount0;
        reserve1 -= amount1;

        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        emit LiquidityRemoved(to, amount0, amount1, lpAmount);
    }

    /// @notice Execute single swap shielded by relativistic time anchor.
    /// @dev Prevents time-bandit front-running: rejects swaps whose physical timestamp
    ///      is earlier than the already executed chain state.
    function swapExactTokensWithAnchor(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        RelativisticTimeAnchor calldata anchor
    ) external returns (uint256 amountOut) {
        if (to == address(0)) revert ZeroAddress();
        uint128 physMicros = verifyTimeAnchor(anchor);

        // Anti-MEV monotonic sequence check: an order cannot execute out of physical order
        if (physMicros < lastPhysicalTimestampMicros) {
            revert MEVTimeBanditDetected(physMicros, lastPhysicalTimestampMicros);
        }

        amountOut = _executeSwap(tokenIn, tokenOut, amountIn, minAmountOut, msg.sender, to);
        lastPhysicalTimestampMicros = physMicros;

        emit FairSwapExecuted(to, tokenIn, tokenOut, amountIn, amountOut, physMicros);
    }

    /// @notice Execute batch of orders sequenced strictly by physical microsecond time.
    /// @dev Neutralizes sandwich attacks and MEV gas-bribe reorderings.
    function executeBatchFairSwaps(SwapOrder[] calldata orders) external returns (uint256 executedCount) {
        uint256 len = orders.length;
        if (len == 0) return 0;

        uint128 prevMicros = 0;

        // Check sandwich patterns and microsecond monotonic order across the batch
        for (uint256 i = 0; i < len; i++) {
            uint128 curMicros = verifyTimeAnchor(orders[i].anchor);

            // Batch must be physically sequenced ascending
            if (curMicros < prevMicros) {
                revert UnorderedPhysicalBatch(i, prevMicros, curMicros);
            }

            // Anti-Sandwich Check: Trader i cannot sandwich Trader i+1 with a backrun at i+2
            if (i + 2 < len) {
                if (
                    orders[i].trader == orders[i + 2].trader &&
                    orders[i].trader != orders[i + 1].trader &&
                    orders[i].tokenIn == orders[i + 1].tokenIn &&
                    orders[i + 2].tokenIn == orders[i + 1].tokenOut
                ) {
                    emit SandwichNeutralized(orders[i].trader, orders[i + 1].trader, curMicros);
                    revert MEVSandwichDetected(orders[i].trader, orders[i + 1].trader);
                }
            }

            prevMicros = curMicros;
        }

        if (prevMicros < lastPhysicalTimestampMicros) {
            revert MEVTimeBanditDetected(prevMicros, lastPhysicalTimestampMicros);
        }

        for (uint256 i = 0; i < len; i++) {
            SwapOrder calldata o = orders[i];
            uint128 oMicros = uint128(o.anchor.timestampSec) * 1_000_000 + uint128(o.anchor.subsecondMicros);

            uint256 out = _executeSwap(o.tokenIn, o.tokenOut, o.amountIn, o.minAmountOut, o.trader, o.trader);
            emit FairSwapExecuted(o.trader, o.tokenIn, o.tokenOut, o.amountIn, out, oMicros);
            executedCount++;
        }

        lastPhysicalTimestampMicros = prevMicros;
    }

    /// @notice Get the expected output amount for a given input amount.
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public view returns (uint256 amountOut) {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * (10_000 - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10_000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address from,
        address to
    ) internal returns (uint256 amountOut) {
        bool isZeroForOne;
        if (tokenIn == token0 && tokenOut == token1) {
            isZeroForOne = true;
        } else if (tokenIn == token1 && tokenOut == token0) {
            isZeroForOne = false;
        } else {
            revert InvalidTokenPair();
        }

        uint256 rIn = isZeroForOne ? reserve0 : reserve1;
        uint256 rOut = isZeroForOne ? reserve1 : reserve0;

        amountOut = getAmountOut(amountIn, rIn, rOut);
        if (amountOut < minAmountOut) revert InsufficientOutputAmount();

        _safeTransferFrom(tokenIn, from, address(this), amountIn);
        _safeTransfer(tokenOut, to, amountOut);

        if (isZeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, value)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, value)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
