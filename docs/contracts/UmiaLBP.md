# UmiaLBP

Source: `src/launchpad/UmiaLBP.sol`

## Purpose

Custom launch strategy integrating auction distribution with venture treasury migration.

- Creates initializer/auction on token receipt.
- Sweeps auction proceeds.
- Splits raised currency to venture share and LP migration share.
- Initializes Uniswap v4 pool/position and registers resulting LP NFT to venture.

## Key immutables and config

- venture config: `venture`, `ventureBps`
- token/currency config: `token`, `currency`, `totalSupply`, `reserveTokenAmount`
- pool config: `poolLPFee`, `poolTickSpacing`
- timing config: `migrationBlock`, `sweepBlock`
- fee config: `feeRecipient`, `feeBps`
- dependencies: `poolManager`

## Important functions

- `onTokensReceived()`
- `migrate()`
- `sweepToken()` / `sweepCurrency()` (after `sweepBlock`)
- fee path: `claimFees`, `unlockCallback`

## Full-range liquidity enforcement

The hook only allows full-range liquidity positions on the spot pool. Any attempt to add concentrated liquidity (tick range narrower than the full usable range) reverts with `OnlyFullRangePositions`.

This is enforced in `beforeAddLiquidity`:

```solidity
if (
    params.tickLower != TickMath.minUsableTick(key.tickSpacing)
        || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
) {
    revert OnlyFullRangePositions();
}
```

**Why this matters**: The spot pool's TWAP oracle uses a truncated tick-based design that assumes liquidity exists at every tick level. Concentrated liquidity creates zero-liquidity gaps where moving the tick costs nothing, making the truncation cap ineffective — an attacker could push the price through empty ranges with minimal capital. Full-range positions guarantee uniform liquidity depth across all ticks.

**Position modification**: Uniswap V4 positions have immutable tick ranges. To change a position's range, a user must remove the old position and add a new one. Since `beforeRemoveLiquidity` is disabled (returns false in hook permissions), removal always succeeds. The enforcement in `beforeAddLiquidity` is sufficient to guarantee that only full-range positions exist on the pool.

## Notes

- Constructor enforces `positionRecipient == venture`.
- `migrate()` calls `ILBPMigrationCallback(venture).onLBPMigrated(tokenId)`.
- Hook permissions include `afterSwap` for fee capture.
