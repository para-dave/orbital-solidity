// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/FixedPointMath.sol";

/**
 * @title FixedPointMathTest
 * @notice Test suite for FixedPointMath library
 * @dev Ported from fixed_point.py test_fixed_point()
 */
contract FixedPointMathTest is Test {
    using FixedPointMath for uint256;

    uint256 constant ONE = FixedPointMath.ONE;
    uint256 constant TOLERANCE = ONE / 1000; // 0.1%

    function setUp() public {}

    // Helper to convert float-like values to fixed-point
    function fromFloat(uint256 whole, uint256 decimal) internal pure returns (uint256) {
        return whole * ONE + (decimal * ONE) / 1000;
    }

    function testMul() public {
        uint256 a = fromFloat(2, 500); // 2.5
        uint256 b = fromFloat(4, 0);   // 4.0
        uint256 result = a.mul(b);
        uint256 expected = fromFloat(10, 0); // 10.0

        assertApproxEqAbs(result, expected, TOLERANCE, "Mul failed");
    }

    function testDiv() public {
        uint256 a = fromFloat(2, 500); // 2.5
        uint256 b = fromFloat(4, 0);   // 4.0
        uint256 result = a.div(b);
        uint256 expected = fromFloat(0, 625); // 0.625

        assertApproxEqAbs(result, expected, TOLERANCE, "Div failed");
    }

    function testDivByZero() public {
        uint256 a = fromFloat(2, 500);
        vm.expectRevert();
        this.divHelper(a, 0);
    }

    // Helper to wrap library call for proper revert testing
    function divHelper(uint256 a, uint256 b) external pure returns (uint256) {
        return a.div(b);
    }

    function testSqrt() public {
        // Test sqrt(16) = 4
        uint256 x = fromFloat(16, 0);
        uint256 result = x.sqrt();
        uint256 expected = fromFloat(4, 0);

        assertApproxEqAbs(result, expected, TOLERANCE, "Sqrt(16) failed");

        // Test sqrt(2) ≈ 1.414
        x = fromFloat(2, 0);
        result = x.sqrt();
        // Check that result^2 ≈ x
        uint256 squared = result.mul(result);
        assertApproxEqAbs(squared, x, ONE / 100, "Sqrt(2) failed"); // 1% tolerance
    }

    function testSqrtZero() public {
        uint256 result = uint256(0).sqrt();
        assertEq(result, 0, "Sqrt(0) should be 0");
    }

    function testUnitVector() public {
        uint256[] memory v = FixedPointMath.unitVector(3);

        assertEq(v.length, 3, "Wrong length");

        // Each component should be 1/sqrt(3) ≈ 0.577
        uint256 expected = ONE * 577 / 1000; // Approximate
        for (uint256 i = 0; i < 3; i++) {
            assertApproxEqAbs(v[i], expected, ONE / 100, "Unit vector component wrong");
        }

        // Check that sum of squares equals ONE
        uint256 sumSquares = 0;
        for (uint256 i = 0; i < 3; i++) {
            sumSquares += v[i].mul(v[i]);
        }
        assertApproxEqAbs(sumSquares, ONE, ONE / 100, "Unit vector not normalized");
    }

    function testDotProduct() public {
        uint256[] memory a = new uint256[](3);
        a[0] = fromFloat(1, 0);
        a[1] = fromFloat(2, 0);
        a[2] = fromFloat(3, 0);

        uint256[] memory b = new uint256[](3);
        b[0] = fromFloat(4, 0);
        b[1] = fromFloat(5, 0);
        b[2] = fromFloat(6, 0);

        // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
        uint256 result = FixedPointMath.dotProduct(a, b);
        uint256 expected = fromFloat(32, 0);

        assertApproxEqAbs(result, expected, TOLERANCE, "Dot product failed");
    }

    function testDotProductLengthMismatch() public {
        uint256[] memory a = new uint256[](3);
        uint256[] memory b = new uint256[](2);

        vm.expectRevert();
        this.dotProductHelper(a, b);
    }

    // Helper to wrap library call for proper revert testing
    function dotProductHelper(uint256[] memory a, uint256[] memory b) external pure returns (uint256) {
        return FixedPointMath.dotProduct(a, b);
    }

    function testSumSquares() public {
        uint256[] memory values = new uint256[](3);
        values[0] = fromFloat(2, 0); // 2
        values[1] = fromFloat(3, 0); // 3
        values[2] = fromFloat(4, 0); // 4

        // 2^2 + 3^2 + 4^2 = 4 + 9 + 16 = 29
        uint256 result = FixedPointMath.sumSquares(values);
        uint256 expected = fromFloat(29, 0);

        assertApproxEqAbs(result, expected, TOLERANCE, "Sum squares failed");
    }

    function testNorm() public {
        uint256[] memory values = new uint256[](2);
        values[0] = fromFloat(3, 0); // 3
        values[1] = fromFloat(4, 0); // 4

        // ||v|| = sqrt(3^2 + 4^2) = sqrt(25) = 5
        uint256 result = FixedPointMath.norm(values);
        uint256 expected = fromFloat(5, 0);

        assertApproxEqAbs(result, expected, TOLERANCE, "Norm failed");
    }

    function testSafeSub() public {
        uint256 a = fromFloat(10, 0);
        uint256 b = fromFloat(3, 0);

        uint256 result = FixedPointMath.safeSub(a, b);
        assertEq(result, fromFloat(7, 0), "SafeSub normal case failed");

        // Test underflow protection
        result = FixedPointMath.safeSub(b, a);
        assertEq(result, 0, "SafeSub should return 0 on underflow");
    }

    function testCenterVector() public {
        uint256 r = fromFloat(100, 0);
        uint256[] memory center = FixedPointMath.centerVector(r, 3);

        assertEq(center.length, 3, "Wrong length");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(center[i], r, "Center component wrong");
        }
    }

    function testApproxEqual() public {
        uint256 a = fromFloat(10, 0);
        uint256 b = fromFloat(10, 5); // 10.005
        uint256 tolerance = ONE / 100; // 1%

        assertTrue(
            FixedPointMath.approxEqual(a, b, tolerance),
            "Should be approximately equal"
        );

        b = fromFloat(11, 0);
        assertFalse(
            FixedPointMath.approxEqual(a, b, tolerance),
            "Should not be approximately equal"
        );
    }
}
