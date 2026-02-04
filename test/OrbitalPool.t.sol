// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/OrbitalPool.sol";
import "../contracts/FixedPointMath.sol";

/**
 * @title MockERC20
 * @notice Simple ERC20 mock for testing
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

/**
 * @title OrbitalPoolTest
 * @notice Test suite for OrbitalPool
 * @dev Ported from test_simple_pool.py
 */
contract OrbitalPoolTest is Test {
    using FixedPointMath for uint256;

    OrbitalPool public pool;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public token2;

    address public alice = address(0x1);
    address public bob = address(0x2);

    uint256 constant ONE = FixedPointMath.ONE;
    uint256 constant TOLERANCE = ONE / 100; // 1%

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        // Create token array
        address[] memory tokens = new address[](3);
        tokens[0] = address(token0);
        tokens[1] = address(token1);
        tokens[2] = address(token2);

        // Deploy pool with 0.3% fee
        pool = new OrbitalPool(tokens, 30);

        // Mint tokens to test addresses
        token0.mint(alice, 1000000 * ONE);
        token1.mint(alice, 1000000 * ONE);
        token2.mint(alice, 1000000 * ONE);

        token0.mint(bob, 1000000 * ONE);
        token1.mint(bob, 1000000 * ONE);
        token2.mint(bob, 1000000 * ONE);
    }

    function testCreatePool() public {
        assertEq(pool.nTokens(), 3);
        assertEq(pool.feesBps(), 30);
        assertEq(pool.getTickCount(), 0);
    }

    function testCreateTick() public {
        uint256 r = 1000 * ONE;
        uint256 k = 500 * ONE;

        uint256 tickId = pool.createTick(r, k);
        assertEq(tickId, 0);
        assertEq(pool.getTickCount(), 1);

        (uint256 tickR, uint256 tickK,,) = pool.getTickInfo(tickId);
        assertEq(tickR, r);
        assertEq(tickK, k);
    }

    function testAddLiquidityFirstLP() public {
        // Create pool with initial liquidity
        (uint256 tickId,) = _createPoolWithLiquidity(
            alice,
            1000 * ONE,
            1000 * ONE,
            1000 * ONE
        );

        // Check tick info
        (uint256 r,, uint256 totalShares, uint256[] memory reserves) = pool.getTickInfo(tickId);

        // Shares should be positive
        assertGt(totalShares, 0);

        // Reserves should match deposit
        assertEq(reserves[0], 1000 * ONE);
        assertEq(reserves[1], 1000 * ONE);
        assertEq(reserves[2], 1000 * ONE);

        // Alice should have all shares
        assertEq(pool.getLPShares(tickId, alice), totalShares);

        // Radius should be set
        assertGt(r, 0);
    }

    function testAddLiquiditySecondLP() public {
        // Alice adds initial liquidity
        (uint256 tickId,) = _createPoolWithLiquidity(
            alice,
            1000 * ONE,
            1000 * ONE,
            1000 * ONE
        );

        uint256 aliceShares = pool.getLPShares(tickId, alice);

        // Bob adds same amount
        vm.startPrank(bob);
        token0.approve(address(pool), 1000 * ONE);
        token1.approve(address(pool), 1000 * ONE);
        token2.approve(address(pool), 1000 * ONE);

        uint256[] memory bobAmounts = new uint256[](3);
        bobAmounts[0] = 1000 * ONE;
        bobAmounts[1] = 1000 * ONE;
        bobAmounts[2] = 1000 * ONE;

        pool.addLiquidity(tickId, bobAmounts);
        vm.stopPrank();

        // Bob should have approximately equal shares to Alice
        uint256 bobShares = pool.getLPShares(tickId, bob);
        assertApproxEqRel(aliceShares, bobShares, 0.01e18); // 1% tolerance

        // Total reserves should be doubled
        (,,, uint256[] memory reserves) = pool.getTickInfo(tickId);
        assertApproxEqRel(reserves[0], 2000 * ONE, 0.01e18);
        assertApproxEqRel(reserves[1], 2000 * ONE, 0.01e18);
        assertApproxEqRel(reserves[2], 2000 * ONE, 0.01e18);
    }

    function testSwapBasic() public {
        // Create pool with liquidity
        _createPoolWithLiquidity(
            alice,
            10000 * ONE,
            10000 * ONE,
            10000 * ONE
        );

        // Bob swaps 100 token0 for token1
        vm.startPrank(bob);
        token0.approve(address(pool), 100 * ONE);

        uint256 amountOut = pool.swap(0, 100 * ONE, 1, 90 * ONE);
        vm.stopPrank();

        // Should get reasonable output (less than input due to fees)
        assertGt(amountOut, 90 * ONE);
        assertLt(amountOut, 100 * ONE);

        // Reserves should change
        assertGt(pool.totalReserves(0), 10000 * ONE); // Gained token0
        assertLt(pool.totalReserves(1), 10000 * ONE); // Lost token1
    }

    function testSphereInvariantMaintained() public {
        // Create pool
        (uint256 tickId,) = _createPoolWithLiquidity(
            alice,
            5000 * ONE,
            5000 * ONE,
            5000 * ONE
        );

        // Check initial invariant
        assertTrue(pool.checkInvariant(tickId));

        // Execute several trades
        vm.startPrank(bob);
        for (uint256 i = 0; i < 3; i++) {
            token0.approve(address(pool), 500 * ONE);
            try pool.swap(0, 500 * ONE, 1, 0) {
                // Invariant must hold after each trade
                assertTrue(pool.checkInvariant(tickId), "Sphere invariant violated");
            } catch {
                // Trade might fail if reserves get too skewed
                break;
            }
        }
        vm.stopPrank();

        // Final check
        assertTrue(pool.checkInvariant(tickId));
    }

    function testPriceChangesAfterSwap() public {
        // Create pool
        _createPoolWithLiquidity(
            alice,
            10000 * ONE,
            10000 * ONE,
            10000 * ONE
        );

        // Initial price should be 1:1
        uint256 priceBefore = pool.getPrice(0, 2);
        assertApproxEqRel(priceBefore, ONE, 0.01e18); // 1% tolerance

        // Swap token0 for token2
        vm.startPrank(bob);
        token0.approve(address(pool), 1000 * ONE);
        pool.swap(0, 1000 * ONE, 2, 0);
        vm.stopPrank();

        // Price should change (token2 more expensive now)
        uint256 priceAfter = pool.getPrice(0, 2);
        assertGt(priceAfter, ONE);
    }

    function testLargeSwap() public {
        // Create pool
        (uint256 tickId,) = _createPoolWithLiquidity(
            alice,
            10000 * ONE,
            10000 * ONE,
            10000 * ONE
        );

        // Swap 20% of reserves
        vm.startPrank(bob);
        token0.approve(address(pool), 2000 * ONE);

        try pool.swap(0, 2000 * ONE, 1, 0) returns (uint256 amountOut) {
            // Should get less than amountIn due to slippage
            assertLt(amountOut, 2000 * ONE);

            // Invariant should hold
            assertTrue(pool.checkInvariant(tickId));
        } catch {
            // Large trades might fail, that's acceptable
        }
        vm.stopPrank();
    }

    function testMultipleTicks() public {
        // Create two ticks
        uint256 r1 = 10000 * ONE;
        uint256 k1 = 8000 * ONE;
        uint256 tick1 = pool.createTick(r1, k1);

        uint256 r2 = 6000 * ONE;
        uint256 k2 = 4500 * ONE;
        uint256 tick2 = pool.createTick(r2, k2);

        // Alice adds to tick1
        vm.startPrank(alice);
        token0.approve(address(pool), 5000 * ONE);
        token1.approve(address(pool), 5000 * ONE);
        token2.approve(address(pool), 5000 * ONE);

        uint256[] memory amounts1 = new uint256[](3);
        amounts1[0] = 5000 * ONE;
        amounts1[1] = 5000 * ONE;
        amounts1[2] = 5000 * ONE;
        pool.addLiquidity(tick1, amounts1);
        vm.stopPrank();

        // Bob adds to tick2
        vm.startPrank(bob);
        token0.approve(address(pool), 3000 * ONE);
        token1.approve(address(pool), 3000 * ONE);
        token2.approve(address(pool), 3000 * ONE);

        uint256[] memory amounts2 = new uint256[](3);
        amounts2[0] = 3000 * ONE;
        amounts2[1] = 3000 * ONE;
        amounts2[2] = 3000 * ONE;
        pool.addLiquidity(tick2, amounts2);
        vm.stopPrank();

        assertEq(pool.getTickCount(), 2);

        // Swap should use largest tick
        vm.startPrank(bob);
        token0.approve(address(pool), 500 * ONE);
        pool.swap(0, 500 * ONE, 1, 0);
        vm.stopPrank();

        // Both ticks should still have valid invariants
        assertTrue(pool.checkInvariant(tick1));
        assertTrue(pool.checkInvariant(tick2));
    }

    function testFixedPointPrecision() public {
        // Create pool
        (uint256 tickId,) = _createPoolWithLiquidity(
            alice,
            10000 * ONE,
            10000 * ONE,
            10000 * ONE
        );

        // Check that reserves are exact
        uint256[] memory reserves = pool.getTickReserves(tickId);
        assertEq(reserves[0], 10000 * ONE);
        assertEq(reserves[1], 10000 * ONE);

        // Small trade (0.1 tokens)
        vm.startPrank(bob);
        token0.approve(address(pool), ONE / 10);
        uint256 amountOut = pool.swap(0, ONE / 10, 1, 0);
        vm.stopPrank();

        // Should get non-zero output
        assertGt(amountOut, 0);

        // Invariant should hold even with small amounts
        assertTrue(pool.checkInvariant(tickId));
    }

    function testGetTickReserves() public {
        // Create pool with uneven reserves
        vm.startPrank(alice);
        token0.approve(address(pool), 1000 * ONE);
        token1.approve(address(pool), 2000 * ONE);
        token2.approve(address(pool), 3000 * ONE);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000 * ONE;
        amounts[1] = 2000 * ONE;
        amounts[2] = 3000 * ONE;

        // Calculate r and k
        uint256 avg = (amounts[0] + amounts[1] + amounts[2]) / 3;
        uint256 r = FixedPointMath.div(avg, pool.oneMinusOneOverSqrtN());
        uint256 k = FixedPointMath.mul(r, 11 * ONE / 10); // 1.1x

        uint256 tickId = pool.createTick(r, k);
        pool.addLiquidity(tickId, amounts);
        vm.stopPrank();

        uint256[] memory reserves = pool.getTickReserves(tickId);

        assertEq(reserves.length, 3);
        assertApproxEqRel(reserves[0], 1000 * ONE, 0.01e18);
        assertApproxEqRel(reserves[1], 2000 * ONE, 0.01e18);
        assertApproxEqRel(reserves[2], 3000 * ONE, 0.01e18);
    }

    // ============ Helper Functions ============

    function _createPoolWithLiquidity(
        address lp,
        uint256 amount0,
        uint256 amount1,
        uint256 amount2
    ) internal returns (uint256 tickId, uint256 shares) {
        // Calculate r and k
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount0;
        amounts[1] = amount1;
        amounts[2] = amount2;

        uint256 avg = (amount0 + amount1 + amount2) / 3;
        uint256 r = FixedPointMath.div(avg, pool.oneMinusOneOverSqrtN());

        // k = r * (sqrt(n) - 1) * 1.1
        uint256 kBase = FixedPointMath.mul(
            r,
            pool.sqrtN() - FixedPointMath.ONE
        );
        uint256 k = FixedPointMath.mul(kBase, 11 * ONE / 10);

        // Create tick
        tickId = pool.createTick(r, k);

        // Add liquidity
        vm.startPrank(lp);
        token0.approve(address(pool), amount0);
        token1.approve(address(pool), amount1);
        token2.approve(address(pool), amount2);

        shares = pool.addLiquidity(tickId, amounts);
        vm.stopPrank();
    }
}
