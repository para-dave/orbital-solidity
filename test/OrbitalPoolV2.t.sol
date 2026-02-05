// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/OrbitalPoolV2.sol";
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

contract OrbitalPoolV2Test is Test {
    using FixedPointMath for uint256;

    OrbitalPoolV2 pool;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    address[] tokens;

    address alice = address(0x1);
    address bob = address(0x2);

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
        pool = new OrbitalPoolV2(tokens);

        // Mint tokens to test users
        token0.mint(alice, 1_000_000 * ONE);
        token1.mint(alice, 1_000_000 * ONE);
        token2.mint(alice, 1_000_000 * ONE);

        token0.mint(bob, 1_000_000 * ONE);
        token1.mint(bob, 1_000_000 * ONE);
        token2.mint(bob, 1_000_000 * ONE);
    }

    // ============ Phase 1: Foundation Tests ============

    function testCreateInteriorTick() public {
        uint256 r = 10_000 * ONE;
        uint256 k = 0; // Interior tick

        uint256 tickId = pool.createTick(r, k);

        (uint256 tickR, uint256 tickK, OrbitalPoolV2.TickType tickType, , ) = pool.getTickInfo(tickId);

        assertEq(tickId, 0, "First tick should have ID 0");
        assertEq(tickR, r, "Radius should match");
        assertEq(tickK, k, "K should be 0 for interior");
        assertTrue(tickType == OrbitalPoolV2.TickType.Interior, "Should be interior tick");
    }

    function testCreateBoundaryTick() public {
        uint256 r = 10_000 * ONE;
        uint256 k = 5_000 * ONE;

        uint256 tickId = pool.createTick(r, k);

        (uint256 tickR, uint256 tickK, OrbitalPoolV2.TickType tickType, , ) = pool.getTickInfo(tickId);

        assertEq(tickR, r, "Radius should match");
        assertEq(tickK, k, "K should match");
        assertTrue(tickType == OrbitalPoolV2.TickType.Boundary, "Should be boundary tick");
    }

    function testAddLiquidityFirstLP() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        vm.startPrank(alice);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0]);
        token1.approve(address(pool), amounts[1]);
        token2.approve(address(pool), amounts[2]);

        uint256 shares = pool.addLiquidity(tickId, amounts);

        vm.stopPrank();

        assertTrue(shares > 0, "Should receive shares");
        assertEq(pool.getLPShares(tickId, alice), shares, "Shares should be tracked");

        (, , , uint256 totalShares, uint256[] memory reserves) = pool.getTickInfo(tickId);
        assertEq(totalShares, shares, "Total shares should match");
        assertEq(reserves[0], amounts[0], "Reserve 0 should match");
        assertEq(reserves[1], amounts[1], "Reserve 1 should match");
        assertEq(reserves[2], amounts[2], "Reserve 2 should match");
    }

    function testAddLiquiditySecondLP() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        // Alice adds first
        vm.startPrank(alice);
        uint256[] memory amounts1 = new uint256[](3);
        amounts1[0] = 10_000 * ONE;
        amounts1[1] = 10_000 * ONE;
        amounts1[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts1[0]);
        token1.approve(address(pool), amounts1[1]);
        token2.approve(address(pool), amounts1[2]);

        uint256 sharesAlice = pool.addLiquidity(tickId, amounts1);
        vm.stopPrank();

        // Bob adds second
        vm.startPrank(bob);
        uint256[] memory amounts2 = new uint256[](3);
        amounts2[0] = 5_000 * ONE;
        amounts2[1] = 5_000 * ONE;
        amounts2[2] = 5_000 * ONE;

        token0.approve(address(pool), amounts2[0]);
        token1.approve(address(pool), amounts2[1]);
        token2.approve(address(pool), amounts2[2]);

        uint256 sharesBob = pool.addLiquidity(tickId, amounts2);
        vm.stopPrank();

        assertTrue(sharesBob > 0, "Bob should receive shares");
        assertTrue(sharesBob < sharesAlice, "Bob should receive fewer shares (proportional)");

        uint256 expectedRatio = amounts2[0].div(amounts1[0]);
        uint256 actualRatio = sharesBob.div(sharesAlice);

        // Allow small tolerance for rounding
        uint256 delta = expectedRatio > actualRatio ? expectedRatio - actualRatio : actualRatio - expectedRatio;
        assertTrue(delta < ONE / 1000, "Ratio should be approximately 0.5");
    }

    function testAddLiquidityIgnoresExcessAmounts() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        // Alice adds first
        vm.startPrank(alice);
        uint256[] memory amounts1 = new uint256[](3);
        amounts1[0] = 10_000 * ONE;
        amounts1[1] = 10_000 * ONE;
        amounts1[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts1[0]);
        token1.approve(address(pool), amounts1[1]);
        token2.approve(address(pool), amounts1[2]);
        pool.addLiquidity(tickId, amounts1);
        vm.stopPrank();

        // Bob provides an "excess" amount of token0; pool should only pull proportional amounts.
        vm.startPrank(bob);
        uint256[] memory maxAmounts = new uint256[](3);
        maxAmounts[0] = 6_000 * ONE;
        maxAmounts[1] = 5_000 * ONE;
        maxAmounts[2] = 5_000 * ONE;

        uint256 b0Before = token0.balanceOf(bob);
        uint256 b1Before = token1.balanceOf(bob);
        uint256 b2Before = token2.balanceOf(bob);

        token0.approve(address(pool), maxAmounts[0]);
        token1.approve(address(pool), maxAmounts[1]);
        token2.approve(address(pool), maxAmounts[2]);

        pool.addLiquidity(tickId, maxAmounts);
        vm.stopPrank();

        uint256 b0After = token0.balanceOf(bob);
        uint256 b1After = token1.balanceOf(bob);
        uint256 b2After = token2.balanceOf(bob);

        // min ratio is 0.5, so expected pulled is 5k of each token (not 6k of token0).
        assertEq(b0Before - b0After, 5_000 * ONE, "Pulled token0 should be proportional");
        assertEq(b1Before - b1After, 5_000 * ONE, "Pulled token1 should be proportional");
        assertEq(b2Before - b2After, 5_000 * ONE, "Pulled token2 should be proportional");

        (, , , , uint256[] memory reserves) = pool.getTickInfo(tickId);
        assertEq(reserves[0], 15_000 * ONE, "Reserves scale by 1.5x");
        assertEq(reserves[1], 15_000 * ONE, "Reserves scale by 1.5x");
        assertEq(reserves[2], 15_000 * ONE, "Reserves scale by 1.5x");
    }

    function testAddLiquidityRejectsSingleSided() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        // Alice adds initial liquidity
        vm.startPrank(alice);
        uint256[] memory amounts1 = new uint256[](3);
        amounts1[0] = 10_000 * ONE;
        amounts1[1] = 10_000 * ONE;
        amounts1[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts1[0]);
        token1.approve(address(pool), amounts1[1]);
        token2.approve(address(pool), amounts1[2]);

        pool.addLiquidity(tickId, amounts1);
        vm.stopPrank();

        // Bob tries to add liquidity with only one token
        vm.startPrank(bob);
        uint256[] memory amounts2 = new uint256[](3);
        amounts2[0] = 5_000 * ONE;
        amounts2[1] = 0;
        amounts2[2] = 0;

        token0.approve(address(pool), amounts2[0]);

        vm.expectRevert();
        pool.addLiquidity(tickId, amounts2);
        vm.stopPrank();
    }

    function testRemoveLiquidity() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        vm.startPrank(alice);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0]);
        token1.approve(address(pool), amounts[1]);
        token2.approve(address(pool), amounts[2]);

        uint256 shares = pool.addLiquidity(tickId, amounts);

        // Remove half the liquidity
        uint256 sharesToRemove = shares / 2;
        uint256 balanceBefore0 = token0.balanceOf(alice);
        uint256 balanceBefore1 = token1.balanceOf(alice);
        uint256 balanceBefore2 = token2.balanceOf(alice);

        uint256[] memory withdrawn = pool.removeLiquidity(tickId, sharesToRemove);

        uint256 balanceAfter0 = token0.balanceOf(alice);
        uint256 balanceAfter1 = token1.balanceOf(alice);
        uint256 balanceAfter2 = token2.balanceOf(alice);

        vm.stopPrank();

        // Check balances increased
        assertEq(balanceAfter0 - balanceBefore0, withdrawn[0], "Should receive token 0");
        assertEq(balanceAfter1 - balanceBefore1, withdrawn[1], "Should receive token 1");
        assertEq(balanceAfter2 - balanceBefore2, withdrawn[2], "Should receive token 2");

        // Check approximately half of deposits
        uint256 expectedAmount = amounts[0] / 2;
        uint256 delta = withdrawn[0] > expectedAmount ? withdrawn[0] - expectedAmount : expectedAmount - withdrawn[0];
        assertTrue(delta < ONE * 10, "Should receive approximately half");
    }

    function testSwapBasic() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        // Add liquidity
        vm.startPrank(alice);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0]);
        token1.approve(address(pool), amounts[1]);
        token2.approve(address(pool), amounts[2]);

        pool.addLiquidity(tickId, amounts);
        vm.stopPrank();

        // Bob swaps
        vm.startPrank(bob);
        uint256 amountIn = 100 * ONE;
        token0.approve(address(pool), amountIn);

        uint256 balanceBefore = token1.balanceOf(bob);
        uint256 amountOut = pool.swap(0, amountIn, 1, 0);
        uint256 balanceAfter = token1.balanceOf(bob);

        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, amountOut, "Should receive output tokens");
        assertTrue(amountOut > 0, "Should receive some output");
        assertTrue(amountOut < amountIn, "Output should be less than input (with fee)");
    }

    function testSwapSkipsEmptyLargestTick() public {
        // Create an empty interior tick with huge r (should be ignored)
        pool.createTick(100_000 * ONE, 0);

        // Add liquidity to a boundary tick so there are no interior ticks with liquidity
        // Use a valid boundary (k/r must be >= sqrt(n)-1 for the equal-point init used in tests)
        uint256 boundaryTickId = pool.createTick(10_000 * ONE, 9_000 * ONE);

        vm.startPrank(alice);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0]);
        token1.approve(address(pool), amounts[1]);
        token2.approve(address(pool), amounts[2]);
        pool.addLiquidity(boundaryTickId, amounts);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 amountIn = 100 * ONE;
        token0.approve(address(pool), amountIn);
        uint256 amountOut = pool.swap(0, amountIn, 1, 0);
        vm.stopPrank();

        assertTrue(amountOut > 0, "Should swap using non-empty tick");
    }

    function testSphereInvariantMaintained() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        // Add liquidity
        vm.startPrank(alice);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0]);
        token1.approve(address(pool), amounts[1]);
        token2.approve(address(pool), amounts[2]);

        pool.addLiquidity(tickId, amounts);
        vm.stopPrank();

        // Check invariant before trade
        bool invariantBefore = pool.checkInvariant(tickId);
        assertTrue(invariantBefore, "Invariant should hold before trade");

        // Execute swap
        vm.startPrank(bob);
        uint256 amountIn = 100 * ONE;
        token0.approve(address(pool), amountIn);
        pool.swap(0, amountIn, 1, 0);
        vm.stopPrank();

        // Check invariant after trade
        bool invariantAfter = pool.checkInvariant(tickId);
        assertTrue(invariantAfter, "Invariant should hold after trade");
    }

    function testGlobalStateTracking() public {
        uint256 tickId1 = pool.createTick(10_000 * ONE, 0);
        uint256 tickId2 = pool.createTick(5_000 * ONE, 0);

        // Add liquidity to both ticks
        vm.startPrank(alice);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0] * 2);
        token1.approve(address(pool), amounts[1] * 2);
        token2.approve(address(pool), amounts[2] * 2);

        pool.addLiquidity(tickId1, amounts);
        pool.addLiquidity(tickId2, amounts);
        vm.stopPrank();

        // Check global state
        (uint256[] memory totalReserves, uint256 totalR, ) = pool.getGlobalState();

        assertTrue(totalR > 0, "Total R should be positive");
        assertTrue(totalReserves[0] >= amounts[0] * 2, "Total reserves should include both ticks");
    }

    function testGlobalStateIgnoresEmptyTicks() public {
        pool.createTick(10_000 * ONE, 0);
        pool.createTick(5_000 * ONE, 0);

        (uint256[] memory totalReserves, uint256 totalR, uint256 totalRSquared) = pool.getGlobalState();
        assertEq(totalR, 0, "Empty ticks should not count toward totalR");
        assertEq(totalRSquared, 0, "Empty ticks should not count toward totalRSquared");
        assertEq(totalReserves[0], 0, "Empty ticks should not count toward reserves");
        assertEq(totalReserves[1], 0, "Empty ticks should not count toward reserves");
        assertEq(totalReserves[2], 0, "Empty ticks should not count toward reserves");
    }

    function testBoundaryConstraintCheck() public {
        uint256 r = 10_000 * ONE;
        uint256 k = 8_000 * ONE;
        uint256 tickId = pool.createTick(r, k);

        // Add liquidity that is inside the tick (alpha <= k). This init is at the equal price point,
        // so boundary ticks are not necessarily pinned immediately.
        vm.startPrank(alice);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0]);
        token1.approve(address(pool), amounts[1]);
        token2.approve(address(pool), amounts[2]);

        pool.addLiquidity(tickId, amounts);
        vm.stopPrank();

        ( , uint256 tickK, , , uint256[] memory reserves) = pool.getTickInfo(tickId);
        uint256 alpha = 0;
        uint256 oneOverSqrtN = pool.oneOverSqrtN();
        for (uint256 i = 0; i < 3; i++) {
            alpha += reserves[i].mul(oneOverSqrtN);
        }

        assertTrue(alpha <= tickK + 1e15, "Should satisfy alpha <= k");
        assertTrue(!pool.isPinned(tickId), "Should not be pinned at equal point");
    }

    function testMultipleTicksCreation() public {
        uint256 tickId1 = pool.createTick(10_000 * ONE, 0);
        uint256 tickId2 = pool.createTick(5_000 * ONE, 0);
        uint256 tickId3 = pool.createTick(15_000 * ONE, 2_000 * ONE);

        assertEq(pool.getTickCount(), 3, "Should have 3 ticks");
        assertEq(tickId1, 0, "First tick ID");
        assertEq(tickId2, 1, "Second tick ID");
        assertEq(tickId3, 2, "Third tick ID");
    }

    function testGetPrice() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        // Add liquidity
        vm.startPrank(alice);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000 * ONE;
        amounts[1] = 10_000 * ONE;
        amounts[2] = 10_000 * ONE;

        token0.approve(address(pool), amounts[0]);
        token1.approve(address(pool), amounts[1]);
        token2.approve(address(pool), amounts[2]);

        pool.addLiquidity(tickId, amounts);
        vm.stopPrank();

        uint256 price = pool.getPrice(0, 1);

        // With equal reserves, price should be approximately 1.0
        uint256 delta = price > ONE ? price - ONE : ONE - price;
        assertTrue(delta < ONE / 10, "Price should be close to 1.0 with equal reserves");
    }

    function testRevertOnZeroShares() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        vm.startPrank(alice);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0;
        amounts[1] = 0;
        amounts[2] = 0;

        vm.expectRevert();
        pool.addLiquidity(tickId, amounts);

        vm.stopPrank();
    }

    function testRevertOnInsufficientShares() public {
        uint256 tickId = pool.createTick(10_000 * ONE, 0);

        vm.startPrank(alice);

        // Try to remove shares without adding any
        vm.expectRevert();
        pool.removeLiquidity(tickId, 100 * ONE);

        vm.stopPrank();
    }
}
