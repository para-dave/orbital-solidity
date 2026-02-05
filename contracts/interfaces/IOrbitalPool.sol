// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOrbitalPool
 * @notice Interface for Orbital AMM Pool
 * @dev Defines the core functions for interacting with Orbital pools
 */
interface IOrbitalPool {
    // ============ Events ============

    enum TickType {
        Interior,
        Boundary
    }

    event TickCreated(uint256 indexed tickId, uint256 r, uint256 k, TickType tickType);
    event LiquidityAdded(
        uint256 indexed tickId,
        address indexed lp,
        uint256[] amounts,
        uint256 shares
    );
    event LiquidityRemoved(
        uint256 indexed tickId,
        address indexed lp,
        uint256 shares,
        uint256[] amounts
    );
    event Swap(
        address indexed trader,
        uint256 tokenInIdx,
        uint256 amountIn,
        uint256 tokenOutIdx,
        uint256 amountOut
    );

    // ============ Core Functions ============

    /**
     * @notice Create a new liquidity tick
     * @param r Radius parameter (fixed-point)
     * @param k Boundary parameter (fixed-point)
     * @return tickId The ID of the newly created tick
     */
    function createTick(uint256 r, uint256 k) external returns (uint256 tickId);

    /**
     * @notice Add liquidity to a tick
     * @param tickId The tick to add liquidity to
     * @param amounts Array of token amounts to deposit
     * @return shares Number of LP shares minted
     */
    function addLiquidity(uint256 tickId, uint256[] calldata amounts)
        external
        returns (uint256 shares);

    /**
     * @notice Remove liquidity from a tick
     * @param tickId The tick to remove liquidity from
     * @param shares Number of shares to burn
     * @return amounts Array of token amounts returned
     */
    function removeLiquidity(uint256 tickId, uint256 shares)
        external
        returns (uint256[] memory amounts);

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
    ) external returns (uint256 amountOut);

    // ============ View Functions ============

    /**
     * @notice Get the price of tokenA in terms of tokenB
     * @param tokenAIdx Index of token A
     * @param tokenBIdx Index of token B
     * @return price Fixed-point price
     */
    function getPrice(uint256 tokenAIdx, uint256 tokenBIdx)
        external
        view
        returns (uint256 price);

    /**
     * @notice Get detailed tick information
     * @param tickId The tick ID
     * @return r Radius parameter
     * @return k Boundary parameter
     * @return tickType Tick type (interior/boundary)
     * @return totalShares Total LP shares
     * @return reserves Token reserves array
     */
    function getTickInfo(uint256 tickId)
        external
        view
        returns (
            uint256 r,
            uint256 k,
            TickType tickType,
            uint256 totalShares,
            uint256[] memory reserves
        );

    /**
     * @notice Get LP shares for an address in a tick
     * @param tickId The tick ID
     * @param lp LP address
     * @return shares Number of shares owned
     */
    function getLPShares(uint256 tickId, address lp)
        external
        view
        returns (uint256 shares);

    /**
     * @notice Check if a tick's sphere invariant holds
     * @param tickId The tick ID
     * @return valid True if invariant is satisfied
     */
    function checkInvariant(uint256 tickId) external view returns (bool valid);

    /**
     * @notice Check if a tick is on its boundary plane (dot(reserves,v) == k)
     * @param tickId The tick ID
     */
    function isOnBoundary(uint256 tickId) external view returns (bool);

    /**
     * @notice Whether a tick is currently pinned to its boundary
     * @param tickId The tick ID
     */
    function isPinned(uint256 tickId) external view returns (bool);

    /**
     * @notice Get the number of ticks in the pool
     * @return count Number of ticks
     */
    function getTickCount() external view returns (uint256 count);

    /**
     * @notice Get the number of tokens in the pool
     * @return Number of tokens
     */
    function nTokens() external view returns (uint256);

    function getGlobalState()
        external
        view
        returns (uint256[] memory totalReserves, uint256 totalR, uint256 totalRSquared);

    /**
     * @notice Get token address at index
     * @param tokenIdx Token index
     * @return token Token address
     */
    function tokens(uint256 tokenIdx) external view returns (address token);

    /**
     * @notice Get pre-computed sqrt(n)
     * @return sqrtN Fixed-point sqrt(n)
     */
    function sqrtN() external view returns (uint256);

    /**
     * @notice Get pre-computed 1 - 1/sqrt(n)
     * @return value Fixed-point value
     */
    function oneMinusOneOverSqrtN() external view returns (uint256);

    /**
     * @notice Get pre-computed 1/sqrt(n)
     */
    function oneOverSqrtN() external view returns (uint256);
}
