# Spot Pool TWAP Oracle

## Overview

Umia integrates a time-weighted average price (TWAP) oracle directly into `UmiaLBP`, the Uniswap V4 hook that manages every Venture's spot pool. The oracle records price observations on every swap and liquidity change, enabling any onchain or off-chain consumer to query manipulation-resistant TWAPs over arbitrary time windows.

Two primary consumers exist today:

| Consumer            | Window                           | Purpose                                                                                                                          |
| ------------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **MarketCore**   | 4 hours                          | Rejects market creation if spot price deviates >5% from the 4h TWAP, preventing sandwich attacks on decision market start prices |
| **UmiaTwapMilestoneCondition** | Configurable (typically 30 days) | Gates a MetaVesT vesting milestone on the full-window TWAP. The price threshold it compares against is resolved live from the venture's `VentureVestingAuthority` (absolute, or `multiple × clearingPrice`), not stored or finalized on the condition. Reverts if oracle history is insufficient (fail-closed). |

Both use the same oracle. The window is a query-time parameter, not a configuration.

## How It Works

### The Observation Buffer

Each pool has a circular buffer of up to 65,535 **observations**. An observation records:

```
struct Observation {
    uint32  blockTimestamp                      // when this observation was written
    int24   prevTick                            // the tick at time of writing
    int48   tickCumulative                      // cumulative sum of (tick * seconds elapsed)
    uint144 secondsPerLiquidityCumulativeX128   // cumulative seconds / liquidity
    bool    initialized                         // whether this slot has been written
}
```

The `tickCumulative` field is the key to TWAP computation. Each time an observation is written, it adds `tick * elapsed_seconds` to the running sum. To compute a TWAP between two points in time, you subtract their cumulative values and divide by the time difference:

```
twapTick = (tickCumulative[now] - tickCumulative[then]) / (now - then)
```

This is a **geometric mean** TWAP (since ticks are logarithmic), which is more robust against manipulation than arithmetic mean.

### When Observations Are Written

UmiaLBP writes an observation in two hook callbacks:

- **`beforeSwap`** — captures the tick *before* the swap executes. This is the standard oracle pattern.
- **`beforeAddLiquidity`** — ensures the oracle is current before liquidity changes affect the `secondsPerLiquidityCumulative` accumulator.

At most one observation is written per block. If multiple swaps happen in the same block, the first one writes and subsequent ones are no-ops.

### Initialization

The oracle is initialized during `migrate()`, not during pool initialization. This is because Uniswap V4's `noSelfCall` modifier silently skips hook callbacks when the hook calls the PoolManager on itself. Since UmiaLBP uses the `SelfInitializerHook` pattern (the hook initializes its own pool), the `afterInitialize` callback is never triggered. Instead, `_initializeOracle()` is called directly in `migrate()` after pool creation. Migration also grows the oracle buffer to 250 slots to provide initial TWAP coverage (see Buffer Sizing below).

### Truncation

The oracle uses a **truncated** variant that caps tick movement to +/-9,116 ticks per block (`MAX_ABS_TICK_MOVE`). If the tick moves more than this threshold between observations, the recorded value is clamped. This bounds the impact of single-block price manipulation (e.g., flashloan attacks) on the TWAP, regardless of pool liquidity depth.

9,116 ticks corresponds to roughly a 2.5x price change in a single block — far beyond any legitimate price movement.

## Querying the Oracle

### `observe(PoolKey, uint32[] secondsAgos)`

Returns cumulative tick and liquidity values at each requested point in the past.

```solidity
uint32[] memory secondsAgos = new uint32[](2);
secondsAgos[0] = 14400; // 4 hours ago
secondsAgos[1] = 0;     // now

(int48[] memory tickCumulatives, ) = lbp.observe(key, secondsAgos);

int24 twapTick = int24(
    (tickCumulatives[1] - tickCumulatives[0]) / int48(14400)
);

// Convert tick to price if needed:
uint160 twapSqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
```

Any window length works — 1 minute, 4 hours, 30 days — as long as the buffer contains observations spanning that period.

Reverts with `TargetPredatesOldestObservation` if the requested time is older than the oldest observation in the buffer.

### `increaseCardinalityNext(PoolKey, uint16)`

Pre-allocates observation buffer slots. Permissionless — anyone can call it and pay the gas.

```solidity
lbp.increaseCardinalityNext(key, 1000);
```

Each slot costs one SSTORE (~20k gas) to initialize. The buffer starts at cardinality 1 and grows as new slots are needed during writes.

## Buffer Sizing (Cardinality)

### What is cardinality?

The observation buffer is a fixed-size circular array. **Cardinality** is the number of usable slots in this array. When all slots are full, new observations overwrite the oldest ones. The buffer starts at cardinality 1 (only the most recent observation is kept) and must be explicitly grown by calling `increaseCardinalityNext()`.

Growing cardinality costs gas upfront: each new slot requires a cold SSTORE (~22,100 gas) to initialize. This is a one-time cost — once initialized, subsequent writes to that slot are warm SSTOREs (~5,000 gas each, paid by swappers as part of normal hook execution).

### Why this matters

A TWAP query for a given time window (e.g., 30 days) only works if the buffer still contains an observation from that far back. If trading activity has overwritten all observations older than 30 days, the query reverts with `TargetPredatesOldestObservation`.

The oracle is always **time-based**: you query "what was the average price over the last N seconds?" The oracle interpolates between observations, assuming the tick stays constant between them. Even with sparse observations (e.g., 1 per day), a 30-day TWAP is valid as long as the oldest observation is >= 30 days old. Cardinality is an infrastructure constraint, not a semantic one.

### Sizing for 30-day TWAPs

