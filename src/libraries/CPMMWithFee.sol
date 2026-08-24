// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {CPMM} from "./CPMM.sol";

/// @title CPMMWithFee
/// @notice Charges a `swapFeeBps` fee over the fee-free CPMM. The protocol keeps `protocolCutBps` of
///         the fee; the rest is donated to the pool reserves for LPs.
library CPMMWithFee {
    uint256 internal constant FEE_BPS_DENOM = 10_000;

    /// @notice Swap exact input, charging the swap fee before delegating to the CPMM.
    /// @param state The CPMM state (will be modified)
    /// @param amountIn The gross input amount, inclusive of the fee
    /// @param amountOutMin Minimum output amount (slippage protection)
    /// @param maxPriceImpactBps Maximum price impact in basis points
    /// @param zeroForOne If true, swap token0 for token1
    /// @param swapFeeBps Swap fee, in bps of the input
    /// @param protocolCutBps Protocol's cut of the fee, in bps of the fee
    /// @return result Swap result with amounts and prices
    /// @return protocolFee The protocol's cut of the fee, for the caller to accrue
    function _swapExactIn(
        CPMM.State storage state,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        uint256 swapFeeBps,
        uint256 protocolCutBps
    ) internal returns (CPMM.SwapResult memory result, uint256 protocolFee) {
        uint256 totalFee = (amountIn * swapFeeBps) / FEE_BPS_DENOM;
        result = CPMM._swapExactIn(state, amountIn - totalFee, amountOutMin, maxPriceImpactBps, zeroForOne);
        protocolFee = _settleFee(state, result, zeroForOne, totalFee, protocolCutBps);
        result.amountIn = amountIn;
    }

    /// @notice Swap exact output, charging the swap fee on top of the input the CPMM requires.
    /// @param state The CPMM state (will be modified)
    /// @param amountOut The exact output amount desired
    /// @param amountInMax Maximum input amount (slippage protection)
    /// @param maxPriceImpactBps Maximum price impact in basis points
    /// @param zeroForOne If true, swap token0 for token1
    /// @param swapFeeBps Swap fee, in bps of the input
    /// @param protocolCutBps Protocol's cut of the fee, in bps of the fee
    /// @return result Swap result with amounts and prices
    /// @return protocolFee The protocol's cut of the fee, for the caller to accrue
    function _swapExactOut(
        CPMM.State storage state,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        uint256 swapFeeBps,
        uint256 protocolCutBps
    ) internal returns (CPMM.SwapResult memory result, uint256 protocolFee) {
        result = CPMM._swapExactOut(state, amountOut, amountInMax, maxPriceImpactBps, zeroForOne);

        if (swapFeeBps > 0) {
            uint256 netIn = result.amountIn;
            // Gross up so netIn = grossIn * (1 - swapFeeBps), rounding up.
            uint256 grossIn = (netIn * FEE_BPS_DENOM + (FEE_BPS_DENOM - swapFeeBps) - 1) / (FEE_BPS_DENOM - swapFeeBps);
            if (grossIn > amountInMax) revert CPMM.SlippageToleranceExceeded();

            protocolFee = _settleFee(state, result, zeroForOne, grossIn - netIn, protocolCutBps);
            result.amountIn = grossIn;
        }
    }

    /// @notice Split a swap fee between the protocol and LPs.
    /// @dev Donates the LP remainder to the input reserve and refreshes the post-swap price, which
    ///      the CPMM computed before the donation.
    /// @param state The CPMM state (will be modified)
    /// @param result The swap result whose post-swap price is refreshed after the donation
    /// @param zeroForOne If true, the input reserve is token0
    /// @param totalFee The full swap fee to split
    /// @param protocolCutBps Protocol's cut of the fee, in bps of the fee
    /// @return protocolFee The protocol's cut of the fee
    function _settleFee(
        CPMM.State storage state,
        CPMM.SwapResult memory result,
        bool zeroForOne,
        uint256 totalFee,
        uint256 protocolCutBps
    ) private returns (uint256 protocolFee) {
        protocolFee = (totalFee * protocolCutBps) / FEE_BPS_DENOM;

        uint256 lpFee = totalFee - protocolFee;
        if (lpFee > 0) {
            if (zeroForOne) state.reserve0 += lpFee;
            else state.reserve1 += lpFee;
            result.priceAfterX96 = CPMM._getPriceX96(state.reserve0, state.reserve1, zeroForOne);
        }
    }

    /// @notice Quote an exact-input swap's output, net of the swap fee.
    /// @param reserve0 Reserve of token0
    /// @param reserve1 Reserve of token1
    /// @param amountIn The input amount
    /// @param zeroForOne Swap direction
    /// @param swapFeeBps Swap fee, in bps of the input
    /// @return amountOut Expected output amount
    /// @return priceImpactBps Price impact in basis points
    function _quoteSwapExactIn(
        uint256 reserve0,
        uint256 reserve1,
        uint256 amountIn,
        bool zeroForOne,
        uint256 swapFeeBps
    ) internal pure returns (uint256 amountOut, uint256 priceImpactBps) {
        uint256 amountInAfterFee = amountIn - (amountIn * swapFeeBps) / FEE_BPS_DENOM;
        return CPMM._quoteSwapExactIn(reserve0, reserve1, amountInAfterFee, zeroForOne);
    }
}
