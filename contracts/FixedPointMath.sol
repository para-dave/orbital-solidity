// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FixedPointMath
 * @notice Fixed-point math library using 18 decimals
 * @dev All operations use 18 decimal places (like Ether wei)
 *      Ported from fixed_point.py
 */
library FixedPointMath {
    uint256 internal constant ONE = 10**18;
    uint256 internal constant MAX_UINT256 = type(uint256).max;

    /**
     * @notice Multiply two fixed-point numbers
     * @param a First fixed-point number
     * @param b Second fixed-point number
     * @return Result as fixed-point (a * b / ONE)
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / ONE;
    }

    /**
     * @notice Divide two fixed-point numbers
     * @param a Numerator (fixed-point)
     * @param b Denominator (fixed-point)
     * @return Result as fixed-point (a * ONE / b)
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "Division by zero");
        return (a * ONE) / b;
    }

    /**
     * @notice Square root using Newton's method
     * @param x Fixed-point number
     * @return Fixed-point square root
     * @dev Returns result * 10^18 (scaled)
     */
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        // Scale x up for precision
        uint256 scaledX = x * ONE;

        // Newton's method
        uint256 z = (scaledX + ONE) / 2;
        uint256 y = scaledX;

        uint256 iterations = 0;
        uint256 maxIterations = 100;

        while (z < y && iterations < maxIterations) {
            y = z;
            z = (scaledX / z + z) / 2;
            iterations++;
        }

        return y;
    }

    /**
     * @notice Sum of squares of fixed-point values
     * @param values Array of fixed-point numbers
     * @return Sum of (v * v) for each v
     */
    function sumSquares(uint256[] memory values) internal pure returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < values.length; i++) {
            result += mul(values[i], values[i]);
        }
        return result;
    }

    /**
     * @notice Compute ||v||^2 for a vector of fixed-point values
     * @param values Array of fixed-point numbers
     * @return Norm squared
     */
    function normSquared(uint256[] memory values) internal pure returns (uint256) {
        return sumSquares(values);
    }

    /**
     * @notice Compute ||v|| for a vector of fixed-point values
     * @param values Array of fixed-point numbers
     * @return Norm (magnitude)
     */
    function norm(uint256[] memory values) internal pure returns (uint256) {
        return sqrt(normSquared(values));
    }

    /**
     * @notice Dot product of two fixed-point vectors
     * @param a First vector
     * @param b Second vector
     * @return Dot product (sum of a[i] * b[i])
     */
    function dotProduct(uint256[] memory a, uint256[] memory b)
        internal
        pure
        returns (uint256)
    {
        require(a.length == b.length, "Length mismatch");

        uint256 sum = 0;
        for (uint256 i = 0; i < a.length; i++) {
            sum += mul(a[i], b[i]);
        }
        return sum;
    }

    /**
     * @notice Safe subtraction that returns 0 on underflow
     * @param a Minuend
     * @param b Subtrahend
     * @return max(0, a - b)
     */
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : 0;
    }

    /**
     * @notice Create unit vector (1/sqrt(n), 1/sqrt(n), ..., 1/sqrt(n))
     * @param n Number of dimensions
     * @return Array of n components, each 1/sqrt(n) in fixed-point
     */
    function unitVector(uint256 n) internal pure returns (uint256[] memory) {
        uint256 sqrtN = sqrt(n * ONE);
        uint256 component = div(ONE, sqrtN);

        uint256[] memory result = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            result[i] = component;
        }
        return result;
    }

    /**
     * @notice Create center vector (r, r, ..., r) for sphere AMM
     * @param r Radius in fixed-point
     * @param n Number of dimensions
     * @return Array of n components, each equal to r
     */
    function centerVector(uint256 r, uint256 n) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            result[i] = r;
        }
        return result;
    }

    /**
     * @notice Convert float to fixed-point (helper for testing)
     * @param x Integer representation of float * 10^18
     * @return Fixed-point number
     */
    function fromFloat(uint256 x) internal pure returns (uint256) {
        return x;
    }

    /**
     * @notice Check if two fixed-point values are approximately equal
     * @param a First value
     * @param b Second value
     * @param tolerance Maximum difference allowed
     * @return True if |a - b| <= tolerance
     */
    function approxEqual(uint256 a, uint256 b, uint256 tolerance)
        internal
        pure
        returns (bool)
    {
        uint256 diff = a > b ? a - b : b - a;
        return diff <= tolerance;
    }
}
