# Certora Formal Verification

Formal verification specs for Umia's core contracts using the [Certora Prover](https://www.certora.com/).

```
certora/
├── conf/                          # Prover configuration
│   ├── CPMM.conf
│   ├── MarketCore.conf
│   └── StateMachine.conf
├── harness/                       # Wrapper contracts exposing internals
│   ├── CPMMHarness.sol
│   └── MarketCoreHarness.sol
└── specs/                         # CVL specification files
    ├── CPMM.spec
    ├── MarketCore.spec
    └── StateMachine.spec
```

## Prerequisites

1. Set your prover key: `export CERTORAKEY=<your-key>`
2. Have `solc` (0.8.26) installed and available in PATH

## Running

```bash
just certora CPMM            # CPMM math invariants
just certora MarketCore    # Solvency, settlement, claims
just certora StateMachine     # Market lifecycle transitions
```

Results appear on the [Certora Prover dashboard](https://prover.certora.com/).

## Specs

### `CPMM.spec` — AMM math (10 rules, 1 invariant)

Target: `CPMMHarness.sol` wrapping `src/libraries/CPMM.sol`

| Rule                                       | Property                                                          |
| ------------------------------------------ | ----------------------------------------------------------------- |
| `constantProductNeverDecreases_exactIn`    | `k` never decreases after a swap (fees make it grow)              |
| `constantProductNeverDecreases_exactOut`   | Same for exact-output swaps                                       |
| `outputAlwaysLessThanReserve`              | Swap output is strictly less than the output reserve              |
| `swapExactInOutputMonotonicity`            | Larger input produces larger or equal output                      |
| `getAmountOutNeverExceedsReserve`          | Pure math: `_getAmountOut < reserveOut`                           |
| `getAmountInRoundTrip`                     | `getAmountIn → getAmountOut` round-trip within rounding tolerance |
| `feeIsAlwaysCollected`                     | Output with fee is strictly less than no-fee output               |
| `swapPreservesReserveDirectionality`       | zeroForOne increases reserve0, decreases reserve1                 |
| `priceImpactBounded`                       | Price impact is in `[0, 10000]` bps                               |
| `addLiquidityPreservesPrice`               | Price ratio preserved after liquidity addition (within rounding)  |
| `addLiquidityIncreasesReserves`            | Both reserves non-decreasing after liquidity addition             |
| **Invariant:** `reservesPositiveAfterInit` | Once both reserves are positive, they stay positive               |

### `MarketCore.spec` — Solvency & settlement (11 rules, 1 ghost invariant)

Target: `MarketCoreHarness.sol` extending `src/core/UmiaMarketCore.sol`

| Rule                                              | Property                                                                     |
| ------------------------------------------------- | ---------------------------------------------------------------------------- |
| `solvencyInvariantHoldsAfterSplit`                | `_checkInvariant` passes after split                                         |
| `solvencyInvariantHoldsAfterMerge`                | `_checkInvariant` passes after merge                                         |
| `splitMergeNetZero`                               | Split then merge same amounts restores real balances                         |
| `splitExactSupplyChange`                          | Split increases supply by exact amount for market proposals, zero for others |
| `noDoubleClaim`                                   | Second claim reverts                                                         |
| `claimBurnsVirtualTokens`                         | User's virtual token balance is zero after claim                             |
| `claimSetsFlag`                                   | `hasClaimed` is true after successful claim                                  |
| `virtualSupplyConservationOnSwap`                 | CPMM reserves + user supply constant through swaps                           |
| `totalSupplyTracksOnSplit`                        | `totalSupply` non-decreasing after split                                     |
| `settleOnlyOnce`                                  | Settling an already-settled market reverts                                   |
| `executeOnlyOnce`                                 | Executing an already-executed market reverts                                 |
| **Ghost invariant:** `totalSupplyIsSumOfBalances` | `totalSupply[id] == Σ balanceOf[user][id]` for all users                     |

The ghost variable `sumOfBalances` is maintained by an `Sstore` hook on `balanceOf` and independently verifies that the contract's `totalSupply` counter matches actual token holdings.

### `StateMachine.spec` — Market lifecycle (10 rules)

Target: `MarketCoreHarness.sol`

| Rule                       | Property                                                       |
| -------------------------- | -------------------------------------------------------------- |
| `splitOnlyWhenOpen`        | `split` reverts when market is not OPEN                        |
| `mergeOnlyWhenOpen`        | `merge` reverts when market is not OPEN                        |
| `settlementOnlyWhenEnded`  | `settleMarket` reverts when market is not ENDED                |
| `claimOnlyWhenSettled`     | `claimSettlement` reverts when market is not settled           |
| `marketCounterMonotonic`   | Market counter never decreases (parametric over all functions) |
| `proposalCounterMonotonic` | Proposal counter never decreases                               |
| `hasClaimedMonotonic`      | `hasClaimed` never goes from true to false                     |
| `marketExecutedMonotonic`  | `marketExecuted` never goes from true to false                 |
| `settlementMonotonic`      | Winning proposal ID never changes once set                     |
| `addLiquidityOnlyWhenOpen` | `addLiquidity` reverts when market is not OPEN                 |

## Assumptions (NONDET summaries)

External calls are summarized as `NONDET` — the prover assumes they succeed and returns an arbitrary value. This means these specs verify **internal accounting invariants**, not integration correctness.

| Summary                                                                   | Rationale                                                                                                      |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `safeTransfer` / `safeTransferFrom`                                       | Umia uses standard ERC20 tokens vetted at venture creation. Fee-on-transfer and rebasing tokens are out of scope. |
| `update`, `initialize`, `calculateTWAP`                                   | TWAP oracle interactions. Specs focus on accounting, not oracle correctness.                                   |
| `swapRouter`, `conditionalMarketOracle`                                                | Hub registry lookups. Access control is not verified (the prover can pick any address).                        |
| `ventureById`, `ventureTokenById`, `ventureMoneyTokenById`                         | Hub registry. Token addresses are arbitrary in the prover.                                                     |
| `winningMarketThresholdBps`, `circuitBreakerActive`, `governanceExecutor` | Protocol parameters. Specs verify accounting holds for any parameter values.                                   |

## Coverage gaps

- **`removeLiquidity` / `_reAddLiquidity`**: Uniswap V4 integration not modeled. If the re-add returns less liquidity, accounting could diverge.
- **Ghost scope**: Only `totalSupply == Σ balanceOf` is implemented. Ghosts for `userVirtualSupply == Σ balanceOf` (per-proposal) and full conservation (`reserve + Σ user balances == constant`) are deferred to avoid prover performance degradation.
- **Access control**: `routerSwapExactIn`/`routerSwapExactOut` require `msg.sender == HUB.swapRouter()`, but since `swapRouter()` is NONDET, this check is trivially satisfied.
