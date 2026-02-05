// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FixedPointMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OrbitalPoolV2
 * @notice Full n-dimensional sphere-based AMM with tick consolidation
 * @dev Implements the complete paper specification including:
 *      - Interior tick consolidation
 *      - Boundary tick consolidation
 *      - Torus consolidation (interior + boundary)
 *      - Multi-tick routing with global invariant
 *      - LP withdrawal
 */
contract OrbitalPoolV2 {
    using FixedPointMath for uint256;
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 private constant TOLERANCE = 1e15; // 0.1% tolerance for invariants
    uint256 private constant MAX_ITERATIONS = 20; // Numerical solver iterations

    // ============ Enums ============

    enum TickType {
        Interior,      // No boundary constraint
        Boundary       // Has boundary constraint k
    }

    // ============ Structs ============

    struct Tick {
        uint256 r;                              // Radius parameter
        uint256 k;                              // Boundary constraint (0 for interior)
        TickType tickType;                       // Interior = no boundary parameter, Boundary = has k parameter
        bool pinned;                             // Whether the tick is currently pinned to its boundary (x·v = k)
        uint256[] reserves;                      // Per-token reserves
        uint256 totalShares;                     // Total LP shares
        mapping(address => uint256) lpShares;    // LP address => shares
    }

    struct GlobalState {
        uint256[] totalReserves;     // Sum of all tick reserves per token
        uint256 totalR;              // Sum of all r values
        uint256 totalRSquared;       // Sum of r² values
    }

    struct ConsolidationCache {
        uint256[] tickIds;           // Ticks being consolidated
        uint256[] weights;           // Weight of each tick (r / total_r)
        uint256 combinedR;           // Combined radius
        uint256[] combinedReserves;  // Combined reserves
    }

    // ============ State Variables ============

    uint256 public immutable nTokens;
    address[] public tokens;

    Tick[] private ticks;
    GlobalState private globalState;

    // Cached constants
    uint256 public immutable sqrtN;
    uint256 public immutable oneMinusOneOverSqrtN;
    uint256 public immutable oneOverSqrtN;

    // ============ Events ============

    event TickCreated(uint256 indexed tickId, uint256 r, uint256 k, TickType tickType);
    event LiquidityAdded(uint256 indexed tickId, address indexed lp, uint256[] amounts, uint256 shares);
    event LiquidityRemoved(uint256 indexed tickId, address indexed lp, uint256 shares, uint256[] amounts);
    event Swap(address indexed trader, uint256 tokenInIdx, uint256 amountIn, uint256 tokenOutIdx, uint256 amountOut);
    event TicksConsolidated(uint256[] tickIds, uint256 combinedR);

    // ============ Constructor ============

    constructor(address[] memory _tokens) {
        require(_tokens.length >= 2, "Need at least 2 tokens");

        nTokens = _tokens.length;
        tokens = _tokens;

        // Initialize global state
        globalState.totalReserves = new uint256[](nTokens);
        globalState.totalR = 0;
        globalState.totalRSquared = 0;

        // Pre-compute constants
        sqrtN = FixedPointMath.sqrt(nTokens * FixedPointMath.ONE);
        oneMinusOneOverSqrtN = FixedPointMath.ONE - FixedPointMath.div(
            FixedPointMath.ONE,
            sqrtN
        );
        oneOverSqrtN = FixedPointMath.div(FixedPointMath.ONE, sqrtN);
    }

    // ============ Tick Management ============

    /**
     * @notice Create a new tick (interior or boundary)
     * @param r Radius parameter
     * @param k Boundary constraint (0 for interior tick)
     * @return tickId The ID of the newly created tick
     */
    function createTick(uint256 r, uint256 k) external returns (uint256 tickId) {
        require(r > 0, "Radius must be positive");

        tickId = ticks.length;
        TickType tickType = k == 0 ? TickType.Interior : TickType.Boundary;

        // Create new tick
        ticks.push();
        Tick storage tick = ticks[tickId];
        tick.r = r;
        tick.k = k;
        tick.tickType = tickType;
        tick.pinned = false;
        tick.reserves = new uint256[](nTokens);
        tick.totalShares = 0;

        emit TickCreated(tickId, r, k, tickType);
    }

    // ============ Add Liquidity ============

    /**
     * @notice Add liquidity to a tick
     * @param tickId The tick to add liquidity to
     * @param amounts Array of token amounts to deposit
     * @return shares Number of LP shares minted
     */
    function addLiquidity(uint256 tickId, uint256[] calldata amounts)
        external
        returns (uint256 shares)
    {
        require(tickId < ticks.length, "Invalid tick");
        require(amounts.length == nTokens, "Wrong amounts length");

        Tick storage tick = ticks[tickId];
        uint256[] memory usedAmounts = new uint256[](nTokens);

        if (tick.totalShares == 0) {
            // First LP: geometric mean
            shares = _geometricMean(amounts);
            require(shares > 0, "Initial shares must be positive");

            // Set r from deposit
            uint256 oldR = tick.r;
            uint256 sum = 0;
            for (uint256 i = 0; i < nTokens; i++) {
                require(amounts[i] > 0, "Zero initial deposit");
                sum += amounts[i];
            }
            uint256 avg = sum / nTokens;
            uint256 newR = avg.div(oneMinusOneOverSqrtN);
            tick.r = newR;

            // Keep k/r invariant (k_norm) constant as r is updated.
            if (tick.k > 0) {
                uint256 scaleFactor = newR.div(oldR);
                tick.k = tick.k.mul(scaleFactor);
            }

            // Set initial reserves
            for (uint256 i = 0; i < nTokens; i++) {
                tick.reserves[i] = amounts[i];
                usedAmounts[i] = amounts[i];
            }

            // Initialize pinned state based on whether we are exactly on the boundary.
            if (tick.k > 0) {
                uint256 dotProduct = 0;
                for (uint256 i = 0; i < nTokens; i++) {
                    dotProduct += tick.reserves[i].mul(oneOverSqrtN);
                }
                uint256 delta = dotProduct > tick.k ? dotProduct - tick.k : tick.k - dotProduct;
                tick.pinned = delta < TOLERANCE;
                require(dotProduct <= tick.k + TOLERANCE, "Initial state outside tick");
            }

            require(_checkSphereInvariant(tickId), "Invalid initial state");
        } else {
            // Proportional shares: scale the entire tick (reserves, r, k) by a single factor.
            // This preserves:
            // - Sphere invariant
            // - No-arbitrage direction (center - reserves)
            // and prevents value extraction via unbalanced deposits.
            uint256 minRatio = type(uint256).max;
            for (uint256 i = 0; i < nTokens; i++) {
                require(tick.reserves[i] > 0, "No reserves");
                uint256 ratio = amounts[i].div(tick.reserves[i]);
                if (ratio < minRatio) {
                    minRatio = ratio;
                }
            }

            shares = tick.totalShares.mul(minRatio);
            require(shares > 0, "Shares must be positive");

            uint256 scaleFactor = FixedPointMath.ONE + minRatio;

            // Update reserves (scaled) and compute exact amounts required
            for (uint256 i = 0; i < nTokens; i++) {
                uint256 oldReserve = tick.reserves[i];
                uint256 newReserve = oldReserve.mul(scaleFactor);
                usedAmounts[i] = newReserve - oldReserve;
                require(amounts[i] >= usedAmounts[i], "Insufficient proportional deposit");
                tick.reserves[i] = newReserve;
            }

            tick.r = tick.r.mul(scaleFactor);
            if (tick.k > 0) {
                tick.k = tick.k.mul(scaleFactor);
            }

            // Maintain constraints after scaling.
            require(_checkSphereInvariant(tickId), "Invalid liquidity add");
            if (tick.k > 0) {
                uint256 dotProduct = 0;
                for (uint256 i = 0; i < nTokens; i++) {
                    dotProduct += tick.reserves[i].mul(oneOverSqrtN);
                }
                require(dotProduct <= tick.k + TOLERANCE, "Outside tick after add");
                if (tick.pinned) {
                    require(isOnBoundary(tickId), "Pinned must satisfy plane");
                }
            }
        }

        // Update shares
        tick.totalShares += shares;
        tick.lpShares[msg.sender] += shares;

        // Update global state
        _updateGlobalState();

        // Transfer tokens
        for (uint256 i = 0; i < nTokens; i++) {
            if (usedAmounts[i] > 0) {
                IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), usedAmounts[i]);
            }
        }

        emit LiquidityAdded(tickId, msg.sender, usedAmounts, shares);
    }

    // ============ Remove Liquidity ============

    /**
     * @notice Remove liquidity from a tick
     * @param tickId The tick to remove liquidity from
     * @param shares Number of shares to burn
     * @return amounts Array of token amounts returned
     */
    function removeLiquidity(uint256 tickId, uint256 shares)
        external
        returns (uint256[] memory amounts)
    {
        require(tickId < ticks.length, "Invalid tick");
        Tick storage tick = ticks[tickId];
        require(tick.lpShares[msg.sender] >= shares, "Insufficient shares");
        require(shares > 0, "Shares must be positive");

        // Calculate proportional amounts
        uint256 proportion = shares.div(tick.totalShares);
        amounts = new uint256[](nTokens);

        uint256 scaleFactor = FixedPointMath.ONE - proportion;
        for (uint256 i = 0; i < nTokens; i++) {
            uint256 oldReserve = tick.reserves[i];
            uint256 newReserve = oldReserve.mul(scaleFactor);
            amounts[i] = oldReserve - newReserve;
            tick.reserves[i] = newReserve;
        }

        // Update shares
        tick.totalShares -= shares;
        tick.lpShares[msg.sender] -= shares;

        // Scale r down proportionally
        tick.r = tick.r.mul(scaleFactor);
        if (tick.k > 0) {
            tick.k = tick.k.mul(scaleFactor);
        }

        require(_checkSphereInvariant(tickId), "Invalid liquidity remove");
        if (tick.k > 0) {
            uint256 dotProduct = 0;
            for (uint256 i = 0; i < nTokens; i++) {
                dotProduct += tick.reserves[i].mul(oneOverSqrtN);
            }
            require(dotProduct <= tick.k + TOLERANCE, "Outside tick after remove");
            if (tick.pinned) {
                require(isOnBoundary(tickId), "Pinned must satisfy plane");
            }
        }

        // Update global state
        _updateGlobalState();

        // Transfer tokens
        for (uint256 i = 0; i < nTokens; i++) {
            if (amounts[i] > 0) {
                IERC20(tokens[i]).safeTransfer(msg.sender, amounts[i]);
            }
        }

        emit LiquidityRemoved(tickId, msg.sender, shares, amounts);
    }

    // ============ Swap (with multi-tick routing) ============

    /**
     * @notice Swap tokens with multi-tick routing
     * @param tokenInIdx Index of input token
     * @param amountIn Amount of input token
     * @param tokenOutIdx Index of output token
     * @param minAmountOut Minimum output amount
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

        amountOut = _swapFullTorusSegmented(tokenInIdx, amountIn, tokenOutIdx);

        require(amountOut >= minAmountOut, "Slippage exceeded");

        // Update global state
        _updateGlobalState();

        // Transfer tokens
        IERC20(tokens[tokenInIdx]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokens[tokenOutIdx]).safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenInIdx, amountIn, tokenOutIdx, amountOut);
    }

    // ============ Full Torus Routing (Paper Spec) ============

    uint256 private constant MAX_SEGMENTS = 64;
    uint256 private constant CROSS_TOLERANCE = 1e14; // tighter than invariant tolerance

    struct ConsolidatedState {
        uint256[] interiorIds;
        uint256[] boundaryIds;
        uint256 rInt;                // Sum of r across interior ticks
        uint256 kBoundTotal;         // Sum of k across boundary ticks
        uint256 sBoundTotal;         // Sum of s across boundary ticks
        uint256 kMinInteriorNorm;    // min(k/r) among interior ticks with k>0
        uint256 kMaxBoundaryNorm;    // max(k/r) among boundary ticks
        uint256 crossInteriorId;     // id of tick achieving kMinInteriorNorm
        uint256 crossBoundaryId;     // id of tick achieving kMaxBoundaryNorm
        uint256[] xTotal;            // total reserves across all active ticks
        uint256 sumTotal;            // sum(xTotal)
        uint256 sumSquaresTotal;     // sum(xTotal^2)
    }

    function _swapFullTorusSegmented(
        uint256 inIdx,
        uint256 amountIn,
        uint256 outIdx
    ) internal returns (uint256 amountOut) {
        uint256 remaining = amountIn;
        uint256 totalOut = 0;

        for (uint256 seg = 0; seg < MAX_SEGMENTS; seg++) {
            if (remaining == 0) break;

            ConsolidatedState memory state = _getConsolidatedState();
            require(state.rInt > 0, "No interior liquidity");

            uint256 xOutBefore = state.xTotal[outIdx];
            require(xOutBefore > 0, "No output liquidity");

            // Solve assuming no tick boundary crossing in this segment
            uint256 newXOut;
            if (state.boundaryIds.length == 0) {
                newXOut = _solveSphereNewXOut(state.xTotal, state.rInt, inIdx, remaining, outIdx);
            } else {
                newXOut = _solveTorusNewXOut(state, inIdx, remaining, outIdx);
            }

            require(newXOut < xOutBefore, "Invalid trade");
            uint256 segmentOut = xOutBefore - newXOut;

            // Compute potential interior normalized projection after the segment
            uint256 sumPotential = state.sumTotal + remaining - segmentOut;
            uint256 alphaTotalPotential = sumPotential.mul(oneOverSqrtN);
            require(alphaTotalPotential + TOLERANCE >= state.kBoundTotal, "Invalid alpha");
            uint256 alphaIntPotential = alphaTotalPotential > state.kBoundTotal ? alphaTotalPotential - state.kBoundTotal : 0;
            uint256 alphaIntNormPotential = alphaIntPotential.div(state.rInt);

            bool canCrossInward = state.kMaxBoundaryNorm > 0;
            bool canCrossOutward = state.kMinInteriorNorm != type(uint256).max;

            bool crossesOutward = canCrossOutward && (alphaIntNormPotential > state.kMinInteriorNorm + CROSS_TOLERANCE);
            bool crossesInward = canCrossInward && (alphaIntNormPotential + CROSS_TOLERANCE < state.kMaxBoundaryNorm);

            if (!crossesOutward && !crossesInward) {
                // Apply full segment
                state.xTotal[inIdx] += remaining;
                state.xTotal[outIdx] = newXOut;
                _applyGlobalReserves(state, state.xTotal);
                totalOut += segmentOut;
                remaining = 0;
                break;
            }

            // Crossing detected: compute exact crossover segment (dIn, dOut) to boundary point.
            uint256 kCrossNorm;
            uint256 crossTickId;
            bool outward;
            if (crossesOutward) {
                outward = true;
                kCrossNorm = state.kMinInteriorNorm;
                crossTickId = state.crossInteriorId;
            } else {
                outward = false;
                kCrossNorm = state.kMaxBoundaryNorm;
                crossTickId = state.crossBoundaryId;
            }
            require(crossTickId != type(uint256).max, "Cross tick missing");

            (uint256 dInCross, uint256 dOutCross) = _solveCrossoverAmounts(
                state,
                inIdx,
                outIdx,
                kCrossNorm
            );

            // Guard against degenerate results
            require(dInCross > 0 && dInCross < remaining, "Bad crossover");
            require(dOutCross > 0 && dOutCross < xOutBefore, "Bad crossover out");

            // Apply crossover segment (no Newton needed)
            state.xTotal[inIdx] += dInCross;
            state.xTotal[outIdx] -= dOutCross;
            _applyGlobalReserves(state, state.xTotal);

            totalOut += dOutCross;
            remaining -= dInCross;

            // Flip pinned status for the crossing tick for subsequent segments
            if (outward) {
                ticks[crossTickId].pinned = true;
            } else {
                ticks[crossTickId].pinned = false;
            }
        }

        require(remaining == 0, "Too many segments");
        return totalOut;
    }

    function _getConsolidatedState() internal view returns (ConsolidatedState memory state) {
        uint256 interiorCount = 0;
        uint256 boundaryCount = 0;

        state.xTotal = new uint256[](nTokens);
        state.kMinInteriorNorm = type(uint256).max;
        state.kMaxBoundaryNorm = 0;
        state.crossInteriorId = type(uint256).max;
        state.crossBoundaryId = type(uint256).max;

        // Pass 1: count + accumulate totals/parameters
        for (uint256 tickId = 0; tickId < ticks.length; tickId++) {
            Tick storage tick = ticks[tickId];
            if (tick.totalShares == 0) continue;

            // Total reserves across all active ticks
            for (uint256 i = 0; i < nTokens; i++) {
                state.xTotal[i] += tick.reserves[i];
            }

            bool isBoundary = tick.k > 0 && tick.pinned;
            if (isBoundary) {
                boundaryCount++;
                state.kBoundTotal += tick.k;
                state.sBoundTotal += _boundaryOrthogonalRadius(tick.r, tick.k);

                uint256 kNorm = tick.k.div(tick.r);
                if (kNorm > state.kMaxBoundaryNorm) {
                    state.kMaxBoundaryNorm = kNorm;
                    state.crossBoundaryId = tickId;
                }
            } else {
                interiorCount++;
                state.rInt += tick.r;

                if (tick.k > 0) {
                    uint256 kNorm = tick.k.div(tick.r);
                    if (kNorm < state.kMinInteriorNorm) {
                        state.kMinInteriorNorm = kNorm;
                        state.crossInteriorId = tickId;
                    }
                }
            }
        }

        // Compute sum + sumSquares of total reserves
        state.sumTotal = 0;
        state.sumSquaresTotal = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            state.sumTotal += state.xTotal[i];
            state.sumSquaresTotal += state.xTotal[i].mul(state.xTotal[i]);
        }

        // Pass 2: collect ids
        state.interiorIds = new uint256[](interiorCount);
        state.boundaryIds = new uint256[](boundaryCount);
        uint256 iIdx = 0;
        uint256 bIdx = 0;

        for (uint256 tickId = 0; tickId < ticks.length; tickId++) {
            Tick storage tick = ticks[tickId];
            if (tick.totalShares == 0) continue;

            bool isBoundary = tick.k > 0 && tick.pinned;
            if (isBoundary) {
                state.boundaryIds[bIdx] = tickId;
                bIdx++;
            } else {
                state.interiorIds[iIdx] = tickId;
                iIdx++;
            }
        }
    }

    function _boundaryOrthogonalRadius(uint256 r, uint256 k) internal view returns (uint256) {
        // s = sqrt(r^2 - (k - r*sqrt(n))^2)
        uint256 rSqrtN = r.mul(sqrtN);
        uint256 diff = k > rSqrtN ? k - rSqrtN : rSqrtN - k;
        uint256 rSquared = r.mul(r);
        uint256 diffSquared = diff.mul(diff);
        require(rSquared >= diffSquared, "Invalid boundary geometry");
        return (rSquared - diffSquared).sqrt();
    }

    function _solveSphereNewXOut(
        uint256[] memory xTotal,
        uint256 r,
        uint256 inIdx,
        uint256 amountIn,
        uint256 outIdx
    ) internal pure returns (uint256 newXOut) {
        uint256 xIn = xTotal[inIdx];
        uint256 xOut = xTotal[outIdx];

        require(xIn <= r, "Bad sphere xIn");
        require(xOut <= r, "Bad sphere xOut");

        uint256 rMinusXIn = r - xIn;
        uint256 rMinusXOut = r - xOut;

        uint256 term1 = rMinusXOut.mul(rMinusXOut);
        uint256 term2 = amountIn.mul(amountIn);
        uint256 term3 = (2 * FixedPointMath.ONE).mul(rMinusXIn).mul(amountIn);

        uint256 underSqrt = term1 + term3;
        require(underSqrt > term2, "Invalid trade");
        underSqrt -= term2;

        uint256 sqrtTerm = underSqrt.sqrt();
        require(sqrtTerm <= r, "Invalid trade sqrt");
        newXOut = r - sqrtTerm;
    }

    function _solveTorusNewXOut(
        ConsolidatedState memory state,
        uint256 inIdx,
        uint256 amountIn,
        uint256 outIdx
    ) internal view returns (uint256 newXOut) {
        uint256 xIn0 = state.xTotal[inIdx];
        uint256 xOut0 = state.xTotal[outIdx];
        require(xOut0 > 0, "No output liquidity");

        // Precompute the parts of (sum, sumSquares) that don't depend on the candidate xOut.
        uint256 sumBase = state.sumTotal + amountIn;

        uint256 xIn1 = xIn0 + amountIn;
        uint256 sumSquaresBase = state.sumSquaresTotal + xIn1.mul(xIn1) - xIn0.mul(xIn0);

        uint256 low = 0;
        uint256 high = xOut0;

        int256 fLow = _fullTorusInvariantErrorFromSums(
            sumBase - xOut0 + low,
            sumSquaresBase - xOut0.mul(xOut0) + low.mul(low),
            state.rInt,
            state.kBoundTotal,
            state.sBoundTotal
        );
        int256 fHigh = _fullTorusInvariantErrorFromSums(
            sumBase,
            sumSquaresBase,
            state.rInt,
            state.kBoundTotal,
            state.sBoundTotal
        );

        require(
            fLow == 0 || fHigh == 0 || (fLow > 0 && fHigh < 0) || (fLow < 0 && fHigh > 0),
            "Unbracketed"
        );

        if (fHigh == 0) return high;
        if (fLow == 0) return low;

        for (uint256 iter = 0; iter < MAX_ITERATIONS * 4; iter++) {
            uint256 mid = (low + high) / 2;
            int256 fMid = _fullTorusInvariantErrorFromSums(
                sumBase - xOut0 + mid,
                sumSquaresBase - xOut0.mul(xOut0) + mid.mul(mid),
                state.rInt,
                state.kBoundTotal,
                state.sBoundTotal
            );

            if (_absInt(fMid) < TOLERANCE) {
                return mid;
            }

            // keep bracketing
            if ((fMid > 0 && fLow > 0) || (fMid < 0 && fLow < 0)) {
                low = mid;
                fLow = fMid;
            } else {
                high = mid;
                fHigh = fMid;
            }

            if (high - low <= 1) {
                return high;
            }
        }

        return high;
    }

    function _fullTorusInvariantErrorFromSums(
        uint256 sumTotal,
        uint256 sumSquares,
        uint256 rInt,
        uint256 kBoundTotal,
        uint256 sBoundTotal
    ) internal view returns (int256) {
        // Paper: r_int^2 = (alpha_total - k_bound_total - r_int*sqrt(n))^2 + (||w_total|| - s_bound_total)^2
        uint256 alphaTotal = sumTotal.mul(oneOverSqrtN);
        int256 parallelDiff = int256(alphaTotal) - int256(kBoundTotal) - int256(rInt.mul(sqrtN));
        uint256 parallelTerm = _absInt(parallelDiff).mul(_absInt(parallelDiff));

        uint256 sumSquaredOverN = FixedPointMath.mul(sumTotal, sumTotal) / nTokens;
        require(sumSquares + TOLERANCE >= sumSquaredOverN, "Invalid orth");
        uint256 orthNormSquared = sumSquares > sumSquaredOverN ? sumSquares - sumSquaredOverN : 0;
        uint256 orthNorm = orthNormSquared.sqrt();

        int256 orthDiff = int256(orthNorm) - int256(sBoundTotal);
        uint256 orthTerm = _absInt(orthDiff).mul(_absInt(orthDiff));

        int256 lhs = int256(parallelTerm) + int256(orthTerm);
        int256 rhs = int256(rInt.mul(rInt));
        return lhs - rhs;
    }

    function _solveCrossoverAmounts(
        ConsolidatedState memory state,
        uint256 inIdx,
        uint256 outIdx,
        uint256 kCrossNorm
    ) internal view returns (uint256 dIn, uint256 dOut) {
        // Target: alpha_int_norm == kCrossNorm
        uint256 alphaIntTarget = state.rInt.mul(kCrossNorm);
        uint256 alphaTotalTarget = alphaIntTarget + state.kBoundTotal;
        uint256 sumTarget = alphaTotalTarget.mul(sqrtN);

        // ||w_int|| from interior sphere + ||w_bound|| = ||w_total||
        uint256 rIntSqrtN = state.rInt.mul(sqrtN);
        uint256 parallelDiffAbs = alphaIntTarget > rIntSqrtN ? alphaIntTarget - rIntSqrtN : rIntSqrtN - alphaIntTarget;
        uint256 rIntSquared = state.rInt.mul(state.rInt);
        uint256 parallelDiffSquared = parallelDiffAbs.mul(parallelDiffAbs);
        require(rIntSquared >= parallelDiffSquared, "Bad crossover geom");
        uint256 wIntMag = (rIntSquared - parallelDiffSquared).sqrt();
        uint256 wTotalTarget = state.sBoundTotal + wIntMag;

        uint256 sumSquaredOverNTarget = FixedPointMath.mul(sumTarget, sumTarget) / nTokens;
        uint256 sumSquaresTarget = wTotalTarget.mul(wTotalTarget) + sumSquaredOverNTarget;

        int256 sumDelta = int256(state.sumTotal) - int256(sumTarget);

        uint256 xIn = state.xTotal[inIdx];
        uint256 xOut = state.xTotal[outIdx];

        // Quadratic in dIn (fixed-point):
        // 2*d^2 + 2*(xIn - xOut + sumDelta)*d + (sumSqCur - sumSqTarget - 2*xOut*sumDelta + sumDelta^2) = 0
        int256 B = 2 * (int256(xIn) - int256(xOut) + sumDelta);
        int256 C = int256(state.sumSquaresTotal) - int256(sumSquaresTarget);
        C += (-2 * (int256(xOut) * sumDelta)) / int256(FixedPointMath.ONE);
        C += (sumDelta * sumDelta) / int256(FixedPointMath.ONE);

        int256 disc = (B * B) / int256(FixedPointMath.ONE) - 8 * C;
        require(disc >= 0, "No crossover root");
        uint256 sqrtDisc = uint256(disc).sqrt();

        int256 root1 = (-B + int256(sqrtDisc)) / 4;
        int256 root2 = (-B - int256(sqrtDisc)) / 4;

        uint256 dCandidate = 0;
        if (root1 > 0) {
            dCandidate = uint256(root1);
        }
        if (root2 > 0 && (dCandidate == 0 || uint256(root2) < dCandidate)) {
            dCandidate = uint256(root2);
        }
        require(dCandidate > 0, "No positive crossover");

        int256 dOutSigned = int256(dCandidate) + sumDelta;
        require(dOutSigned > 0, "Bad crossover dOut");

        dIn = dCandidate;
        dOut = uint256(dOutSigned);
    }

    function _applyGlobalReserves(ConsolidatedState memory state, uint256[] memory xTotal) internal {
        // Compute orthogonal direction u from xTotal.
        uint256 sumTotal = 0;
        uint256 sumSquares = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            sumTotal += xTotal[i];
            sumSquares += xTotal[i].mul(xTotal[i]);
        }

        uint256 avg = sumTotal / nTokens;
        uint256 sumSquaredOverN = FixedPointMath.mul(sumTotal, sumTotal) / nTokens;
        require(sumSquares + TOLERANCE >= sumSquaredOverN, "Invalid total");

        uint256 orthNormSquared = sumSquares > sumSquaredOverN ? sumSquares - sumSquaredOverN : 0;
        uint256 orthNorm = orthNormSquared.sqrt();

        int256[] memory u = new int256[](nTokens); // fixed-point unit vector components
        if (orthNorm > 0) {
            for (uint256 i = 0; i < nTokens; i++) {
                int256 w = int256(xTotal[i]) - int256(avg);
                u[i] = (w * int256(FixedPointMath.ONE)) / int256(orthNorm);
            }
        }

        // Update boundary ticks: x = k*v + s*u
        for (uint256 b = 0; b < state.boundaryIds.length; b++) {
            uint256 tickId = state.boundaryIds[b];
            Tick storage tick = ticks[tickId];

            uint256 s = _boundaryOrthogonalRadius(tick.r, tick.k);
            uint256 kPerToken = tick.k.mul(oneOverSqrtN);

            for (uint256 i = 0; i < nTokens; i++) {
                int256 orth = (int256(s) * u[i]) / int256(FixedPointMath.ONE);
                int256 reserve = int256(kPerToken) + orth;
                require(reserve >= 0, "Neg reserve");
                tick.reserves[i] = uint256(reserve);
            }

            require(_checkSphereInvariant(tickId), "Boundary sphere violated");
            require(isOnBoundary(tickId), "Boundary plane violated");
        }

        // Update consolidated interior reserves: x_int = alpha_int*v + (||w_total||-||w_bound||)*u
        uint256 alphaTotal = sumTotal.mul(oneOverSqrtN);
        require(alphaTotal + TOLERANCE >= state.kBoundTotal, "Alpha underflow");
        uint256 alphaInt = alphaTotal > state.kBoundTotal ? alphaTotal - state.kBoundTotal : 0;

        require(orthNorm + TOLERANCE >= state.sBoundTotal, "Bad w split");
        uint256 wIntMag = orthNorm > state.sBoundTotal ? orthNorm - state.sBoundTotal : 0;

        uint256 alphaIntPerToken = alphaInt.mul(oneOverSqrtN);
        uint256[] memory xInt = new uint256[](nTokens);
        for (uint256 i = 0; i < nTokens; i++) {
            int256 orth = (int256(wIntMag) * u[i]) / int256(FixedPointMath.ONE);
            int256 reserve = int256(alphaIntPerToken) + orth;
            require(reserve >= 0, "Neg interior");
            xInt[i] = uint256(reserve);
        }

        // Deconsolidate interior ticks proportionally by r
        require(state.rInt > 0, "Zero rInt");
        for (uint256 t = 0; t < state.interiorIds.length; t++) {
            uint256 tickId = state.interiorIds[t];
            Tick storage tick = ticks[tickId];

            for (uint256 i = 0; i < nTokens; i++) {
                tick.reserves[i] = xInt[i].mul(tick.r).div(state.rInt);
            }

            require(_checkSphereInvariant(tickId), "Interior sphere violated");
            if (tick.k > 0) {
                uint256 dotProduct = 0;
                for (uint256 i = 0; i < nTokens; i++) {
                    dotProduct += tick.reserves[i].mul(oneOverSqrtN);
                }
                require(dotProduct <= tick.k + TOLERANCE, "Interior outside boundary");
            }
        }
    }

    function _absInt(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    // ============ Internal Trading Functions ============

    /**
     * @notice Execute trade on a single tick
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
        require(xIn <= r && xOut <= r, "Out of range");

        // Quadratic formula for sphere invariant
        uint256 rMinusXIn = r - xIn;
        uint256 rMinusXOut = r - xOut;

        uint256 term1 = rMinusXOut.mul(rMinusXOut);
        uint256 term2 = amountIn.mul(amountIn);
        uint256 term3 = (2 * FixedPointMath.ONE).mul(rMinusXIn).mul(amountIn);

        uint256 underSqrt = term1 + term3;
        require(underSqrt > term2, "Invalid trade: negative discriminant");
        underSqrt -= term2;

        uint256 sqrtTerm = underSqrt.sqrt();
        require(sqrtTerm > rMinusXOut, "Invalid trade: non-positive output");

        amountOut = sqrtTerm - rMinusXOut;

        // Update reserves
        tick.reserves[inIdx] = xIn + amountIn;
        tick.reserves[outIdx] = xOut - amountOut;

        // Verify invariant
        require(_checkSphereInvariant(tickId), "Sphere invariant violated");
    }

    /**
     * @notice Trade on consolidated ticks (interior consolidation)
     */
    function _tradeConsolidated(
        uint256[] memory tickIds,
        uint256 inIdx,
        uint256 amountIn,
        uint256 outIdx
    ) internal returns (uint256 amountOut) {
        require(tickIds.length >= 2, "Need at least 2 ticks to consolidate");

        // Step 1: Consolidate ticks
        ConsolidationCache memory cache = _consolidateInteriorTicks(tickIds);

        // Step 2: Trade on consolidated tick
        uint256 combinedR = cache.combinedR;
        uint256 xIn = cache.combinedReserves[inIdx];
        uint256 xOut = cache.combinedReserves[outIdx];

        // Use quadratic formula on consolidated tick
        uint256 rMinusXIn = combinedR - xIn;
        uint256 rMinusXOut = combinedR - xOut;

        uint256 term1 = rMinusXOut.mul(rMinusXOut);
        uint256 term2 = amountIn.mul(amountIn);
        uint256 term3 = (2 * FixedPointMath.ONE).mul(rMinusXIn).mul(amountIn);

        uint256 underSqrt = term1 + term3;
        require(underSqrt > term2, "Invalid trade");
        underSqrt -= term2;

        uint256 sqrtTerm = underSqrt.sqrt();
        amountOut = sqrtTerm - rMinusXOut;

        // Step 3: Update consolidated reserves
        cache.combinedReserves[inIdx] = xIn + amountIn;
        cache.combinedReserves[outIdx] = xOut - amountOut;

        // Step 4: Deconsolidate back to constituent ticks
        _deconsolidateInteriorTicks(cache, tickIds);

        emit TicksConsolidated(tickIds, combinedR);
    }

    // ============ Consolidation Functions ============

    /**
     * @notice Consolidate multiple interior ticks
     * @dev Combines ticks: r_combined = r1 + r2, x_combined = x1 + x2
     */
    function _consolidateInteriorTicks(uint256[] memory tickIds)
        internal
        view
        returns (ConsolidationCache memory cache)
    {
        cache.tickIds = tickIds;
        cache.weights = new uint256[](tickIds.length);
        cache.combinedReserves = new uint256[](nTokens);
        cache.combinedR = 0;

        // Sum up r and reserves
        for (uint256 i = 0; i < tickIds.length; i++) {
            Tick storage tick = ticks[tickIds[i]];
            require(tick.tickType == TickType.Interior, "Only interior ticks");

            cache.combinedR += tick.r;

            for (uint256 j = 0; j < nTokens; j++) {
                cache.combinedReserves[j] += tick.reserves[j];
            }
        }

        // Calculate weights for deconsolidation
        for (uint256 i = 0; i < tickIds.length; i++) {
            Tick storage tick = ticks[tickIds[i]];
            cache.weights[i] = tick.r.div(cache.combinedR);
        }
    }

    /**
     * @notice Deconsolidate reserves back to constituent ticks
     * @dev Splits proportionally: x_i = x_combined * (r_i / r_combined)
     */
    function _deconsolidateInteriorTicks(
        ConsolidationCache memory cache,
        uint256[] memory tickIds
    ) internal {
        for (uint256 i = 0; i < tickIds.length; i++) {
            Tick storage tick = ticks[tickIds[i]];

            for (uint256 j = 0; j < nTokens; j++) {
                tick.reserves[j] = cache.combinedReserves[j].mul(cache.weights[i]);
            }

            // Verify invariant
            require(_checkSphereInvariant(tickIds[i]), "Invariant violated after deconsolidation");
        }
    }

    /**
     * @notice Consolidate multiple boundary ticks
     * @dev Uses boundary radii: s = sqrt(r² - (k - r*sqrt(n))²)
     */
    function _consolidateBoundaryTicks(uint256[] memory tickIds)
        internal
        view
        returns (ConsolidationCache memory cache)
    {
        cache.tickIds = tickIds;
        cache.weights = new uint256[](tickIds.length);
        cache.combinedReserves = new uint256[](nTokens);
        cache.combinedR = 0;

        uint256[] memory boundaryRadii = new uint256[](tickIds.length);
        uint256 totalBoundaryRadius = 0;

        // Calculate boundary radii
        for (uint256 i = 0; i < tickIds.length; i++) {
            Tick storage tick = ticks[tickIds[i]];
            require(tick.tickType == TickType.Boundary, "Only boundary ticks");

            boundaryRadii[i] = _boundaryOrthogonalRadius(tick.r, tick.k);
            totalBoundaryRadius += boundaryRadii[i];
        }

        // Calculate combined radius and reserves
        for (uint256 i = 0; i < tickIds.length; i++) {
            Tick storage tick = ticks[tickIds[i]];
            uint256 weight = boundaryRadii[i].div(totalBoundaryRadius);
            cache.weights[i] = weight;

            cache.combinedR += tick.r.mul(weight);

            for (uint256 j = 0; j < nTokens; j++) {
                cache.combinedReserves[j] += tick.reserves[j].mul(weight);
            }
        }
    }

    /**
     * @notice Deconsolidate boundary ticks
     */
    function _deconsolidateBoundaryTicks(
        ConsolidationCache memory cache,
        uint256[] memory tickIds
    ) internal {
        for (uint256 i = 0; i < tickIds.length; i++) {
            Tick storage tick = ticks[tickIds[i]];

            // Update reserves proportionally
            for (uint256 j = 0; j < nTokens; j++) {
                tick.reserves[j] = cache.combinedReserves[j].mul(cache.weights[i]);
            }

            // Verify invariant and boundary constraint
            require(_checkSphereInvariant(tickIds[i]), "Invariant violated");
            require(isOnBoundary(tickIds[i]), "Boundary constraint violated");
        }
    }

    // ============ Torus Consolidation ============

    /**
     * @notice Calculate torus invariant error
     * @dev Returns how far the current state is from satisfying the torus invariant
     *      Torus invariant: parallel_term² + orthogonal_term² = r_interior²
     */
    function _torusInvariantError(
        uint256[] memory combinedReserves,
        uint256 interiorR,
        uint256 boundaryR,
        uint256 boundaryK
    ) internal view returns (int256) {
        // Calculate total parallel component: sum(x) / sqrt(n)
        uint256 sumReserves = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            sumReserves += combinedReserves[i];
        }
        uint256 parallelComponent = sumReserves.div(sqrtN);

        // Calculate total orthogonal norm: sqrt(sum(x²) - (sum(x))² / n)
        uint256 sumSquares = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            sumSquares += combinedReserves[i].mul(combinedReserves[i]);
        }
        uint256 sumSquaredOverN = sumReserves.mul(sumReserves).div(nTokens * FixedPointMath.ONE);
        uint256 orthogonalNormSquared = sumSquares - sumSquaredOverN;

        // Calculate boundary orthogonal radius: s = sqrt(r² - (k - r*sqrt(n))²)
        uint256 kMinusRSqrtN = boundaryK > boundaryR.mul(sqrtN)
            ? boundaryK - boundaryR.mul(sqrtN)
            : boundaryR.mul(sqrtN) - boundaryK;
        uint256 kTermSquared = kMinusRSqrtN.mul(kMinusRSqrtN);
        uint256 boundaryRSquared = boundaryR.mul(boundaryR);

        require(boundaryRSquared >= kTermSquared, "Invalid boundary tick geometry");
        uint256 boundaryOrthogonalRadiusSquared = boundaryRSquared - kTermSquared;

        // Torus invariant components
        // parallel_term = (sum(x)/sqrt(n) - k - r_interior*sqrt(n))²
        uint256 targetParallel = boundaryK + interiorR.mul(sqrtN);
        int256 parallelDiff = int256(parallelComponent) - int256(targetParallel);
        int256 parallelTerm = parallelDiff * parallelDiff / int256(FixedPointMath.ONE);

        // orthogonal_term = (||x_orthogonal|| - s_boundary)²
        uint256 orthogonalNorm = orthogonalNormSquared.sqrt();
        uint256 boundaryOrthogonalRadius = boundaryOrthogonalRadiusSquared.sqrt();
        int256 orthogonalDiff = int256(orthogonalNorm) - int256(boundaryOrthogonalRadius);
        int256 orthogonalTerm = orthogonalDiff * orthogonalDiff / int256(FixedPointMath.ONE);

        // Return: parallel_term + orthogonal_term - r_interior²
        int256 interiorRSquared = int256(interiorR.mul(interiorR));
        return parallelTerm + orthogonalTerm - interiorRSquared;
    }

    /**
     * @notice Newton's method solver for torus trades
     * @dev Solves for output amount that maintains torus invariant
     */
    function _newtonSolveTorusTrade(
        uint256[] memory reserves,
        uint256 outIdx,
        uint256 initialGuess,
        uint256 interiorR,
        uint256 boundaryR,
        uint256 boundaryK
    ) internal view returns (uint256) {
        uint256 x = initialGuess;
        uint256[] memory testReserves = new uint256[](nTokens);

        for (uint256 iter = 0; iter < MAX_ITERATIONS; iter++) {
            // Copy reserves and update output token
            for (uint256 i = 0; i < nTokens; i++) {
                testReserves[i] = reserves[i];
            }
            testReserves[outIdx] = x;

            // Calculate invariant error at current x
            int256 fx = _torusInvariantError(testReserves, interiorR, boundaryR, boundaryK);

            // Check if converged
            if (fx < 0) fx = -fx; // abs value
            if (uint256(fx) < TOLERANCE) {
                return x;
            }

            // Calculate derivative using finite difference
            testReserves[outIdx] = x + FixedPointMath.ONE / 1000; // Small step
            int256 fxPlusDelta = _torusInvariantError(testReserves, interiorR, boundaryR, boundaryK);

            int256 dfx = (fxPlusDelta - fx) * 1000; // Derivative

            if (dfx == 0) {
                // Avoid division by zero, return current best guess
                return x;
            }

            // Newton's update: x_new = x - f(x) / f'(x)
            int256 delta = fx * int256(FixedPointMath.ONE) / dfx;

            if (delta < 0) {
                if (x < uint256(-delta)) {
                    return x; // Avoid underflow
                }
                x = x - uint256(-delta);
            } else {
                x = x + uint256(delta);
            }

            // Ensure x stays in valid range
            if (x > reserves[outIdx] * 2) {
                x = reserves[outIdx];
            }
        }

        return x;
    }

    /**
     * @notice Trade on torus consolidation using Newton's method
     * @dev Torus invariant is more complex than sphere, requires iterative solving
     */
    function _tradeTorusConsolidated(
        uint256 interiorTickId,
        uint256 boundaryTickId,
        uint256 inIdx,
        uint256 amountIn,
        uint256 outIdx
    ) internal returns (uint256 amountOut) {
        Tick storage interiorTick = ticks[interiorTickId];
        Tick storage boundaryTick = ticks[boundaryTickId];

        // Combined reserves
        uint256[] memory combinedReserves = new uint256[](nTokens);
        for (uint256 i = 0; i < nTokens; i++) {
            combinedReserves[i] = interiorTick.reserves[i] + boundaryTick.reserves[i];
        }

        // Update input reserve
        uint256 xOutBefore = combinedReserves[outIdx];
        combinedReserves[inIdx] += amountIn;

        // Solve for new output reserve using Newton's method
        uint256 newXOut = _newtonSolveTorusTrade(
            combinedReserves,
            outIdx,
            xOutBefore, // Initial guess
            interiorTick.r,
            boundaryTick.r,
            boundaryTick.k
        );

        require(newXOut < xOutBefore, "Invalid torus trade result");
        amountOut = xOutBefore - newXOut;
        combinedReserves[outIdx] = newXOut;

        // Deconsolidate using proper torus geometry
        _deconsolidateTorusTicks(combinedReserves, interiorTickId, boundaryTickId);
    }

    /**
     * @notice Deconsolidate torus back to interior + boundary ticks
     * @dev Uses proper torus geometry to split reserves
     */
    function _deconsolidateTorusTicks(
        uint256[] memory combinedReserves,
        uint256 interiorTickId,
        uint256 boundaryTickId
    ) internal {
        Tick storage interiorTick = ticks[interiorTickId];
        Tick storage boundaryTick = ticks[boundaryTickId];

        // Calculate orthogonal component (perpendicular to v)
        uint256 sumReserves = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            sumReserves += combinedReserves[i];
        }

        // orthogonal = x - (sum(x)/n) * (1, 1, ..., 1)
        uint256[] memory orthogonalComponent = new uint256[](nTokens);
        uint256 avgReserve = sumReserves / nTokens;
        uint256 orthogonalNormSquared = 0;

        for (uint256 i = 0; i < nTokens; i++) {
            if (combinedReserves[i] > avgReserve) {
                orthogonalComponent[i] = combinedReserves[i] - avgReserve;
            } else {
                orthogonalComponent[i] = avgReserve - combinedReserves[i];
            }
            orthogonalNormSquared += orthogonalComponent[i].mul(orthogonalComponent[i]);
        }
        uint256 orthogonalNorm = orthogonalNormSquared.sqrt();

        // Boundary parallel component: k * v
        uint256 boundaryParallelPerToken = boundaryTick.k.div(sqrtN);

        // Boundary orthogonal component magnitude
        uint256 kMinusRSqrtN = boundaryTick.k > boundaryTick.r.mul(sqrtN)
            ? boundaryTick.k - boundaryTick.r.mul(sqrtN)
            : boundaryTick.r.mul(sqrtN) - boundaryTick.k;
        uint256 boundaryOrthogonalMag = (boundaryTick.r.mul(boundaryTick.r) - kMinusRSqrtN.mul(kMinusRSqrtN)).sqrt();

        // Split orthogonal component
        for (uint256 i = 0; i < nTokens; i++) {
            // Boundary orthogonal
            uint256 boundaryOrthogonal = orthogonalNorm > 0
                ? orthogonalComponent[i].mul(boundaryOrthogonalMag).div(orthogonalNorm)
                : 0;

            // Interior orthogonal
            uint256 interiorOrthogonal = orthogonalComponent[i] > boundaryOrthogonal
                ? orthogonalComponent[i] - boundaryOrthogonal
                : 0;

            // Interior parallel component magnitude
            uint256 interiorOrthogonalForParallel = interiorOrthogonal;
            uint256 interiorParallelMag = interiorTick.r.mul(interiorTick.r) > interiorOrthogonalForParallel.mul(interiorOrthogonalForParallel)
                ? (interiorTick.r.mul(interiorTick.r) - interiorOrthogonalForParallel.mul(interiorOrthogonalForParallel)).sqrt()
                : 0;
            uint256 interiorParallelPerToken = interiorTick.r > interiorParallelMag.div(sqrtN)
                ? interiorTick.r - interiorParallelMag.div(sqrtN)
                : 0;

            // Reconstruct reserves
            boundaryTick.reserves[i] = boundaryParallelPerToken + boundaryOrthogonal;
            interiorTick.reserves[i] = interiorParallelPerToken + interiorOrthogonal;
        }
    }

    // ============ Tick-Crossing Logic ============

    /**
     * @notice Execute trade with boundary crossing detection and segmentation
     * @dev Segments trade if it would cross tick boundaries
     */
    function _tradeWithCrossing(
        uint256 tickId,
        uint256 inIdx,
        uint256 amountIn,
        uint256 outIdx,
        uint256 kMinInterior,
        uint256 kMaxBoundary
    ) internal returns (uint256 amountOut, uint256 remaining) {
        Tick storage tick = ticks[tickId];

        // Save initial state
        uint256[] memory initialReserves = new uint256[](nTokens);
        for (uint256 i = 0; i < nTokens; i++) {
            initialReserves[i] = tick.reserves[i];
        }

        // Try full trade
        try this._tradeSingleTickExternal(tickId, inIdx, amountIn, outIdx) returns (uint256 out) {
            // Trade succeeded, check if crossed boundary
            uint256 newAlpha = _calculateAlpha(tick.reserves);

            if (newAlpha >= kMaxBoundary && newAlpha <= kMinInterior) {
                // No crossing, trade is valid
                return (out, 0);
            }

            // Crossed boundary, need to segment - restore state
            for (uint256 i = 0; i < nTokens; i++) {
                tick.reserves[i] = initialReserves[i];
            }

            // Find crossover amount
            uint256 targetK = newAlpha > kMinInterior ? kMinInterior : kMaxBoundary;
            uint256 crossoverAmount = _findCrossoverAmount(tickId, inIdx, outIdx, targetK);

            if (crossoverAmount > 0 && crossoverAmount < amountIn) {
                // Execute trade up to crossover point
                amountOut = _tradeSingleTick(tickId, inIdx, crossoverAmount, outIdx);
                remaining = amountIn - crossoverAmount;
                return (amountOut, remaining);
            }

            // Couldn't find crossover, execute partial trade
            amountOut = _tradeSingleTick(tickId, inIdx, amountIn / 2, outIdx);
            remaining = amountIn / 2;
            return (amountOut, remaining);
        } catch {
            // Trade failed completely
            return (0, amountIn);
        }
    }

    /**
     * @notice Calculate alpha (parallel component) for reserves
     * @dev alpha = dot(reserves, v) where v = (1/√n, ..., 1/√n)
     */
    function _calculateAlpha(uint256[] memory reserves) internal view returns (uint256) {
        uint256 dotProduct = 0;
        for (uint256 i = 0; i < reserves.length; i++) {
            dotProduct += reserves[i].mul(oneOverSqrtN);
        }
        return dotProduct;
    }

    /**
     * @notice Find trade amount that reaches exact crossover point
     * @dev Uses quadratic formula to find exact crossing amount
     */
    function _findCrossoverAmount(
        uint256 tickId,
        uint256 inIdx,
        uint256 outIdx,
        uint256 targetK
    ) internal view returns (uint256) {
        Tick storage tick = ticks[tickId];

        uint256 currentAlpha = _calculateAlpha(tick.reserves);
        int256 alphaDiff = int256(targetK) - int256(currentAlpha);

        // Quadratic equation coefficients
        // From paper: find d_i such that trade reaches exact target_k
        uint256 r = tick.r;
        uint256 xIn = tick.reserves[inIdx];
        uint256 xOut = tick.reserves[outIdx];

        // a = 2
        int256 a = 2 * int256(FixedPointMath.ONE);

        // b = -2*(r - x_in) + 2*(r - x_out)
        int256 b = -2 * int256(r - xIn) + 2 * int256(r - xOut);

        // Calculate c term
        int256 sumOtherSquares = 0;
        for (uint256 k = 0; k < nTokens; k++) {
            if (k != inIdx && k != outIdx) {
                int256 diff = int256(r) - int256(tick.reserves[k]);
                sumOtherSquares += (diff * diff) / int256(FixedPointMath.ONE);
            }
        }

        int256 term1 = (int256(r) - int256(xIn)) * (int256(r) - int256(xIn)) / int256(FixedPointMath.ONE);
        int256 term2Num = int256(r) - int256(xOut) + (int256(sqrtN) * alphaDiff) / int256(FixedPointMath.ONE);
        int256 term2 = (term2Num * term2Num) / int256(FixedPointMath.ONE);
        int256 c = term1 + term2 + sumOtherSquares - int256(r.mul(r));

        // Solve quadratic
        int256 discriminant = (b * b) / int256(FixedPointMath.ONE) - (4 * a * c) / int256(FixedPointMath.ONE);

        if (discriminant < 0) {
            return 0;
        }

        uint256 sqrtDisc = uint256(discriminant).sqrt();

        // Try both roots
        int256 root1 = (-b + int256(sqrtDisc)) * int256(FixedPointMath.ONE) / (2 * a);
        int256 root2 = (-b - int256(sqrtDisc)) * int256(FixedPointMath.ONE) / (2 * a);

        // Return positive root
        if (root1 > 0) {
            return uint256(root1);
        } else if (root2 > 0) {
            return uint256(root2);
        }

        return 0;
    }

    /**
     * @notice External wrapper for single tick trade (for try/catch)
     */
    function _tradeSingleTickExternal(
        uint256 tickId,
        uint256 inIdx,
        uint256 amountIn,
        uint256 outIdx
    ) external returns (uint256) {
        require(msg.sender == address(this), "Internal only");
        return _tradeSingleTick(tickId, inIdx, amountIn, outIdx);
    }

    // ============ Helper Functions ============

    /**
     * @notice Find ticks with parallel reserve vectors
     * @dev Two ticks are parallel if their direction vectors are proportional
     */
    function _findParallelTicks(uint256 tokenInIdx, uint256 tokenOutIdx)
        internal
        view
        returns (uint256[] memory parallelTickIds)
    {
        if (ticks.length <= 1) {
            parallelTickIds = new uint256[](0);
            return parallelTickIds;
        }

        // Find first interior tick as reference with non-zero reserves for the trade pair
        uint256 refTickId = type(uint256).max;
        for (uint256 i = 0; i < ticks.length; i++) {
            if (ticks[i].tickType == TickType.Interior &&
                ticks[i].totalShares > 0 &&
                ticks[i].reserves[tokenInIdx] > 0 &&
                ticks[i].reserves[tokenOutIdx] > 0) {
                refTickId = i;
                break;
            }
        }

        if (refTickId == type(uint256).max) {
            // No interior ticks with liquidity for this trade pair
            parallelTickIds = new uint256[](0);
            return parallelTickIds;
        }

        // Count parallel ticks with sufficient reserves
        uint256 count = 1; // Include reference tick
        for (uint256 i = 0; i < ticks.length; i++) {
            if (i != refTickId &&
                ticks[i].tickType == TickType.Interior &&
                ticks[i].totalShares > 0 &&
                ticks[i].reserves[tokenInIdx] > 0 &&
                ticks[i].reserves[tokenOutIdx] > 0 &&
                _areParallel(refTickId, i)) {
                count++;
            }
        }

        // Collect parallel tick IDs
        parallelTickIds = new uint256[](count);
        parallelTickIds[0] = refTickId;
        uint256 idx = 1;
        for (uint256 i = 0; i < ticks.length; i++) {
            if (i != refTickId &&
                ticks[i].tickType == TickType.Interior &&
                ticks[i].totalShares > 0 &&
                ticks[i].reserves[tokenInIdx] > 0 &&
                ticks[i].reserves[tokenOutIdx] > 0 &&
                _areParallel(refTickId, i)) {
                parallelTickIds[idx] = i;
                idx++;
            }
        }
    }

    /**
     * @notice Check if two ticks have parallel reserve vectors
     * @dev Compares direction vectors: d = (r - x) / ||r - x||
     *      Ticks are parallel if normalized direction vectors have dot product ≈ 1
     */
    function _areParallel(uint256 tickId1, uint256 tickId2)
        internal
        view
        returns (bool)
    {
        Tick storage tick1 = ticks[tickId1];
        Tick storage tick2 = ticks[tickId2];

        // Both must be interior ticks
        if (tick1.tickType != TickType.Interior || tick2.tickType != TickType.Interior) {
            return false;
        }

        // Compute direction vectors: d_i = r - x_i
        uint256[] memory d1 = new uint256[](nTokens);
        uint256[] memory d2 = new uint256[](nTokens);

        for (uint256 i = 0; i < nTokens; i++) {
            d1[i] = tick1.r - tick1.reserves[i];
            d2[i] = tick2.r - tick2.reserves[i];
        }

        // Normalize direction vectors
        uint256 norm1 = _vectorNorm(d1);
        uint256 norm2 = _vectorNorm(d2);

        if (norm1 == 0 || norm2 == 0) {
            return false;
        }

        for (uint256 i = 0; i < nTokens; i++) {
            d1[i] = d1[i].div(norm1);
            d2[i] = d2[i].div(norm2);
        }

        // Check if dot product is approximately 1 (parallel, same direction)
        // Note: We only consolidate same-direction parallel ticks, not anti-parallel
        uint256 dotProd = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            dotProd += d1[i].mul(d2[i]);
        }

        // Require very high precision - must be within 0.1% of 1.0
        // This ensures ticks are truly parallel, not just close
        if (dotProd < FixedPointMath.ONE) {
            uint256 deficit = FixedPointMath.ONE - dotProd;
            return deficit < (FixedPointMath.ONE / 1000); // 0.1% tolerance
        } else {
            uint256 excess = dotProd - FixedPointMath.ONE;
            return excess < (FixedPointMath.ONE / 1000); // 0.1% tolerance
        }
    }

    /**
     * @notice Compute vector norm (L2 norm)
     */
    function _vectorNorm(uint256[] memory vec) internal pure returns (uint256) {
        uint256 sumSquares = 0;
        for (uint256 i = 0; i < vec.length; i++) {
            sumSquares += vec[i].mul(vec[i]);
        }
        return sumSquares.sqrt();
    }

    /**
     * @notice Find the largest tick by radius
     */
    function _findLargestTick() internal view returns (uint256 largestId) {
        uint256 largestR = 0;
        largestId = type(uint256).max;
        for (uint256 i = 0; i < ticks.length; i++) {
            if (ticks[i].totalShares == 0) continue;
            if (ticks[i].r > largestR) {
                largestR = ticks[i].r;
                largestId = i;
            }
        }
    }

    /**
     * @notice Check if tick satisfies sphere invariant
     */
    function _checkSphereInvariant(uint256 tickId) internal view returns (bool) {
        Tick storage tick = ticks[tickId];

        uint256 sumSquares = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            uint256 diff = tick.r > tick.reserves[i]
                ? tick.r - tick.reserves[i]
                : tick.reserves[i] - tick.r;
            sumSquares += diff.mul(diff);
        }

        uint256 rSquared = tick.r.mul(tick.r);

        uint256 delta = sumSquares > rSquared
            ? sumSquares - rSquared
            : rSquared - sumSquares;

        return delta < TOLERANCE;
    }

    /**
     * @notice Check if tick is on boundary constraint
     */
    function isOnBoundary(uint256 tickId) public view returns (bool) {
        Tick storage tick = ticks[tickId];

        if (tick.k == 0) {
            return false;
        }

        // Check: dot(reserves, v) = k where v = (1/sqrt(n), ..., 1/sqrt(n))
        uint256 dotProduct = 0;
        for (uint256 i = 0; i < nTokens; i++) {
            dotProduct += tick.reserves[i].mul(oneOverSqrtN);
        }

        uint256 delta = dotProduct > tick.k
            ? dotProduct - tick.k
            : tick.k - dotProduct;

        return delta < TOLERANCE;
    }

    function isPinned(uint256 tickId) external view returns (bool) {
        require(tickId < ticks.length, "Invalid tick");
        return ticks[tickId].pinned;
    }

    /**
     * @notice Update global state after any tick modification
     */
    function _updateGlobalState() internal {
        // Reset global state
        for (uint256 i = 0; i < nTokens; i++) {
            globalState.totalReserves[i] = 0;
        }
        globalState.totalR = 0;
        globalState.totalRSquared = 0;

        // Recompute from all ticks
        for (uint256 tickId = 0; tickId < ticks.length; tickId++) {
            Tick storage tick = ticks[tickId];
            if (tick.totalShares == 0) continue;

            globalState.totalR += tick.r;
            globalState.totalRSquared += tick.r.mul(tick.r);

            for (uint256 i = 0; i < nTokens; i++) {
                globalState.totalReserves[i] += tick.reserves[i];
            }
        }
    }

    /**
     * @notice Geometric mean for initial shares
     */
    function _geometricMean(uint256[] calldata values) internal view returns (uint256) {
        uint256 product = FixedPointMath.ONE;
        for (uint256 i = 0; i < values.length; i++) {
            product = product.mul(values[i]);
        }

        // Newton's method for nth root
        uint256 sum = 0;
        for (uint256 i = 0; i < values.length; i++) {
            sum += values[i];
        }
        uint256 x = sum / nTokens;

        for (uint256 iter = 0; iter < 10; iter++) {
            uint256 xPowNMinus1 = FixedPointMath.ONE;
            for (uint256 j = 0; j < nTokens - 1; j++) {
                xPowNMinus1 = xPowNMinus1.mul(x);
            }

            uint256 numerator = ((nTokens - 1) * FixedPointMath.ONE).mul(x)
                + product.div(xPowNMinus1);
            x = numerator / nTokens;
        }

        return x;
    }

    // ============ View Functions ============

    function getPrice(uint256 tokenAIdx, uint256 tokenBIdx)
        external
        view
        returns (uint256)
    {
        require(tokenAIdx < nTokens && tokenBIdx < nTokens, "Invalid token");

        if (ticks.length == 0) {
            return FixedPointMath.ONE;
        }

        uint256 largestTickId = _findLargestTick();
        if (largestTickId == type(uint256).max) {
            return FixedPointMath.ONE;
        }
        Tick storage tick = ticks[largestTickId];

        uint256 numerator = tick.r - tick.reserves[tokenBIdx];
        uint256 denominator = tick.r - tick.reserves[tokenAIdx];

        return numerator.div(denominator);
    }

    function getTickInfo(uint256 tickId)
        external
        view
        returns (
            uint256 r,
            uint256 k,
            TickType tickType,
            uint256 totalShares,
            uint256[] memory reserves
        )
    {
        require(tickId < ticks.length, "Invalid tick");
        Tick storage tick = ticks[tickId];
        return (tick.r, tick.k, tick.tickType, tick.totalShares, tick.reserves);
    }

    function getLPShares(uint256 tickId, address lp)
        external
        view
        returns (uint256)
    {
        require(tickId < ticks.length, "Invalid tick");
        return ticks[tickId].lpShares[lp];
    }

    function getTickCount() external view returns (uint256) {
        return ticks.length;
    }

    function getGlobalState()
        external
        view
        returns (
            uint256[] memory totalReserves,
            uint256 totalR,
            uint256 totalRSquared
        )
    {
        return (
            globalState.totalReserves,
            globalState.totalR,
            globalState.totalRSquared
        );
    }

    function checkInvariant(uint256 tickId) external view returns (bool) {
        require(tickId < ticks.length, "Invalid tick");
        return _checkSphereInvariant(tickId);
    }
}
