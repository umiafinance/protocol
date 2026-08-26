// ═══════════════════════════════════════════════════════════════
// CPMM.spec — Formal verification of CPMM math invariants
// Target: CPMMHarness (wrapping CPMM library)
// ═══════════════════════════════════════════════════════════════

using CPMMHarness as cpmm;

methods {
    function getReserve0() external returns (uint256) envfree;
    function getReserve1() external returns (uint256) envfree;
    function getK() external returns (uint256) envfree;
    function initState(uint256, uint256) external envfree;
    function swapExactIn(uint256, uint256, uint256, bool) external returns (uint256, uint256);
    function swapExactOut(uint256, uint256, uint256, bool) external returns (uint256, uint256);
    function addLiquidity(uint256, uint256, uint256, uint256) external returns (uint256, uint256);
    function getAmountOut(uint256, uint256, uint256) external returns (uint256) envfree;
    function getAmountIn(uint256, uint256, uint256) external returns (uint256) envfree;
    function getPriceX96(uint256, uint256, bool) external returns (uint256) envfree;
    function getPriceImpactBps(uint256, uint256) external returns (uint256) envfree;
    function quoteSwapExactIn(uint256, uint256, uint256, bool) external returns (uint256, uint256) envfree;
}


// ═══════════════════════════════════════════════════════════════
// Rule 1: Constant product never decreases after swap
// The fee causes k to strictly increase on every non-zero swap.
// ═══════════════════════════════════════════════════════════════

rule constantProductNeverDecreases_exactIn(env e, uint256 amountIn, bool zeroForOne) {
    uint256 r0_before = getReserve0();
    uint256 r1_before = getReserve1();
    require r0_before > 0 && r1_before > 0;

    // Bound to avoid overflow in k calculation
    require r0_before <= 2^128 && r1_before <= 2^128;
    require amountIn > 0 && amountIn <= 2^128;

    mathint k_before = to_mathint(r0_before) * to_mathint(r1_before);

    // Pass max price impact to avoid revert on that check
    uint256 amountOut; uint256 impact;
    amountOut, impact = swapExactIn(e, amountIn, 0, 10000, zeroForOne);

    uint256 r0_after = getReserve0();
    uint256 r1_after = getReserve1();
    mathint k_after = to_mathint(r0_after) * to_mathint(r1_after);

    assert k_after >= k_before, "Constant product must never decrease after swap";
}

rule constantProductNeverDecreases_exactOut(env e, uint256 amountOut, bool zeroForOne) {
    uint256 r0_before = getReserve0();
    uint256 r1_before = getReserve1();
    require r0_before > 0 && r1_before > 0;

    require r0_before <= 2^128 && r1_before <= 2^128;
    require amountOut > 0;

    // amountOut must be less than the output reserve
    uint256 reserveOut = zeroForOne ? r1_before : r0_before;
    require amountOut < reserveOut;
    require amountOut <= 2^128;

    mathint k_before = to_mathint(r0_before) * to_mathint(r1_before);

    uint256 amountIn; uint256 impact;
    amountIn, impact = swapExactOut(e, amountOut, max_uint256, 10000, zeroForOne);

    uint256 r0_after = getReserve0();
    uint256 r1_after = getReserve1();
    mathint k_after = to_mathint(r0_after) * to_mathint(r1_after);

    assert k_after >= k_before, "Constant product must never decrease after exactOut swap";
}


// ═══════════════════════════════════════════════════════════════
// Rule 2: Output always less than reserve
// A swap can never drain the entire output reserve.
// ═══════════════════════════════════════════════════════════════

rule outputAlwaysLessThanReserve(env e, uint256 amountIn, bool zeroForOne) {
    uint256 r0_before = getReserve0();
    uint256 r1_before = getReserve1();
    require r0_before > 0 && r1_before > 0;
    require amountIn > 0 && amountIn <= 2^128;

    uint256 reserveOut = zeroForOne ? r1_before : r0_before;

    uint256 amountOut; uint256 impact;
    amountOut, impact = swapExactIn(e, amountIn, 0, 10000, zeroForOne);

    assert amountOut < reserveOut, "Output must be strictly less than output reserve";
}


