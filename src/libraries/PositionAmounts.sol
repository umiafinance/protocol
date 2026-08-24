// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title PositionAmounts
/// @notice Values a concentrated-liquidity position in its underlying tokens.
library PositionAmounts {
    /// @notice Computes the token0 and token1 backing `liquidity` over the range
    ///         [sqrtPriceAX96, sqrtPriceBX96] at the current pool price.
    /// @dev Both legs round down, matching what the PoolManager credits on a liquidity removal.
    /// @param sqrtPriceX96 A sqrt price representing the current pool price
    /// @param sqrtPriceAX96 A sqrt price representing the first tick boundary
    /// @param sqrtPriceBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        }
    }
}
