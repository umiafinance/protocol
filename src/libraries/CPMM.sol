// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title CPMM
/// @notice A library for CPMM (Constant Product Market Maker) calculations
library CPMM {
    // ─────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────

    struct State {
        uint256 reserve0; // virtualVenture reserve
        uint256 reserve1; // virtualMoney reserve
    }

    struct SwapResult {
        uint256 amountIn;
        uint256 amountOut;
        uint256 priceBeforeX96;
        uint256 priceAfterX96;
        uint256 priceImpactBps;
    }

    struct AddLiquidityResult {
        uint256 actualAmount0;
        uint256 actualAmount1;
    }

    // ─────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────

    /// @notice Default maximum price impact in basis points (5%)
    uint256 public constant DEFAULT_MAX_PRICE_IMPACT_BPS = 500;

    /// @notice Default liquidity slippage tolerance in basis points (0.5%)
    uint256 public constant DEFAULT_LIQUIDITY_SLIPPAGE_BPS = 50;

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error InsufficientLiquidity();
    error InsufficientReserves();
    error SlippageToleranceExceeded();
    error PriceImpactTooHigh();
    error PriceSlippageExceeded();

    // ─────────────────────────────────────────────────────────
    // Swap Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Execute a swap exact input in a CPMM
    /// @param state The CPMM state (will be modified)
    /// @param amountIn The exact input amount
    /// @param amountOutMin Minimum output amount (slippage protection)
    /// @param maxPriceImpactBps Maximum price impact in basis points
    /// @param zeroForOne If true, swap token0 (virtualVenture) for token1 (virtualMoney)
    /// @return result Swap result with amounts and prices
    function _swapExactIn(
        State storage state,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxPriceImpactBps,
        bool zeroForOne
    ) internal returns (SwapResult memory result) {
        if (state.reserve0 == 0 || state.reserve1 == 0) revert InsufficientLiquidity();

        uint256 reserveIn = zeroForOne ? state.reserve0 : state.reserve1;
        uint256 reserveOut = zeroForOne ? state.reserve1 : state.reserve0;

        // Calculate output amount
        result.amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);

        // Slippage protection: ensure minimum output
        if (result.amountOut < amountOutMin) revert SlippageToleranceExceeded();

        // Calculate price impact
        result.priceImpactBps = _getPriceImpactBps(amountIn, reserveIn);
        if (result.priceImpactBps > maxPriceImpactBps) revert PriceImpactTooHigh();

        // Calculate prices before and after
        result.priceBeforeX96 = _getPriceX96(state.reserve0, state.reserve1, zeroForOne);

        // Update reserves
        if (zeroForOne) {
            state.reserve0 += amountIn;
            state.reserve1 -= result.amountOut;
        } else {
            state.reserve1 += amountIn;
            state.reserve0 -= result.amountOut;
        }

        result.priceAfterX96 = _getPriceX96(state.reserve0, state.reserve1, zeroForOne);
        result.amountIn = amountIn;
    }

    /// @notice Execute a swap exact output in a CPMM
    /// @param state The CPMM state (will be modified)
    /// @param amountOut The exact output amount desired
    /// @param amountInMax Maximum input amount (slippage protection)
    /// @param maxPriceImpactBps Maximum price impact in basis points
    /// @param zeroForOne If true, swap token0 (virtualVenture) for token1 (virtualMoney)
    /// @return result Swap result with amounts and prices
    function _swapExactOut(
        State storage state,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 maxPriceImpactBps,
        bool zeroForOne
    ) internal returns (SwapResult memory result) {
        if (state.reserve0 == 0 || state.reserve1 == 0) revert InsufficientLiquidity();

        uint256 reserveIn = zeroForOne ? state.reserve0 : state.reserve1;
        uint256 reserveOut = zeroForOne ? state.reserve1 : state.reserve0;

        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        // Calculate required input
        uint256 amountIn = _getAmountIn(amountOut, reserveIn, reserveOut);

        // Slippage protection: ensure maximum input not exceeded
        if (amountIn > amountInMax) revert SlippageToleranceExceeded();

        // Calculate price impact
        result.priceImpactBps = _getPriceImpactBps(amountIn, reserveIn);
        if (result.priceImpactBps > maxPriceImpactBps) revert PriceImpactTooHigh();

        result.priceBeforeX96 = _getPriceX96(state.reserve0, state.reserve1, zeroForOne);

        // Update reserves
        if (zeroForOne) {
            state.reserve0 += amountIn;
            state.reserve1 -= amountOut;
        } else {
            state.reserve1 += amountIn;
            state.reserve0 -= amountOut;
        }

        result.priceAfterX96 = _getPriceX96(state.reserve0, state.reserve1, zeroForOne);
        result.amountOut = amountOut;
        result.amountIn = amountIn;
    }

    // ─────────────────────────────────────────────────────────
    // Price Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Get the current price of a CPMM
    /// @param reserve0 Reserve of token0
    /// @param reserve1 Reserve of token1
    /// @param zeroForOne If true, return price of token0 in terms of token1
    /// @return priceX96 The price in Q96 format
    function _getPriceX96(uint256 reserve0, uint256 reserve1, bool zeroForOne)
        internal
        pure
        returns (uint256 priceX96)
    {
        if (reserve0 == 0) return 0;
        if (zeroForOne) {
            // Price of token0 in terms of token1
            priceX96 = FullMath.mulDiv(reserve1, FixedPoint96.Q96, reserve0);
        } else {
            // Price of token1 in terms of token0
            priceX96 = FullMath.mulDiv(reserve0, FixedPoint96.Q96, reserve1);
        }
    }

    /// @notice Calculate expected output and price impact for a swap (view function)
    /// @param reserve0 Reserve of token0
    /// @param reserve1 Reserve of token1
    /// @param amountIn The input amount
    /// @param zeroForOne Swap direction
    /// @return amountOut Expected output amount
    /// @return priceImpactBps Price impact in basis points
    function _quoteSwapExactIn(uint256 reserve0, uint256 reserve1, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint256 amountOut, uint256 priceImpactBps)
    {
        if (reserve0 == 0 || reserve1 == 0) revert InsufficientLiquidity();

        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;

        amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
        priceImpactBps = _getPriceImpactBps(amountIn, reserveIn);
    }

    // ─────────────────────────────────────────────────────────
    // Liquidity Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Add liquidity to a CPMM at a given price with slippage protection
    /// @param state The CPMM state (will be modified)
    /// @param amount0 Desired amount of token0 (virtualVenture)
    /// @param amount1 Desired amount of token1 (virtualMoney)
    /// @param priceX96 The desired price in Q96 format
    /// @param slippageBps Maximum price slippage tolerance in basis points (e.g., 50 = 0.5%)
    /// @return result The actual amounts added
    function _addLiquidity(State storage state, uint256 amount0, uint256 amount1, uint256 priceX96, uint256 slippageBps)
        internal
        returns (AddLiquidityResult memory result)
    {
        result.actualAmount0 = amount0;
        result.actualAmount1 = amount1;

        if (state.reserve0 == 0 && state.reserve1 == 0) {
            // First liquidity: use provided amounts, validate price
            uint256 actualPriceX96 = FullMath.mulDiv(amount1, FixedPoint96.Q96, amount0);
            uint256 priceDiffBps = _calculatePriceDiffBps(priceX96, actualPriceX96);
            if (priceDiffBps > slippageBps) revert PriceSlippageExceeded();

            state.reserve0 = amount0;
            state.reserve1 = amount1;
        } else {
            // Validate current price is within user's expected range
            uint256 currentPriceX96 = FullMath.mulDiv(state.reserve1, FixedPoint96.Q96, state.reserve0);
            uint256 priceDiffBps = _calculatePriceDiffBps(priceX96, currentPriceX96);
            if (priceDiffBps > slippageBps) revert PriceSlippageExceeded();

            // Calculate amounts using actual current price
            uint256 requiredAmount1 = FullMath.mulDiv(amount0, currentPriceX96, FixedPoint96.Q96);

            if (amount1 < requiredAmount1) {
                // Adjust amount0 to match amount1
                result.actualAmount0 = FullMath.mulDiv(amount1, FixedPoint96.Q96, currentPriceX96);
            } else {
                // Adjust amount1 to match amount0
                result.actualAmount1 = requiredAmount1;
            }

            // Add to reserves proportionally
            state.reserve0 += result.actualAmount0;
            state.reserve1 += result.actualAmount1;
        }
    }

    // ─────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────

    /// @notice Calculate the amount out of a CPMM
    /// @param amountIn The amount of input tokens
    /// @param reserveIn The reserve of input tokens in the pool
    /// @param reserveOut The reserve of output tokens in the pool
    /// @return amountOut The amount of output tokens
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        // x*y=k, fee-free.
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();
        uint256 numerator = amountIn * reserveOut;
        uint256 denominator = reserveIn + amountIn;
        amountOut = numerator / denominator;
    }

    /// @notice Calculate the amount in needed for a desired amount out
    /// @param amountOut The desired output amount
    /// @param reserveIn The reserve of input tokens
    /// @param reserveOut The reserve of output tokens
    /// @return amountIn The required input amount
    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();

        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = reserveOut - amountOut;
        amountIn = (numerator / denominator) + 1; // Round up
    }

    /// @notice Calculate price impact of a swap in basis points
    /// @param amountIn The input amount
    /// @param reserveIn The reserve of input tokens
    /// @return priceImpactBps Price impact in basis points
    /// @dev priceImpactBps = amountIn / (reserveIn + amountIn), on the already-post-fee amount passed in.
    function _getPriceImpactBps(uint256 amountIn, uint256 reserveIn) internal pure returns (uint256 priceImpactBps) {
        if (reserveIn == 0) return type(uint256).max;

        uint256 denominator = reserveIn + amountIn;
        priceImpactBps = FullMath.mulDiv(amountIn, 10_000, denominator);
    }

    /// @notice Calculate price difference in basis points
    function _calculatePriceDiffBps(uint256 priceA, uint256 priceB) internal pure returns (uint256) {
        if (priceA == priceB) return 0;
        if (priceA == 0) return type(uint256).max;

        uint256 diff = priceA > priceB ? priceA - priceB : priceB - priceA;
        return FullMath.mulDiv(diff, 10_000, priceA);
    }
}
