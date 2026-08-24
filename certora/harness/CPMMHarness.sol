// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CPMM} from "../../src/libraries/CPMM.sol";

/// @title CPMMHarness
/// @notice Exposes CPMM library internals for Certora formal verification
contract CPMMHarness {
    using CPMM for CPMM.State;

    CPMM.State public state;

    // ─── State Getters ──────────────────────────────────────

    function getReserve0() external view returns (uint256) {
        return state.reserve0;
    }

    function getReserve1() external view returns (uint256) {
        return state.reserve1;
    }

    function getK() external view returns (uint256) {
        return state.reserve0 * state.reserve1;
    }

    // ─── Initialization ─────────────────────────────────────

    function initState(uint256 reserve0, uint256 reserve1) external {
        state.reserve0 = reserve0;
        state.reserve1 = reserve1;
    }

    // ─── Swap Wrappers ──────────────────────────────────────

    function swapExactIn(
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxPriceImpactBps,
        bool zeroForOne
    ) external returns (uint256 amountOut, uint256 priceImpactBps) {
        CPMM.SwapResult memory result = CPMM._swapExactIn(state, amountIn, amountOutMin, maxPriceImpactBps, zeroForOne);
        amountOut = result.amountOut;
        priceImpactBps = result.priceImpactBps;
    }

    function swapExactOut(
        uint256 amountOut,
        uint256 amountInMax,
        uint256 maxPriceImpactBps,
        bool zeroForOne
    ) external returns (uint256 amountIn, uint256 priceImpactBps) {
        CPMM.SwapResult memory result =
            CPMM._swapExactOut(state, amountOut, amountInMax, maxPriceImpactBps, zeroForOne);
        amountIn = result.amountIn;
        priceImpactBps = result.priceImpactBps;
    }

    // ─── Liquidity Wrappers ─────────────────────────────────

    function addLiquidity(uint256 amount0, uint256 amount1, uint256 priceX96, uint256 slippageBps)
        external
        returns (uint256 actualAmount0, uint256 actualAmount1)
    {
        CPMM.AddLiquidityResult memory result = CPMM._addLiquidity(state, amount0, amount1, priceX96, slippageBps);
        actualAmount0 = result.actualAmount0;
        actualAmount1 = result.actualAmount1;
    }

    // ─── Pure Math Wrappers ─────────────────────────────────

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256)
    {
        return CPMM._getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256)
    {
        return CPMM._getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getPriceX96(uint256 reserve0, uint256 reserve1, bool zeroForOne)
        external
        pure
        returns (uint256)
    {
        return CPMM._getPriceX96(reserve0, reserve1, zeroForOne);
    }

    function getPriceImpactBps(uint256 amountIn, uint256 reserveIn)
        external
        pure
        returns (uint256)
    {
        return CPMM._getPriceImpactBps(amountIn, reserveIn);
    }

    function quoteSwapExactIn(uint256 reserve0, uint256 reserve1, uint256 amountIn, bool zeroForOne)
        external
        pure
        returns (uint256 amountOut, uint256 priceImpactBps)
    {
        return CPMM._quoteSwapExactIn(reserve0, reserve1, amountIn, zeroForOne);
    }
}