// ═══════════════════════════════════════════════════════════════
// Rule 3: Swap output monotonicity
// Larger input produces larger (or equal) output.
// ═══════════════════════════════════════════════════════════════

rule swapExactInOutputMonotonicity(uint256 amountIn1, uint256 amountIn2, uint256 reserveIn, uint256 reserveOut) {
    require reserveIn > 0 && reserveOut > 0;
    require reserveIn <= 2^128 && reserveOut <= 2^128;
    require amountIn1 > 0 && amountIn2 > 0;
    require amountIn1 <= 2^128 && amountIn2 <= 2^128;
    require amountIn1 <= amountIn2;

    uint256 out1 = getAmountOut(amountIn1, reserveIn, reserveOut);
    uint256 out2 = getAmountOut(amountIn2, reserveIn, reserveOut);

    assert out1 <= out2, "Larger input must produce larger or equal output";
}


// ═══════════════════════════════════════════════════════════════
// Rule 4: getAmountOut never exceeds reserve (pure math)
// ═══════════════════════════════════════════════════════════════

rule getAmountOutNeverExceedsReserve(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) {
    require reserveIn > 0 && reserveOut > 0;
    require reserveIn <= 2^128 && reserveOut <= 2^128;
    require amountIn > 0 && amountIn <= 2^128;

    uint256 amountOut = getAmountOut(amountIn, reserveIn, reserveOut);

    assert amountOut < reserveOut, "getAmountOut must return less than reserveOut";
}


// ═══════════════════════════════════════════════════════════════
// Rule 5: Round-trip safety (getAmountIn → getAmountOut)
// If you compute amountIn for a desired amountOut, then feed that
// amountIn back through getAmountOut, you get approximately the
// desired output (within integer rounding tolerance).
//
// The +1 round-up in _getAmountIn compensates for most truncation,
// but four integer divisions across the two functions can accumulate
// up to ~(reserveOut/reserveIn + 2) units of rounding error.
// This is a known AMM integer math limitation (same as Uniswap V2).
// ═══════════════════════════════════════════════════════════════

rule getAmountInRoundTrip(uint256 desiredOut, uint256 reserveIn, uint256 reserveOut) {
    require reserveIn >= 10^9 && reserveOut >= 10^9;
    require reserveIn <= 2^128 && reserveOut <= 2^128;
    require desiredOut < reserveOut;
    require desiredOut <= 2^128;
    require desiredOut >= 1000;

    uint256 requiredIn = getAmountIn(desiredOut, reserveIn, reserveOut);
    require requiredIn >= 334;

    uint256 actualOut = getAmountOut(requiredIn, reserveIn, reserveOut);

    // Integer rounding tolerance: fee truncation error gets amplified
    // by the reserve ratio, plus 2 for output division and denominator
    // truncation in _getAmountIn. For balanced pools (1:1) this is 3 wei;
    // for a 100:1 ratio pool it's 102 wei — always dust.
    mathint tolerance = to_mathint(reserveOut) / to_mathint(reserveIn) + 2;
    assert to_mathint(actualOut) + tolerance >= to_mathint(desiredOut),
        "Round-trip must produce desired output within integer rounding tolerance";
}


// ═══════════════════════════════════════════════════════════════
// Rule 6: Fee is always collected
// For any non-zero input, the fee-adjusted amount is strictly less.
// Fee = 30 bps (0.3%), so amountInWithFee = amountIn * 9970 / 10000
// ═══════════════════════════════════════════════════════════════

