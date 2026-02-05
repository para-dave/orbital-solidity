// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FixedPointMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OrbitalPool
 * @notice Simplified n-dimensional sphere-based AMM for stablecoins
 * @dev Ported from orbital_simple.py - single-tick implementation
 */
contract OrbitalPool {
    using FixedPointMath for uint256;
    using SafeERC20 for IERC20;

    // ============ Structs ============

    struct Tick {
        uint256 r;                      // Radius parameter (fixed-point)
        uint256 k;                      // Boundary parameter (fixed-point)
        uint256[] reserves;             // Per-token reserves
        uint256 totalShares;            // Total LP shares
        mapping(address => uint256) lpShares;  // LP address => shares
    }

    // ============ State Variables ============

    uint256 public immutable nTokens;
    uint256 public immutable feesBps;           // Fee in basis points (30 = 0.3%)
    address[] public tokens;                     // Token addresses
    uint256[] public totalReserves;             // Global reserve tracking

    Tick[] private ticks;

    // Cached constants (computed in constructor)
    uint256 public immutable sqrtN;
    uint256 public immutable oneMinusOneOverSqrtN;

    // ============ Events ============

    event TickCreated(uint256 indexed tickId, uint256 r, uint256 k);
    event LiquidityAdded(
        uint256 indexed tickId,
        address indexed lp,
        uint256[] amounts,
        uint256 shares
    );
    event Swap(
        address indexed trader,
        uint256 tokenInIdx,
        uint256 amountIn,
        uint256 tokenOutIdx,
        uint256 amountOut
    );

    // ============ Constructor ============

    constructor(address[] memory _tokens, uint256 _feesBps) {
        require(_tokens.length >= 2, "Need at least 2 tokens");
        require(_feesBps <= 10000, "Fee too high");

        nTokens = _tokens.length;
        feesBps = _feesBps;
        tokens = _tokens;

        // Initialize global reserves
        totalReserves = new uint256[](nTokens);

        // Pre-compute constants
        sqrtN = FixedPointMath.sqrt(nTokens * FixedPointMath.ONE);
        oneMinusOneOverSqrtN = FixedPointMath.ONE - FixedPointMath.div(
            FixedPointMath.ONE,
            sqrtN
        );
    }

    // ============ Tick Management ============

    /**
     * @notice Create a new tick
     * @param r Radius parameter (fixed-point)
     * @param k Boundary parameter (fixed-point)
     * @return tickId The ID of the newly created tick
     */
    function createTick(uint256 r, uint256 k) external returns (uint256 tickId) {
        tickId = ticks.length;

        // Create new tick with empty reserves
        ticks.push();
        Tick storage tick = ticks[tickId];
        tick.r = r;
        tick.k = k;
        tick.reserves = new uint256[](nTokens);
        tick.totalShares = 0;

        emit TickCreated(tickId, r, k);
    }

    // ============ Add Liquidity ============

    /**
     * @notice Add liquidity to a tick
     * @param tickId The tick to add liquidity to
     * @param amounts Array of token amounts to deposit (fixed-point)
     * @return shares Number of LP shares minted
     */
    function addLiquidity(uint256 tickId, uint256[] calldata amounts)
        external
        returns (uint256 shares)
    {
        require(tickId < ticks.length, "Invalid tick");
        require(amounts.length == nTokens, "Wrong amounts length");

        Tick storage tick = ticks[tickId];

        if (tick.totalShares == 0) {
            // First LP: geometric mean
            shares = _geometricMean(amounts);

            // Set r from deposit
            uint256 sum = 0;
            for (uint256 i = 0; i < nTokens; i++) {
                require(amounts[i] > 0, "Zero initial deposit");
                sum += amounts[i];
            }
            uint256 avg = sum / nTokens;
            tick.r = FixedPointMath.div(avg, oneMinusOneOverSqrtN);

            // Set initial reserves
            for (uint256 i = 0; i < nTokens; i++) {
                tick.reserves[i] = amounts[i];
            }
        } else {
            // Proportional shares
            uint256 minRatio = type(uint256).max;
            for (uint256 i = 0; i < nTokens; i++) {
                require(tick.reserves[i] > 0, "No reserves");
                uint256 ratio = FixedPointMath.div(amounts[i], tick.reserves[i]);
                if (ratio < minRatio) {
                    minRatio = ratio;
                }
            }

            shares = FixedPointMath.mul(tick.totalShares, minRatio);
            require(shares > 0, "Shares must be positive");

            // Update reserves
            for (uint256 i = 0; i < nTokens; i++) {
                tick.reserves[i] += amounts[i];
            }

            // Scale r
            tick.r = FixedPointMath.mul(
                tick.r,
                FixedPointMath.ONE + minRatio
            );
        }

        // Update shares
        tick.totalShares += shares;
        tick.lpShares[msg.sender] += shares;

        // Update global reserves
        for (uint256 i = 0; i < nTokens; i++) {
            totalReserves[i] += amounts[i];
        }

        // Transfer tokens from user
        for (uint256 i = 0; i < nTokens; i++) {
            if (amounts[i] > 0) {
                IERC20(tokens[i]).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amounts[i]
                );
            }
        }

        emit LiquidityAdded(tickId, msg.sender, amounts, shares);
    }

    // ============ Swap ============

    /**
     * @notice Swap tokens
     * @param tokenInIdx Index of input token
     * @param amountIn Amount of input token
     * @param tokenOutIdx Index of output token
     * @param minAmountOut Minimum output amount (slippage protection)
     * @return amountOut Amount of output token received
     */
    function swap(
        uint256 tokenInIdx,
        uint256 amountIn,
        uint256 tokenOutIdx,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        require(tokenInIdx < nTokens, "Invalid tokenIn");
        require(tokenOutIdx < nTokens, "Invalid tokenOut");
        require(tokenInIdx != tokenOutIdx, "Same token");
        require(amountIn > 0, "Zero input");
        require(ticks.length > 0, "No liquidity");

        // Apply fee
        uint256 fee = (amountIn * feesBps) / 10000;
        uint256 amountInAfterFee = amountIn - fee;

        // Find largest active tick (simplified routing)
        uint256 largestTickId = type(uint256).max;
        uint256 largestR = 0;
        for (uint256 i = 0; i < ticks.length; i++) {
            if (ticks[i].totalShares == 0) continue;
            if (largestTickId == type(uint256).max || ticks[i].r > largestR) {
                largestR = ticks[i].r;
                largestTickId = i;
            }
        }
        require(largestTickId != type(uint256).max, "No liquidity");

        // Execute trade on tick
        amountOut = _tradeSingleTick(
            largestTickId,
            tokenInIdx,
            amountInAfterFee,
            tokenOutIdx
        );

        // Verify minimum output
        require(amountOut >= minAmountOut, "Slippage exceeded");

        // Update global reserves
        totalReserves[tokenInIdx] += amountIn;
        totalReserves[tokenOutIdx] -= amountOut;

        // Transfer tokens
        IERC20(tokens[tokenInIdx]).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );
        IERC20(tokens[tokenOutIdx]).safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenInIdx, amountIn, tokenOutIdx, amountOut);
    }

    // ============ Internal Functions ============

    /**
     * @notice Execute trade on a single tick using sphere invariant
     * @dev From paper: Solve quadratic for amountOut given amountIn
     */
    function _tradeSingleTick(
        uint256 tickId,
        uint256 inIdx,
        uint256 amountIn,
        uint256 outIdx
    ) internal returns (uint256 amountOut) {
        Tick storage tick = ticks[tickId];

        uint256 r = tick.r;
        uint256 xIn = tick.reserves[inIdx];
        uint256 xOut = tick.reserves[outIdx];

        // Direct formula: amountOut = sqrt((r-xOut)^2 - amountIn^2 + 2*(r-xIn)*amountIn) - (r-xOut)
        uint256 rMinusXIn = r - xIn;
        uint256 rMinusXOut = r - xOut;

        uint256 term1 = FixedPointMath.mul(rMinusXOut, rMinusXOut);
        uint256 term2 = FixedPointMath.mul(amountIn, amountIn);
        uint256 term3 = FixedPointMath.mul(
            FixedPointMath.mul(2 * FixedPointMath.ONE, rMinusXIn),
            amountIn
        );

        uint256 underSqrt = term1 + term3;
        require(underSqrt > term2, "Invalid trade: negative discriminant");
        underSqrt -= term2;

        uint256 sqrtTerm = FixedPointMath.sqrt(underSqrt);
        require(sqrtTerm > rMinusXOut, "Invalid trade: non-positive output");

        amountOut = sqrtTerm - rMinusXOut;

        // Update reserves
        tick.reserves[inIdx] = xIn + amountIn;
        tick.reserves[outIdx] = xOut - amountOut;

        // Verify sphere invariant
        require(_checkSphereInvariant(tickId), "Sphere invariant violated");
    }

    /**
     * @notice Check ||center - reserves||^2 = r^2
     */
    function _checkSphereInvariant(uint256 tickId) internal view returns (bool) {
        Tick storage tick = ticks[tickId];

        uint256 sumSquares = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            uint256 diff = tick.r - tick.reserves[i];
            sumSquares += FixedPointMath.mul(diff, diff);
        }

        uint256 rSquared = FixedPointMath.mul(tick.r, tick.r);

        // Allow small tolerance for rounding (0.1%)
        uint256 tolerance = FixedPointMath.ONE / 1000;
        uint256 delta = sumSquares > rSquared
            ? sumSquares - rSquared
            : rSquared - sumSquares;

        return delta < tolerance;
    }

    /**
     * @notice Geometric mean for initial share calculation
     * @dev Approximates (product)^(1/n) using iterative approach
     */
    function _geometricMean(uint256[] calldata values) internal view returns (uint256) {
        uint256 product = FixedPointMath.ONE;
        for (uint256 i = 0; i < values.length; i++) {
            product = FixedPointMath.mul(product, values[i]);
        }

        // Approximate nth root using Newton's method
        // Start with arithmetic mean as initial guess
        uint256 sum = 0;
        for (uint256 i = 0; i < values.length; i++) {
            sum += values[i];
        }
        uint256 x = sum / nTokens;

        // Newton iteration: x_new = ((n-1)*x + product/x^(n-1)) / n
        for (uint256 iter = 0; iter < 10; iter++) {
            uint256 xPowNMinus1 = FixedPointMath.ONE;
            for (uint256 j = 0; j < nTokens - 1; j++) {
                xPowNMinus1 = FixedPointMath.mul(xPowNMinus1, x);
            }

            uint256 numerator = FixedPointMath.mul((nTokens - 1) * FixedPointMath.ONE, x)
                + FixedPointMath.div(product, xPowNMinus1);
            x = numerator / nTokens;
        }

        return x;
    }

    // ============ View Functions ============

    /**
     * @notice Get price: tokenA per tokenB (fixed-point)
     * @dev Price = (r - x_b) / (r - x_a) from sphere formula
     */
    function getPrice(uint256 tokenAIdx, uint256 tokenBIdx)
        external
        view
        returns (uint256)
    {
        require(tokenAIdx < nTokens, "Invalid tokenA");
        require(tokenBIdx < nTokens, "Invalid tokenB");

        if (ticks.length == 0) {
            return FixedPointMath.ONE;
        }

        // Use largest active tick
        uint256 largestTickId = type(uint256).max;
        uint256 largestR = 0;
        for (uint256 i = 0; i < ticks.length; i++) {
            if (ticks[i].totalShares == 0) continue;
            if (largestTickId == type(uint256).max || ticks[i].r > largestR) {
                largestR = ticks[i].r;
                largestTickId = i;
            }
        }
        if (largestTickId == type(uint256).max) {
            return FixedPointMath.ONE;
        }

        Tick storage tick = ticks[largestTickId];

        uint256 numerator = tick.r - tick.reserves[tokenBIdx];
        uint256 denominator = tick.r - tick.reserves[tokenAIdx];

        return FixedPointMath.div(numerator, denominator);
    }

    /**
     * @notice Get reserves array for a tick
     */
    function getTickReserves(uint256 tickId)
        external
        view
        returns (uint256[] memory)
    {
        require(tickId < ticks.length, "Invalid tick");
        return ticks[tickId].reserves;
    }

    /**
     * @notice Get tick info
     */
    function getTickInfo(uint256 tickId)
        external
        view
        returns (
            uint256 r,
            uint256 k,
            uint256 totalShares,
            uint256[] memory reserves
        )
    {
        require(tickId < ticks.length, "Invalid tick");
        Tick storage tick = ticks[tickId];
        return (tick.r, tick.k, tick.totalShares, tick.reserves);
    }

    /**
     * @notice Get LP shares for an address in a tick
     */
    function getLPShares(uint256 tickId, address lp)
        external
        view
        returns (uint256)
    {
        require(tickId < ticks.length, "Invalid tick");
        return ticks[tickId].lpShares[lp];
    }

    /**
     * @notice Get number of ticks
     */
    function getTickCount() external view returns (uint256) {
        return ticks.length;
    }

    /**
     * @notice Check if a tick's sphere invariant holds
     */
    function checkInvariant(uint256 tickId) external view returns (bool) {
        require(tickId < ticks.length, "Invalid tick");
        return _checkSphereInvariant(tickId);
    }
}
