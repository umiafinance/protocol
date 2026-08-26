// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PositionAmounts} from "../../src/libraries/PositionAmounts.sol";

/// @notice Differential test: `PositionAmounts` must reproduce, bit for bit, the
///         v3-periphery `LiquidityAmounts.getAmountsForLiquidity` semantics it
///         replaces (the vault's position valuation was built on those numbers).
///         The reference below is that semantics, written out from v3-core:
///         same boundary comparisons, same swap preconditioning, same
///         `mulDiv(n1, n2, sqrtB) / sqrtA` and `mulDiv(L, B - A, Q96)` bodies,
///         both legs rounding down.
contract PositionAmountsTest is Test {
    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    // --- v3-core semantics reference -------------------------------------------

    function refAmount0(uint160 a, uint160 b, uint128 l) internal pure returns (uint256) {
        if (a > b) (a, b) = (b, a);
        uint256 numerator1 = uint256(l) << FixedPoint96.RESOLUTION;
        uint256 numerator2 = uint256(b) - uint256(a);
        require(a > 0);
        return FullMath.mulDiv(numerator1, numerator2, b) / uint256(a);
    }

    function refAmount1(uint160 a, uint160 b, uint128 l) internal pure returns (uint256) {
        if (a > b) (a, b) = (b, a);
        return FullMath.mulDiv(uint256(l), uint256(b) - uint256(a), FixedPoint96.Q96);
    }

    function refGetAmounts(uint160 sqrtPriceX96, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = refAmount0(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = refAmount0(sqrtPriceX96, sqrtPriceBX96, liquidity);
            amount1 = refAmount1(sqrtPriceAX96, sqrtPriceX96, liquidity);
        } else {
            amount1 = refAmount1(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }

    // --- differential fuzz -----------------------------------------------------

    function testFuzz_matchesV3Semantics(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) public {
        // sqrtPriceA == 0 is the documented divergence (InvalidPrice vs division
        // panic) and unreachable from tick-derived bounds, so it is excluded.
        vm.assume(sqrtPriceAX96 > 0 && sqrtPriceBX96 > 0);
        (uint256 amount0, uint256 amount1) =
            PositionAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
        (uint256 ref0, uint256 ref1) = refGetAmounts(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);
        assertEq(amount0, ref0, "amount0 diverged from v3 semantics");
        assertEq(amount1, ref1, "amount1 diverged from v3 semantics");
    }

    // --- boundary pins ----------------------------------------------------------

    function test_priceAtLowerBound_isAllToken0() public pure {
        uint160 lo = 1 << 96;
        uint160 hi = 2 << 96;
        (uint256 amount0, uint256 amount1) = PositionAmounts.getAmountsForLiquidity(lo, lo, hi, 1e18);
        assertEq(amount1, 0);
        assertGt(amount0, 0);
    }

    function test_priceAtUpperBound_isAllToken1() public pure {
        uint160 lo = 1 << 96;
        uint160 hi = 2 << 96;
        (uint256 amount0, uint256 amount1) = PositionAmounts.getAmountsForLiquidity(hi, lo, hi, 1e18);
        assertEq(amount0, 0);
        assertGt(amount1, 0);
    }

    function test_unsortedBounds_swap() public pure {
        uint160 lo = 1 << 96;
        uint160 hi = 2 << 96;
        (uint256 s0, uint256 s1) = PositionAmounts.getAmountsForLiquidity(lo, hi, lo, 1e18);
        (uint256 t0, uint256 t1) = PositionAmounts.getAmountsForLiquidity(lo, lo, hi, 1e18);
        assertEq(s0, t0);
        assertEq(s1, t1);
    }

    function test_zeroLiquidity_isZero() public pure {
        (uint256 amount0, uint256 amount1) = PositionAmounts.getAmountsForLiquidity(1 << 96, 1 << 96, 2 << 96, 0);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_degenerateRange_isZero() public pure {
        (uint256 amount0, uint256 amount1) = PositionAmounts.getAmountsForLiquidity(1 << 96, 1 << 96, 1 << 96, 1e18);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_extremePrices_matchReference() public pure {
        (uint256 amount0, uint256 amount1) =
            PositionAmounts.getAmountsForLiquidity(MIN_SQRT + 1, MIN_SQRT, MAX_SQRT, 1e18);
        (uint256 ref0, uint256 ref1) = refGetAmounts(MIN_SQRT + 1, MIN_SQRT, MAX_SQRT, 1e18);
        assertEq(amount0, ref0);
        assertEq(amount1, ref1);
    }
}