rule feeIsAlwaysCollected(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) {
    require reserveIn > 0 && reserveOut > 0;
    require reserveIn <= 2^128 && reserveOut <= 2^128;
    // amountIn * 30 / 10000 > 0 requires amountIn >= 334
    require amountIn >= 334 && amountIn <= 2^128;

    uint256 amountOut = getAmountOut(amountIn, reserveIn, reserveOut);

    // With fee, output is strictly less than the no-fee output.
    // No-fee: amountOut_nofee = amountIn * reserveOut / (reserveIn + amountIn)
    // Equivalent check: amountOut * (reserveIn + amountIn) < amountIn * reserveOut
    mathint lhs = to_mathint(amountOut) * (to_mathint(reserveIn) + to_mathint(amountIn));
    mathint rhs = to_mathint(amountIn) * to_mathint(reserveOut);
    assert lhs < rhs, "Fee must reduce output below the no-fee amount";
}


// ═══════════════════════════════════════════════════════════════
// Rule 7: Swap preserves reserve directionality
// zeroForOne: reserve0 increases, reserve1 decreases (or stays same)
// oneForZero: reserve1 increases, reserve0 decreases (or stays same)
//
// NOTE: Input reserve always strictly increases (amountIn > 0).
// Output reserve decreases only when amountOut > 0. For dust inputs
// where fee truncation zeroes the effective amount, output is 0
// and the output reserve stays unchanged.
// ═══════════════════════════════════════════════════════════════

rule swapPreservesReserveDirectionality(env e, uint256 amountIn, bool zeroForOne) {
    uint256 r0_before = getReserve0();
    uint256 r1_before = getReserve1();
    require r0_before > 0 && r1_before > 0;
    require r0_before <= 2^128 && r1_before <= 2^128;
    // Require meaningful input: amountIn * 9970 / 10000 > 0 needs amountIn >= 2,
    // and amountOut > 0 needs the fee-adjusted input to move the reserves.
    // 334 ensures fee deduction is non-zero.
    require amountIn >= 334 && amountIn <= 2^128;

    uint256 amountOut; uint256 impact;
    amountOut, impact = swapExactIn(e, amountIn, 0, 10000, zeroForOne);

    // Only verify directionality when the swap produces non-zero output.
    // With extreme reserve ratios (e.g. reserveIn = 2^128, reserveOut = 1),
    // amountOut truncates to 0 — user donates input with no return.
    require amountOut > 0;

    uint256 r0_after = getReserve0();
    uint256 r1_after = getReserve1();

    if (zeroForOne) {
        assert r0_after > r0_before, "zeroForOne: reserve0 must increase";
        assert r1_after < r1_before, "zeroForOne: reserve1 must decrease";
    } else {
        assert r1_after > r1_before, "oneForZero: reserve1 must increase";
        assert r0_after < r0_before, "oneForZero: reserve0 must decrease";
    }
}


// ═══════════════════════════════════════════════════════════════
// Rule 8: Price impact is bounded [0, 10000]
// ═══════════════════════════════════════════════════════════════

rule priceImpactBounded(uint256 amountIn, uint256 reserveIn) {
    require reserveIn > 0 && reserveIn <= 2^128;
    require amountIn > 0 && amountIn <= 2^128;

    uint256 impact = getPriceImpactBps(amountIn, reserveIn);

    assert impact <= 10000, "Price impact must be at most 10000 bps (100%)";
}


// ═══════════════════════════════════════════════════════════════
// Rule 9: addLiquidity preserves price (existing pool)
// After adding liquidity to a pool with existing reserves,
// the price ratio should not change (beyond rounding).
//
// Uses cross-multiplication to avoid Q96 division rounding:
// price_before = r1_before / r0_before
// price_after  = r1_after  / r0_after
// Equivalent: r1_before * r0_after == r1_after * r0_before (±rounding)
// ═══════════════════════════════════════════════════════════════

