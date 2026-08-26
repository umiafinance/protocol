# ConditionalMarketOracle

Source: `src/periphery/ConditionalMarketOracle.sol`

## Purpose

Per-proposal TWAP oracle used by market settlement.

- Maintains a cumulative price value in Uniswap-v2-style Q112.112 form.
- Anchors each proposal's scoring window at `tradingStart` with a zero cumulative baseline.
- Calculates TWAP from `tradingStart` to the current block timestamp (frozen at `tradingEnd`).

## Interface

The three-function interface is the upgrade seam: the Hub owner can point the core at a
replacement oracle implementing the same interface (see `docs/UPGRADES.md`) without changing
`UmiaMarketCore`. `winningThresholdBps` is accepted (and validated) at `initialize` so a future
implementation can calibrate its clamp to the same threshold settlement uses; this implementation's
fixed per-update band does not consume it.

- `initialize(proposalId, reserve0, reserve1, tradingStart, tradingEnd, winningThresholdBps)` —
  one call at market creation: validates inputs, records the seed observation, anchors
  `lastTimestamp` at `tradingStart`. Reverts with `AlreadyInitialized` if repeated.
- `update(proposalId, reserve0, reserve1)` — called before every reserve mutation, so the elapsed
  interval is credited at the price that actually held over it. No-op before `tradingStart`,
  within the same second, after the `tradingEnd` freeze, or for degenerate (zero) reserves — a
  degenerate interval is credited by the next well-formed update instead.
- `calculateTWAP(proposalId, reserve0, reserve1)` — view; extrapolates the current interval at the
  clamped price of the passed reserves.

## Key state

- `oracleStates[proposalId]`:
  - `price0CumulativeLast` — ∫ observation dt, scored from `tradingStart`
  - `lastPrice0X112` — last accepted observation
  - `tradingStart`, `tradingEnd` — scoring window
  - `lastTimestamp` — last recorded time; anchored at `tradingStart` on init
  - `initialized`

## Access control

- `initialize` and `update` are `onlyMarketCore`.

## Price clamping (truncation)

Per-update price changes are clamped to a maximum ratio of 2.5x (and minimum of 0.4x) relative to the last recorded observation. This bounds the impact of single-block price manipulation on the TWAP accumulator.

```
maxPrice = lastPrice * 5 / 2          (2.5x ceiling)
minPrice = (lastPrice * 2 + 4) / 5    (0.4x floor, rounded up so it is never zero)
```

The clamped price (not the raw price) is accumulated into the cumulative sum, so even if an attacker moves the CPMM spot price by 100x in one block, the oracle only records a 2.5x move. Over multiple updates the clamp compounds, so sustained price changes still converge — only single-update spikes are bounded. Every accepted observation is saturated to `MAX_PRICE_X112 = 2^208`, so an extreme reserve ratio cannot store an observation that overflows a later update.

## Trading end freeze

Both `update()` and `calculateTWAP()` cap their effective timestamp at `min(block.timestamp, tradingEnd)` via `_effectiveTimestamp()`.

This means:
- After `tradingEnd`, no further price accumulation occurs regardless of when `update()` is called.
- `calculateTWAP()` returns the same value whether called at `tradingEnd` or hours later.
- Settlement delay cannot dilute or extend the TWAP window beyond the trading period.
- Last-block manipulation at `tradingEnd - 1` gets at most one block of influence rather than being extended by the settlement gap.

## Notes

- `calculateTWAP` reverts with `ProposalNotInitialized` for unknown proposals and
  `TradingNotStarted` before the scoring window opens.
- Queried in the first second of the window, `calculateTWAP` returns the anchored observation
  rather than the raw spot of the passed reserves (which would be same-block manipulable).
