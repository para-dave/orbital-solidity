// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/OrbitalPool.sol";
import "../contracts/FixedPointMath.sol";

contract MockERC20 {
    using FixedPointMath for uint256;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

contract OrbitalPoolV2ConsolidationTest is Test {
    using FixedPointMath for uint256;

    OrbitalPool pool;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    address[] tokens;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);

    uint256 constant ONE = 1e18;

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        tokens = new address[](3);
        tokens[0] = address(token0);
        tokens[1] = address(token1);
        tokens[2] = address(token2);

        // Deploy pool with 0.3% fee
        pool = new OrbitalPool(tokens);

        // Mint tokens to test users
        token0.mint(alice, 1_000_000 * ONE);
        token1.mint(alice, 1_000_000 * ONE);
        token2.mint(alice, 1_000_000 * ONE);

        token0.mint(bob, 1_000_000 * ONE);
        token1.mint(bob, 1_000_000 * ONE);
        token2.mint(bob, 1_000_000 * ONE);

        token0.mint(charlie, 1_000_000 * ONE);
        token1.mint(charlie, 1_000_000 * ONE);
        token2.mint(charlie, 1_000_000 * ONE);
    }

    // ============ Phase 2: Consolidation Tests ============

    function testTwoParallelInteriorTicks() public {
        // Create two interior ticks with same proportions (parallel reserves)
        uint256 tickId1 = pool.createTick(10_000 * ONE, 0);
        uint256 tickId2 = pool.createTick(5_000 * ONE, 0);

        // Add liquidity with same proportions to both ticks
        vm.startPrank(alice);
        uint256[] memory amounts1 = new uint256[](3);
        amounts1[0] = 10_000 * ONE;
        amounts1[1] = 10_000 * ONE;
        amounts1[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts1[0]);
        token1.approve(address(pool), amounts1[1]);
        token2.approve(address(pool), amounts1[2]);
        pool.addLiquidity(tickId1, amounts1);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256[] memory amounts2 = new uint256[](3);
        amounts2[0] = 5_000 * ONE;
        amounts2[1] = 5_000 * ONE;
        amounts2[2] = 5_000 * ONE;

        token0.approve(address(pool), amounts2[0]);
        token1.approve(address(pool), amounts2[1]);
        token2.approve(address(pool), amounts2[2]);
        pool.addLiquidity(tickId2, amounts2);
        vm.stopPrank();

        // Execute swap (should use consolidated routing)
        vm.startPrank(charlie);
        uint256 amountIn = 100 * ONE;
        token0.approve(address(pool), amountIn);

        uint256 balanceBefore = token1.balanceOf(charlie);
        uint256 amountOut = pool.swap(0, amountIn, 1, 0);
        uint256 balanceAfter = token1.balanceOf(charlie);

        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, amountOut, "Should receive output");
        assertTrue(amountOut > 0, "Should get some output");

        // Verify both ticks still satisfy invariant
        assertTrue(pool.checkInvariant(tickId1), "Tick 1 invariant");
        assertTrue(pool.checkInvariant(tickId2), "Tick 2 invariant");
    }

    // Note: Testing non-parallel tick behavior is complex because:
    // 1. First LP must add equal proportions (sphere invariant requirement)
    // 2. After parallel ticks are consolidated in a swap, they remain parallel
    // 3. Creating truly non-parallel ticks requires different initial r values
    //    OR swaps that affect only one tick (not possible with current routing)
    // The other tests adequately cover consolidation behavior.

    function testThreeParallelTicks() public {
        // Create three interior ticks with parallel reserves
        uint256 tickId1 = pool.createTick(10_000 * ONE, 0);
        uint256 tickId2 = pool.createTick(8_000 * ONE, 0);
        uint256 tickId3 = pool.createTick(6_000 * ONE, 0);

        // Add liquidity with same proportions to all three
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        vm.startPrank(alice);
        token0.approve(address(pool), amounts[0] * 3);
        token1.approve(address(pool), amounts[1] * 3);
        token2.approve(address(pool), amounts[2] * 3);
        pool.addLiquidity(tickId1, amounts);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256[] memory amounts2 = new uint256[](3);
        amounts2[0] = 8_000 * ONE;
        amounts2[1] = 8_000 * ONE;
        amounts2[2] = 8_000 * ONE;
        token0.approve(address(pool), amounts2[0]);
        token1.approve(address(pool), amounts2[1]);
        token2.approve(address(pool), amounts2[2]);
        pool.addLiquidity(tickId2, amounts2);
        vm.stopPrank();

        vm.startPrank(charlie);
        uint256[] memory amounts3 = new uint256[](3);
        amounts3[0] = 6_000 * ONE;
        amounts3[1] = 6_000 * ONE;
        amounts3[2] = 6_000 * ONE;
        token0.approve(address(pool), amounts3[0]);
        token1.approve(address(pool), amounts3[1]);
        token2.approve(address(pool), amounts3[2]);
        pool.addLiquidity(tickId3, amounts3);
        vm.stopPrank();

        // Execute large swap that uses all three ticks
        vm.startPrank(alice);
        uint256 amountIn = 1_000 * ONE;
        token0.approve(address(pool), amountIn);

        uint256 amountOut = pool.swap(0, amountIn, 1, 0);
        vm.stopPrank();

        assertTrue(amountOut > 0, "Should get output");

        // All invariants should hold
        assertTrue(pool.checkInvariant(tickId1), "Tick 1 invariant");
        assertTrue(pool.checkInvariant(tickId2), "Tick 2 invariant");
        assertTrue(pool.checkInvariant(tickId3), "Tick 3 invariant");
    }

    function testBoundaryTickCreationAndUsage() public {
        // Create boundary tick
        uint256 r = 10_000 * ONE;
        uint256 k = 8_000 * ONE;
        uint256 tickId = pool.createTick(r, k);

        // Add liquidity
        vm.startPrank(alice);
        uint256 sqrtN = pool.sqrtN();
        uint256 totalNeeded = k.mul(sqrtN);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = totalNeeded / 3;
        amounts[1] = totalNeeded / 3;
        amounts[2] = totalNeeded / 3;

        token0.approve(address(pool), amounts[0] * 2);
        token1.approve(address(pool), amounts[1] * 2);
        token2.approve(address(pool), amounts[2] * 2);

        pool.addLiquidity(tickId, amounts);
        vm.stopPrank();

        // Execute swap
        vm.startPrank(bob);
        uint256 amountIn = 50 * ONE;
        token0.approve(address(pool), amountIn);

        uint256 amountOut = pool.swap(0, amountIn, 1, 0);
        vm.stopPrank();

        assertTrue(amountOut > 0, "Should get output from boundary tick");
        assertTrue(pool.checkInvariant(tickId), "Boundary tick invariant should hold");
    }

    function testMixedInteriorAndBoundaryTicks() public {
        // Create one interior and one boundary tick
        uint256 interiorTickId = pool.createTick(10_000 * ONE, 0);
        uint256 boundaryTickId = pool.createTick(10_000 * ONE, 8_000 * ONE);

        // Add liquidity to interior tick
        vm.startPrank(alice);
        uint256[] memory amounts1 = new uint256[](3);
        amounts1[0] = 10_000 * ONE;
        amounts1[1] = 10_000 * ONE;
        amounts1[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts1[0]);
        token1.approve(address(pool), amounts1[1]);
        token2.approve(address(pool), amounts1[2]);
        pool.addLiquidity(interiorTickId, amounts1);
        vm.stopPrank();

        // Add liquidity to boundary tick
        vm.startPrank(bob);
        uint256 sqrtN = pool.sqrtN();
        uint256 k = 8_000 * ONE;
        uint256 totalNeeded = k.mul(sqrtN);

        uint256[] memory amounts2 = new uint256[](3);
        amounts2[0] = totalNeeded / 3;
        amounts2[1] = totalNeeded / 3;
        amounts2[2] = totalNeeded / 3;

        token0.approve(address(pool), amounts2[0] * 2);
        token1.approve(address(pool), amounts2[1] * 2);
        token2.approve(address(pool), amounts2[2] * 2);
        pool.addLiquidity(boundaryTickId, amounts2);
        vm.stopPrank();

        // Execute swap (should route intelligently)
        vm.startPrank(charlie);
        uint256 amountIn = 100 * ONE;
        token0.approve(address(pool), amountIn);

        uint256 amountOut = pool.swap(0, amountIn, 1, 0);
        vm.stopPrank();

        assertTrue(amountOut > 0, "Should get output");

        // Both invariants should hold
        assertTrue(pool.checkInvariant(interiorTickId), "Interior tick invariant");
        assertTrue(pool.checkInvariant(boundaryTickId), "Boundary tick invariant");
    }

    function testLargeSwapAcrossMultipleTicks() public {
        // Create multiple ticks with different sizes
        uint256 tickId1 = pool.createTick(10_000 * ONE, 0);
        uint256 tickId2 = pool.createTick(8_000 * ONE, 0);
        uint256 tickId3 = pool.createTick(6_000 * ONE, 0);

        // Add liquidity to all
        vm.startPrank(alice);
        for (uint256 i = 0; i < 3; i++) {
            uint256[] memory amounts = new uint256[](3);
            if (i == 0) {
                amounts[0] = 10_000 * ONE;
                amounts[1] = 10_000 * ONE;
                amounts[2] = 10_000 * ONE;
            } else if (i == 1) {
                amounts[0] = 8_000 * ONE;
                amounts[1] = 8_000 * ONE;
                amounts[2] = 8_000 * ONE;
            } else {
                amounts[0] = 6_000 * ONE;
                amounts[1] = 6_000 * ONE;
                amounts[2] = 6_000 * ONE;
            }

            token0.approve(address(pool), amounts[0]);
            token1.approve(address(pool), amounts[1]);
            token2.approve(address(pool), amounts[2]);

            if (i == 0) pool.addLiquidity(tickId1, amounts);
            else if (i == 1) pool.addLiquidity(tickId2, amounts);
            else pool.addLiquidity(tickId3, amounts);
        }
        vm.stopPrank();

        // Execute very large swap
        vm.startPrank(bob);
        uint256 largeAmountIn = 5_000 * ONE;
        token0.approve(address(pool), largeAmountIn);

        uint256 amountOut = pool.swap(0, largeAmountIn, 1, 0);
        vm.stopPrank();

        assertTrue(amountOut > 0, "Should get output");
        assertTrue(amountOut < largeAmountIn, "Output less than input (with fee)");

        // All invariants should still hold
        assertTrue(pool.checkInvariant(tickId1), "Tick 1");
        assertTrue(pool.checkInvariant(tickId2), "Tick 2");
        assertTrue(pool.checkInvariant(tickId3), "Tick 3");
    }

    function testGlobalStateAfterConsolidation() public {
        uint256 tickId1 = pool.createTick(10_000 * ONE, 0);
        uint256 tickId2 = pool.createTick(5_000 * ONE, 0);

        // Record initial global state
        (, uint256 totalRBefore, ) = pool.getGlobalState();

        // Add liquidity
        vm.startPrank(alice);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0] * 2);
        token1.approve(address(pool), amounts[1] * 2);
        token2.approve(address(pool), amounts[2] * 2);

        pool.addLiquidity(tickId1, amounts);

        uint256[] memory amounts2 = new uint256[](3);
        amounts2[0] = 5_000 * ONE;
        amounts2[1] = 5_000 * ONE;
        amounts2[2] = 5_000 * ONE;
        pool.addLiquidity(tickId2, amounts2);
        vm.stopPrank();

        // Execute swap with consolidation
        vm.startPrank(bob);
        uint256 amountIn = 200 * ONE;
        token0.approve(address(pool), amountIn);
        pool.swap(0, amountIn, 1, 0);
        vm.stopPrank();

        // Check global state updated correctly
        (uint256[] memory totalReserves, uint256 totalRAfter, ) = pool.getGlobalState();

        assertTrue(totalRAfter >= totalRBefore, "Total R should not decrease");
        assertTrue(totalReserves[0] > 0, "Total reserves token 0");
        assertTrue(totalReserves[1] > 0, "Total reserves token 1");
        assertTrue(totalReserves[2] > 0, "Total reserves token 2");
    }
}