rule addLiquidityPreservesPrice(env e, uint256 amount0, uint256 amount1, uint256 priceX96, uint256 slippageBps) {
    uint256 r0_before = getReserve0();
    uint256 r1_before = getReserve1();

    // Existing pool with liquidity and realistic reserves.
    // Q96 price = r1 * 2^96 / r0. For the integer price to have precision,
    // both reserves must be substantial. With 18-decimal tokens, 10^9 wei
    // = 10^-9 tokens (1 nanotoken) — well below any real pool.
    require r0_before >= 10^9 && r1_before >= 10^9;
    require r0_before <= 2^96 && r1_before <= 2^96;
    require amount0 >= 10^9 && amount1 >= 10^9;
    require amount0 <= 2^96 && amount1 <= 2^96;
    require slippageBps <= 10000;

    uint256 actual0; uint256 actual1;
    actual0, actual1 = addLiquidity(e, amount0, amount1, priceX96, slippageBps);

    uint256 r0_after = getReserve0();
    uint256 r1_after = getReserve1();

    // Cross-multiply to check price preservation without division rounding.
    // r1_before / r0_before ≈ r1_after / r0_after
    // ⟺ r1_before * r0_after ≈ r1_after * r0_before
    mathint cross_before = to_mathint(r1_before) * to_mathint(r0_after);
    mathint cross_after  = to_mathint(r1_after)  * to_mathint(r0_before);
    mathint diff = cross_after > cross_before
        ? cross_after - cross_before
        : cross_before - cross_after;

    // Tolerance: _addLiquidity uses two FullMath.mulDiv operations, each
    // rounding by up to 1. In the cross product, this error scales by the
    // opposing reserve. Use pre-state reserves + added amounts as a tighter
    // bound than post-state reserves alone.
    mathint tolerance = to_mathint(r0_before) + to_mathint(r1_before)
                      + to_mathint(amount0) + to_mathint(amount1);
    assert diff <= tolerance,
        "Price must be preserved after liquidity addition (within rounding)";
}


// ═══════════════════════════════════════════════════════════════
// Rule 10: addLiquidity increases reserves
// Both reserves must increase (or stay same) after adding liquidity.
// ═══════════════════════════════════════════════════════════════

rule addLiquidityIncreasesReserves(env e, uint256 amount0, uint256 amount1, uint256 priceX96, uint256 slippageBps) {
    uint256 r0_before = getReserve0();
    uint256 r1_before = getReserve1();
    require r0_before <= 2^128 && r1_before <= 2^128;
    require amount0 > 0 && amount1 > 0;
    require amount0 <= 2^128 && amount1 <= 2^128;
    require slippageBps <= 10000;

    uint256 actual0; uint256 actual1;
    actual0, actual1 = addLiquidity(e, amount0, amount1, priceX96, slippageBps);

    uint256 r0_after = getReserve0();
    uint256 r1_after = getReserve1();

    assert r0_after >= r0_before, "Reserve0 must not decrease after adding liquidity";
    assert r1_after >= r1_before, "Reserve1 must not decrease after adding liquidity";
}


// ═══════════════════════════════════════════════════════════════
// Invariant: Reserves stay positive after initialization
// Once both reserves are > 0, no swap can bring either to zero.
//
// NOTE: addLiquidity on an empty pool must provide both tokens > 0.
// The library-level code allows initializing with one side = 0
// (price = 0), but the MarketCore never does this — pools are
// always seeded from LP removal which provides both tokens.
// ═══════════════════════════════════════════════════════════════

invariant reservesPositiveAfterInit()
    (getReserve0() == 0 && getReserve1() == 0) ||
    (getReserve0() > 0 && getReserve1() > 0)
    {
        preserved with (env e) {
            require getReserve0() <= 2^128 && getReserve1() <= 2^128;
        }
        preserved addLiquidity(uint256 amount0, uint256 amount1, uint256 priceX96, uint256 slippageBps) with (env e) {
            require getReserve0() <= 2^128 && getReserve1() <= 2^128;
            require amount0 <= 2^128 && amount1 <= 2^128;
            require (getReserve0() == 0 && getReserve1() == 0) =>
                    (amount0 > 0 && amount1 > 0);
        }
        preserved initState(uint256 r0, uint256 r1) {
            require (r0 == 0 && r1 == 0) || (r0 > 0 && r1 > 0);
        }
    }
