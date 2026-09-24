// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SkyRelayAntiMevSwap} from "../src/SkyRelayAntiMevSwap.sol";

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract SkyRelayAntiMevSwapTest is Test {
    MockToken internal tokenA;
    MockToken internal tokenB;
    SkyRelayAntiMevSwap internal pool;

    address internal t0;
    address internal t1;

    address internal alice = makeAddr("alice");
    address internal victim = makeAddr("victim");
    address internal mevBot = makeAddr("mevBot");

    uint32 internal constant NORAD_ID = 47352;
    int32 internal constant TCA_SLOPE = -4050; // -4050 Hz/s
    int32 internal constant REL_DRIFT = -22; // -22 us/day

    function setUp() public {
        tokenA = new MockToken("Wrapped BNB", "WBNB");
        tokenB = new MockToken("SkyRelay Protocol", "SKYRELAY");

        // Deploy pool with 30 bps (0.3%) fee, 60s max anchor age
        pool = new SkyRelayAntiMevSwap(
            address(tokenA),
            address(tokenB),
            address(0),
            30,
            60
        );

        t0 = pool.token0();
        t1 = pool.token1();

        // Fund Alice (liquidity provider) with abundant reserves on both tokens
        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(alice, 1_000_000 ether);

        // Fund victim and mevBot with abundant reserves on both tokens
        tokenA.mint(victim, 100_000 ether);
        tokenB.mint(victim, 100_000 ether);
        tokenA.mint(mevBot, 500_000 ether);
        tokenB.mint(mevBot, 500_000 ether);

        // Alice provides initial liquidity: 100 of token0 and 100,000 of token1
        vm.startPrank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100 ether, 100_000 ether, 1, alice);
        vm.stopPrank();

        // Approvals for traders
        vm.startPrank(victim);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(mevBot);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _buildAnchor(
        uint64 tsSec,
        uint32 micros,
        int32 slope,
        int32 drift
    ) internal pure returns (SkyRelayAntiMevSwap.RelativisticTimeAnchor memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(NORAD_ID, tsSec, micros, slope, drift)
        );
        return SkyRelayAntiMevSwap.RelativisticTimeAnchor({
            beaconId: 0,
            noradId: NORAD_ID,
            timestampSec: tsSec,
            subsecondMicros: micros,
            tcaDopplerSlopeHzS: slope,
            netDriftUsPerDay: drift,
            anchorDigest: digest
        });
    }

    function test_addAndRemoveLiquidity() public {
        uint256 lpAlice = pool.lpBalanceOf(alice);
        assertGt(lpAlice, 0);
        assertEq(pool.reserve0() + pool.reserve1(), 100 ether + 100_000 ether);

        // Remove 10% of liquidity
        uint256 removeAmount = lpAlice / 10;
        vm.prank(alice);
        (uint256 r0, uint256 r1) = pool.removeLiquidity(removeAmount, 1, 1, alice);

        assertGt(r0, 0);
        assertGt(r1, 0);
        assertEq(pool.lpBalanceOf(alice), lpAlice - removeAmount);
    }

    function test_swapWithValidTimeAnchor() public {
        uint64 currentTs = uint64(block.timestamp);
        SkyRelayAntiMevSwap.RelativisticTimeAnchor memory anchor = _buildAnchor(
            currentTs,
            250_000,
            TCA_SLOPE,
            REL_DRIFT
        );

        uint256 amountIn = 1 ether;
        uint256 expectedOut = pool.getAmountOut(amountIn, pool.reserve0(), pool.reserve1());

        vm.prank(victim);
        uint256 actualOut = pool.swapExactTokensWithAnchor(
            t0,
            t1,
            amountIn,
            expectedOut,
            victim,
            anchor
        );

        assertEq(actualOut, expectedOut);
        assertEq(pool.lastPhysicalTimestampMicros(), uint128(currentTs) * 1_000_000 + 250_000);
    }

    function test_swapRejectsUnphysicalDopplerSlope() public {
        uint64 currentTs = uint64(block.timestamp);
        // Positive slope is unphysical for LEO TCA pass
        SkyRelayAntiMevSwap.RelativisticTimeAnchor memory invalidAnchor = _buildAnchor(
            currentTs,
            100_000,
            1200, // +1200 Hz/s -> invalid!
            REL_DRIFT
        );

        vm.expectRevert(SkyRelayAntiMevSwap.UnphysicalDopplerSlope.selector);
        vm.prank(victim);
        pool.swapExactTokensWithAnchor(
            t0,
            t1,
            1 ether,
            1,
            victim,
            invalidAnchor
        );
    }

    function test_swapRejectsUnphysicalRelativisticDrift() public {
        uint64 currentTs = uint64(block.timestamp);
        // Positive relativistic drift violates Special Relativity for LEO velocity
        SkyRelayAntiMevSwap.RelativisticTimeAnchor memory invalidAnchor = _buildAnchor(
            currentTs,
            100_000,
            TCA_SLOPE,
            15 // +15 us/day -> invalid!
        );

        vm.expectRevert(SkyRelayAntiMevSwap.UnphysicalRelativisticDrift.selector);
        vm.prank(victim);
        pool.swapExactTokensWithAnchor(
            t0,
            t1,
            1 ether,
            1,
            victim,
            invalidAnchor
        );
    }

    function test_antiMevTimeBanditProtection() public {
        uint64 currentTs = uint64(block.timestamp);

        // Victim executes legitimate swap at physical time offset 300,000 microseconds
        SkyRelayAntiMevSwap.RelativisticTimeAnchor memory victimAnchor = _buildAnchor(
            currentTs,
            300_000,
            TCA_SLOPE,
            REL_DRIFT
        );

        vm.prank(victim);
        pool.swapExactTokensWithAnchor(
            t0,
            t1,
            2 ether,
            1,
            victim,
            victimAnchor
        );

        uint128 lastMicros = pool.lastPhysicalTimestampMicros();
        assertEq(lastMicros, uint128(currentTs) * 1_000_000 + 300_000);

        // MEV bot observes victim in mempool, tries to front-run with an earlier physical anchor (offset 200,000 micros)
        // after victim's state is already locked in!
        SkyRelayAntiMevSwap.RelativisticTimeAnchor memory staleMevAnchor = _buildAnchor(
            currentTs,
            200_000,
            TCA_SLOPE,
            REL_DRIFT
        );

        uint128 submittedMicros = uint128(currentTs) * 1_000_000 + 200_000;
        vm.expectRevert(
            abi.encodeWithSelector(
                SkyRelayAntiMevSwap.MEVTimeBanditDetected.selector,
                submittedMicros,
                lastMicros
            )
        );
        vm.prank(mevBot);
        pool.swapExactTokensWithAnchor(
            t0,
            t1,
            10 ether,
            1,
            mevBot,
            staleMevAnchor
        );
    }

    function test_neutralizeSandwichAttackInBatch() public {
        uint64 currentTs = uint64(block.timestamp);

        // MEV Bot attempts a classical sandwich:
        // Tx0: MevBot buys token1 with token0 (frontrun)
        // Tx1: Victim buys token1 with token0
        // Tx2: MevBot sells token1 for token0 (backrun)
        SkyRelayAntiMevSwap.SwapOrder[] memory orders = new SkyRelayAntiMevSwap.SwapOrder[](3);

        orders[0] = SkyRelayAntiMevSwap.SwapOrder({
            trader: mevBot,
            tokenIn: t0,
            tokenOut: t1,
            amountIn: 10 ether,
            minAmountOut: 1,
            anchor: _buildAnchor(currentTs, 100_000, TCA_SLOPE, REL_DRIFT)
        });

        orders[1] = SkyRelayAntiMevSwap.SwapOrder({
            trader: victim,
            tokenIn: t0,
            tokenOut: t1,
            amountIn: 2 ether,
            minAmountOut: 1,
            anchor: _buildAnchor(currentTs, 120_000, TCA_SLOPE, REL_DRIFT)
        });

        orders[2] = SkyRelayAntiMevSwap.SwapOrder({
            trader: mevBot,
            tokenIn: t1,
            tokenOut: t0,
            amountIn: 5_000 ether,
            minAmountOut: 1,
            anchor: _buildAnchor(currentTs, 150_000, TCA_SLOPE, REL_DRIFT)
        });

        // Batch execution detects sandwich pattern and reverts to protect victim
        vm.expectRevert(
            abi.encodeWithSelector(
                SkyRelayAntiMevSwap.MEVSandwichDetected.selector,
                mevBot,
                victim
            )
        );
        pool.executeBatchFairSwaps(orders);
    }

    function test_fairSequencedBatchExecution() public {
        uint64 currentTs = uint64(block.timestamp);

        SkyRelayAntiMevSwap.SwapOrder[] memory orders = new SkyRelayAntiMevSwap.SwapOrder[](2);

        orders[0] = SkyRelayAntiMevSwap.SwapOrder({
            trader: victim,
            tokenIn: t0,
            tokenOut: t1,
            amountIn: 2 ether,
            minAmountOut: 1,
            anchor: _buildAnchor(currentTs, 100_000, TCA_SLOPE, REL_DRIFT)
        });

        orders[1] = SkyRelayAntiMevSwap.SwapOrder({
            trader: alice,
            tokenIn: t1,
            tokenOut: t0,
            amountIn: 500 ether,
            minAmountOut: 1,
            anchor: _buildAnchor(currentTs, 150_000, TCA_SLOPE, REL_DRIFT)
        });

        uint256 executed = pool.executeBatchFairSwaps(orders);
        assertEq(executed, 2);
        assertEq(pool.lastPhysicalTimestampMicros(), uint128(currentTs) * 1_000_000 + 150_000);
    }

    function test_swapWithOnChainBeaconVerification() public {
        MockSkyRelayBeacon mockBeacon = new MockSkyRelayBeacon();
        SkyRelayAntiMevSwap poolWithBeacon = new SkyRelayAntiMevSwap(
            address(tokenA),
            address(tokenB),
            address(mockBeacon),
            30,
            60
        );

        tokenA.mint(alice, 100 ether);
        tokenB.mint(alice, 100_000 ether);
        vm.startPrank(alice);
        tokenA.approve(address(poolWithBeacon), type(uint256).max);
        tokenB.approve(address(poolWithBeacon), type(uint256).max);
        poolWithBeacon.addLiquidity(100 ether, 100_000 ether, 1, alice);
        vm.stopPrank();

        uint64 currentTs = uint64(block.timestamp);
        bytes32 testCatalogHash = keccak256("TEST_CATALOG_V1");

        // Register authentic beacon on mock beacon contract
        mockBeacon.recordMockBeacon(1, NORAD_ID, currentTs, testCatalogHash);

        SkyRelayAntiMevSwap.RelativisticTimeAnchor memory authenticAnchor = SkyRelayAntiMevSwap.RelativisticTimeAnchor({
            beaconId: 1,
            noradId: NORAD_ID,
            timestampSec: currentTs,
            subsecondMicros: 420_000,
            tcaDopplerSlopeHzS: TCA_SLOPE,
            netDriftUsPerDay: REL_DRIFT,
            anchorDigest: testCatalogHash
        });

        vm.startPrank(victim);
        tokenA.approve(address(poolWithBeacon), type(uint256).max);
        tokenB.approve(address(poolWithBeacon), type(uint256).max);
        uint256 out = poolWithBeacon.swapExactTokensWithAnchor(
            poolWithBeacon.token0(),
            poolWithBeacon.token1(),
            1 ether,
            1,
            victim,
            authenticAnchor
        );
        vm.stopPrank();
        assertGt(out, 0);

        // Attempt forged/unrecorded beaconId 999
        SkyRelayAntiMevSwap.RelativisticTimeAnchor memory forgedAnchor = authenticAnchor;
        forgedAnchor.beaconId = 999;

        address p0 = poolWithBeacon.token0();
        address p1 = poolWithBeacon.token1();

        vm.startPrank(mevBot);
        tokenA.approve(address(poolWithBeacon), type(uint256).max);
        tokenB.approve(address(poolWithBeacon), type(uint256).max);
        vm.expectRevert(SkyRelayAntiMevSwap.InvalidAnchorDigest.selector);
        poolWithBeacon.swapExactTokensWithAnchor(
            p0,
            p1,
            1 ether,
            1,
            mevBot,
            forgedAnchor
        );
        vm.stopPrank();
    }
}

contract MockSkyRelayBeacon {
    struct BeaconSummary {
        uint32 noradId;
        uint64 timestamp;
        uint8 quorum;
        bytes32 catalogHash;
        bytes32 signersHash;
    }

    mapping(uint256 => BeaconSummary) public beacons;
    uint256 public totalBeacons;

    function recordMockBeacon(
        uint256 beaconId,
        uint32 noradId,
        uint64 timestamp,
        bytes32 catalogHash
    ) external {
        beacons[beaconId] = BeaconSummary({
            noradId: noradId,
            timestamp: timestamp,
            quorum: 3,
            catalogHash: catalogHash,
            signersHash: keccak256("SIGNERS")
        });
        if (beaconId >= totalBeacons) totalBeacons = beaconId;
    }

    function getBeacon(uint256 beaconId) external view returns (BeaconSummary memory) {
        return beacons[beaconId];
    }
}

