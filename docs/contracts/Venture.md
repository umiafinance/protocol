# Venture

Source: `src/core/Venture.sol`

## Purpose

Treasury contract for a single venture.

- Owns venture token mint/burn rights.
- Holds treasury assets.
- Exposes governance-controlled treasury actions.
- Tracks team membership, monthly allowances, documents, and liquidation state.

## Key state

- `token`, `moneyToken`, `lbp`
- `minMarketStake`
- `monthlyAllowance[token]` (`amount`, `spent`, `currentMonth`)
- `isTeamMember`
- `documents`, `documentCount`
- liquidation:
  - `liquidationActive`
  - `liquidationTotalSupply`
  - `liquidationAssets[]`

## Important functions

- Initialization/callbacks:
  - `initialize(...)` (only hub)
  - `onLBPMigrated()` (only configured LBP; applies the optional trading pause)
- Treasury mutation:
  - `mint`, `burn`, `withdraw`, `withdrawERC721`, `withdrawERC1155`, `executeCall`
- Governance-only updates:
  - `updateTeamMember`
  - `updateMonthlyAllowance`
  - `uploadDocument`
  - `startLiquidation`
- Team-member withdrawal:
  - `withdrawMonthlyAllowance`
- Liquidation claims:
  - `claimLiquidation`

## Access control

- `onlyHubOrMarketCoreOrExecutor`: core treasury mutation.
- `onlyExecutor`: governance-only update functions.
- `whenNotLiquidating`: blocks most normal treasury operations once liquidation starts.

## Notes

- Allowance reset uses `CalendarLib.timestampToMonth`.
- ERC721 assets are explicitly disallowed in `startLiquidation`.
- Spot liquidity lives in the venture's `SpotLiquidityVault` (see UIP-001), not in the treasury.
