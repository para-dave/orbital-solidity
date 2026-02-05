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

contract OrbitalPoolV2FullTorusStressTest is Test {
    using FixedPointMath for uint256;

    uint256 constant ONE = 1e18;
    uint256 constant INV_TOL = 1e15; // must match contract tolerance
    uint256 constant PARALLEL_RTL = 1e12; // ~1e-12 relative tolerance

    OrbitalPool pool;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    address[] tokens;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        tokens = new address[](3);
        tokens[0] = address(token0);
        tokens[1] = address(token1);
        tokens[2] = address(token2);

        pool = new OrbitalPool(tokens);

        token0.mint(alice, 10_000_000 * ONE);
        token1.mint(alice, 10_000_000 * ONE);
        token2.mint(alice, 10_000_000 * ONE);

        token0.mint(bob, 10_000_000 * ONE);
        token1.mint(bob, 10_000_000 * ONE);
        token2.mint(bob, 10_000_000 * ONE);
    }

    function testRandomTradesRouteNoArb() public {
        // Ticks: one unconditional interior + 3 boundary-cap ticks with increasing k/r.
        uint256 tick0Id = pool.createTick(10_000 * ONE, 0);
        uint256 tick1Id = pool.createTick(10_000 * ONE, 7_800 * ONE); // k/r = 0.78
        uint256 tick2Id = pool.createTick(10_000 * ONE, 8_500 * ONE); // k/r = 0.85
        uint256 tick3Id = pool.createTick(10_000 * ONE, 9_500 * ONE); // k/r = 0.95

        // Add equal-point liquidity to all ticks (valid for all k/r >= sqrt(n)-1).
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        _addEqualLiquidity(tick0Id, 30_000 * ONE);
        _addEqualLiquidity(tick1Id, 20_000 * ONE);
        _addEqualLiquidity(tick2Id, 15_000 * ONE);
        _addEqualLiquidity(tick3Id, 10_000 * ONE);
        vm.stopPrank();

        // Pre-approve trader
        vm.startPrank(bob);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);

        uint256 seed = 123456;
        for (uint256 t = 0; t < 200; t++) {
            seed = uint256(keccak256(abi.encode(seed, t)));
            uint256 inIdx = seed % 3;
            uint256 outIdx = (seed / 3) % 3;
            if (outIdx == inIdx) outIdx = (outIdx + 1) % 3;

            (uint256[] memory totals, , ) = pool.getGlobalState();
            uint256 maxIn = totals[inIdx] / 50; // 2%
            if (maxIn < 5 * ONE) maxIn = 5 * ONE;
            uint256 amountIn = (seed / 9) % maxIn;
            if (amountIn < ONE / 10) amountIn = ONE / 10;

            // Trade should either succeed cleanly or revert; most should succeed with these sizes.
            try pool.swap(inIdx, amountIn, outIdx, 0) returns (uint256 amountOut) {
                assertTrue(amountOut > 0, "No output");
            } catch {
                // Accept reverts for extreme states; invariants must still hold.
            }

            _assertAllTickInvariantsAndNoArb();
        }

        vm.stopPrank();
    }

    function _addEqualLiquidity(uint256 tickId, uint256 totalAmount) internal {
        uint256[] memory amounts = new uint256[](3);
        uint256 per = totalAmount / 3;
        amounts[0] = per;
        amounts[1] = per;
        amounts[2] = totalAmount - 2 * per; // keep exact sum
        pool.addLiquidity(tickId, amounts);
    }

    function _assertAllTickInvariantsAndNoArb() internal view {
        uint256 tickCount = pool.getTickCount();

        // Find reference vectors
        bool haveRefW = false;
        bool haveRefD = false;
        int256[] memory refW = new int256[](3);
        int256[] memory refD = new int256[](3);

        for (uint256 tickId = 0; tickId < tickCount; tickId++) {
            (, uint256 k, , uint256 totalShares, uint256[] memory reserves) = pool.getTickInfo(tickId);
            if (totalShares == 0) continue;

            assertTrue(pool.checkInvariant(tickId), "Sphere invariant");

            if (k > 0 && pool.isPinned(tickId)) {
                assertTrue(pool.isOnBoundary(tickId), "Pinned must satisfy plane");
            }

            // alpha <= k for all boundary-parameter ticks (pinned or interior)
            if (k > 0) {
                uint256 oneOverSqrtN = pool.oneOverSqrtN();
                uint256 alpha = 0;
                for (uint256 i = 0; i < 3; i++) {
                    alpha += reserves[i].mul(oneOverSqrtN);
                }
                assertTrue(alpha <= k + INV_TOL, "alpha <= k");
            }

            // w = x - avg(x) should be parallel across all ticks (skip near-equal w=0)
            int256[] memory w = _wVector(reserves);
            if (_normSq(w) > 1000) {
                if (!haveRefW) {
                    haveRefW = true;
                    refW = w;
                } else {
                    _assertParallel(refW, w, "w parallel");
                }
            }

            // For interior ticks, d = r - x should be parallel (prices match).
            if (!pool.isPinned(tickId)) {
                (uint256 r, , , , ) = pool.getTickInfo(tickId);
                int256[] memory d = new int256[](3);
                d[0] = int256(r) - int256(reserves[0]);
                d[1] = int256(r) - int256(reserves[1]);
                d[2] = int256(r) - int256(reserves[2]);
                if (_normSq(d) > 1000) {
                    if (!haveRefD) {
                        haveRefD = true;
                        refD = d;
                    } else {
                        _assertParallel(refD, d, "d parallel");
                    }
                }
            }
        }
    }

    function _wVector(uint256[] memory reserves) internal pure returns (int256[] memory w) {
        w = new int256[](3);
        uint256 sum = reserves[0] + reserves[1] + reserves[2];
        uint256 avg = sum / 3;
        w[0] = int256(reserves[0]) - int256(avg);
        w[1] = int256(reserves[1]) - int256(avg);
        w[2] = int256(reserves[2]) - int256(avg);
    }

    function _assertParallel(int256[] memory a, int256[] memory b, string memory err) internal pure {
        int256 dot = _dot(a, b); // fixed-point
        uint256 n1 = _normSq(a);
        uint256 n2 = _normSq(b);
        if (n1 == 0 || n2 == 0) return;

        uint256 left = uint256(_abs(dot));
        left = left * left;
        uint256 right = n1 * n2;

        uint256 diff = left > right ? left - right : right - left;
        // Relative tolerance on dot^2 vs norms product
        uint256 tol = right / PARALLEL_RTL + 1;
        require(diff <= tol, err);
    }

    function _dot(int256[] memory a, int256[] memory b) internal pure returns (int256) {
        int256 sum = 0;
        for (uint256 i = 0; i < 3; i++) {
            sum += (a[i] * b[i]) / int256(ONE);
        }
        return sum;
    }

    function _normSq(int256[] memory a) internal pure returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < 3; i++) {
            int256 v = a[i];
            uint256 av = uint256(v < 0 ? -v : v);
            sum += (av * av) / ONE;
        }
        return sum;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }
}