The buffer must survive 30 days without the oldest needed observation being evicted. The risk is not average activity — it's **peak activity**. A single busy day with hundreds of swaps can consume many buffer slots.

| Trading frequency  | Observations per day | 30-day total          |
| ------------------ | -------------------- | --------------------- |
| 1 swap/hour        | 24                   | 720                   |
| 1 swap/10 min      | 144                  | 4,320                 |
| 1 swap/min         | 1,440                | 43,200                |
| 1 swap/block (12s) | 7,200                | 216,000 (exceeds max) |

**Recommended cardinality: 2,000–3,000** for pools that need 30-day TWAPs. This handles pools with sustained activity of up to ~70–100 swaps/hour (well above typical Venture pools) without evicting 30-day-old data. If a pool consistently sees higher throughput, cardinality can be increased later — `increaseCardinalityNext()` is permissionless and additive.

### Initialization cost

Each slot costs ~22,100 gas (cold SSTORE). The Ethereum block gas limit is ~60M, so a single `increaseCardinalityNext()` call can initialize at most ~2,600 slots. To reach higher cardinalities, call it multiple times — `grow()` picks up where the last call left off.

| Target cardinality | Transactions needed | Total gas | Cost at 10 gwei |
| ------------------ | ------------------- | --------- | --------------- |
| 720                | 1                   | ~16M      | ~0.00016 ETH    |
| 1,500              | 2                   | ~33M      | ~0.00033 ETH    |
| 3,000              | 3                   | ~66M      | ~0.00066 ETH    |
| 10,000             | 8                   | ~221M     | ~0.0022 ETH     |

This cost is paid once per pool, typically right after LBP migration. It can be paid by anyone (permissionless) and does not need to come from the Venture owner.

### What happens if cardinality is too low?

- Short-window queries (4h TWAP for MarketCore) still work — even cardinality 1 supports a 4h TWAP as long as there's been at least one swap in the last 4 hours, since the oracle interpolates from its single observation.
- Long-window queries (30-day TWAP for incentive packages) revert with `TargetPredatesOldestObservation`. The incentive contract should handle this gracefully (e.g., "check not yet available").
- The buffer can always be grown later without losing existing observations.

## Security Properties

**Manipulation resistance**: An attacker wanting to skew a 4-hour TWAP must sustain an artificial price for the entire 4-hour window. With the truncation cap at 9,116 ticks/block, even a flashloan attack in a single block can only contribute a bounded amount to the cumulative value.

**Full-range liquidity only**: The `UmiaLBP` hook enforces that all liquidity positions on the spot pool are full-range (spanning `minUsableTick` to `maxUsableTick`). Concentrated liquidity would create zero-liquidity tick gaps where the tick can be moved for free, undermining the truncation cap's security guarantee. The enforcement happens in `beforeAddLiquidity` — any position with a narrower tick range reverts with `OnlyFullRangePositions`. See [UmiaLBP docs](contracts/UmiaLBP.md) for details.

**No liquidity lock**: Unlike reference implementations that permanently lock liquidity to guarantee oracle integrity, Umia does not enforce a liquidity floor. The seed LP (set during LBP migration) provides substantial baseline liquidity, and MarketCore only removes 50% for decision markets. The truncation mechanism provides manipulation resistance regardless of liquidity depth.

**Fail-closed guard**: The `SpotMarketPriceGuard` distinguishes two failure modes when `observe(TWAP_WINDOW)` reverts:
- **Oracle uninitialized** (pre-migration): silently allows the operation (bootstrap case).
- **Oracle active but insufficient history** (buffer evicted or too young): reverts with `InsufficientOracleHistory`. This prevents an attacker from exhausting the observation buffer with dust swaps to bypass the guard.

**Buffer exhaustion resistance**: Migration initializes the oracle with 250 observation slots (~5.5M gas). At worst case (1 observation/block, 12s), 250 slots covers ~50 minutes. While this doesn't fully cover the 4h TWAP window under adversarial conditions, the fail-closed guard ensures that buffer exhaustion triggers `InsufficientOracleHistory` rather than bypassing the check. Cardinality can be increased later via `increaseCardinalityNext()` (permissionless) if higher resilience is needed.

## Integration with MarketCore

When `createMarket()` is called, `_checkSpotTwapDeviation()` runs before any LP is removed:

1. Reads the Venture's LBP address and LP position
2. Queries the 4-hour TWAP via `observe()`
3. Reads the current spot tick from the pool
4. Computes the absolute tick difference: `|spotTick - twapTick|`
5. Reverts with `SpotPriceDeviationTooHigh` if the tick difference exceeds `MAX_TICK_DEVIATION` (default: 500 ticks ≈ 5% price deviation)

Tick differences map directly to percentage price changes because ticks are logarithmic (`price = 1.0001^tick`). A fixed tick difference corresponds to a fixed percentage regardless of the absolute tick level.

This prevents an attacker from manipulating the spot price right before market creation to skew the initial CPMM reserves for all proposals.

## Files

| File                                 | Role                                                                                                                             |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `src/libraries/SpotMarketOracle.sol` | Circular buffer library — observation storage, writes, binary search, interpolation                                              |
| `src/launchpad/UmiaLBP.sol`          | Hook integration — writes observations in `beforeSwap`/`beforeAddLiquidity`, exposes `observe()` and `increaseCardinalityNext()` |
| `src/core/UmiaMarketCore.sol`     | Consumer — `_checkSpotTwapDeviation()` queries the 4h TWAP on market creation                                                    |
| `test/launchpad/UmiaLBPOracle.t.sol` | Oracle integration tests                                                                                                         |
| `src/periphery/UmiaTwapMilestoneCondition.sol`  | Consumer — full-window TWAP query gating MetaVesT vesting milestones                                                              |
