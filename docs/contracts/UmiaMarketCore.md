# UmiaMarketCore

Source: `src/core/UmiaMarketCore.sol`

## Purpose

Decision market engine with virtual token accounting.

- Creates markets/proposals.
- Handles split/merge with a minimal virtual-token ledger (`balanceOf`/`transfer` + `LedgerLib`), not full ERC-6909 (no approve/allowance/operator surface).
- Runs per-proposal CPMM markets.
- Settles markets with TWAP-based winner selection.
- Coordinates settlement claims and winning payload execution.

## Key state

- `marketCounter`, `proposalCounter`, `activeUnsettledMarketCount`
- `_markets[marketId]` (`MarketData`), `_proposals[proposalId]` (`ProposalData`) — packed structs in `MarketCoreTypes`
- `_pools[proposalId]` (`Pool`: CPMM reserves, accrued protocol fees, user virtual supplies, LP shares)
- `_settle[marketId]` (`SettleAcct`: real venture/money balances, winner + winning TWAP, LP re-add accounting, `settledAt`, `executed`-adjacent flags on `MarketData`)
- `balanceOf[owner][id]`, `totalSupply[id]` — the virtual venture/money + LP-share ledger (`LedgerLib`)
- `proposalToMarket`, `activeMarketByVenture`, `_hasClaimed[marketId][user]`
- EIP-712 replay state: `marketCreationNonces`, `swapNonces`, `DOMAIN_SEPARATOR`
- Market stake accounting lives in the separate `UmiaMarketStake` contract, not here.

## Important functions

- Market lifecycle:
  - `createMarket`
  - `getMarketStatus`
  - `settleMarket`
  - `claimSettlement`
  - `executeWinningProposal`
- Trading/accounting:
  - `split`, `merge`
  - swaps: `swapExactIn`, `swapExactOut` (self-custodial), plus `swapExactInWithPermit`, `swapExactOutWithPermit` (EIP-712 relayed)
  - `addLiquidity`

## Access control and checks

- `createMarket` requires signer-approved payload and nonce.
- Swaps are self-custodial: `swapExactIn` / `swapExactOut` move the caller's own virtual tokens. The permit variants recover an EIP-712 signer and consume a per-signer `swapNonces` entry for replay protection.
- `executeWinningProposal` resolves executor from hub and requires non-zero executor if payload execution is needed.

## Important constants

Defined in `MarketCreationLib` (not on `UmiaMarketCore` itself):

- `TRADING_MAX_START_DELAY = 7 days` — start at/before `block.timestamp` clamps to now (no minimum delay)
- `TRADING_MIN_DURATION = 1 hours`
- `TRADING_MAX_DURATION = 96 hours`
- `TRADING_DEFAULT_DURATION = 3 days` — used when `duration == 0`
- `MIN_PROPOSALS = 1`
- `MAX_PROPOSALS = 5`

## Notes

- A no-op proposal is auto-inserted at index 0 for each market.
- 50% of venture LP liquidity is removed during market creation and partially re-added at settlement.
- Winner threshold comparison uses hub-configured `winningMarketThresholdBps`.
