# Umia Smart Contracts Architecture

This document describes the current Solidity code under `smart-contracts/src`.
It is intentionally code-first and references concrete contracts in this repository.

## High-level Components

- **Hub / registry layer**
  - `src/core/UmiaHub.sol`
  - Creates ventures and stores canonical protocol addresses (market core, oracle, governance executor, LBP factory).

- **venture treasury layer**
  - `src/core/Venture.sol`
  - Holds treasury assets, receives the migrated Uniswap v4 LP position, and is the target of governance execution.

- **Decision market layer**
  - `src/core/UmiaMarketCore.sol`
  - Runs market lifecycle, split/merge accounting, virtual token balances (ERC6909), CPMM state, settlement, and winning proposal execution.

- **Governance execution layer**
  - `src/core/GovernanceExecutor.sol`
  - Decodes typed action plans via `GovernancePayloadValidator` and dispatches actions into `Venture` via `GovernanceActions`.
  - Shared types in `src/libraries/GovernanceTypes.sol`.

- **Periphery layer**
  - `src/periphery/ConditionalMarketOracle.sol` for per-proposal TWAP tracking.
  - `src/periphery/UmiaValidationHook.sol` for auction-time validation hooks (one per gated CCA, wired in at auction creation).

- **Launchpad layer**
  - `src/launchpad/UmiaLBPFactory.sol` and `src/launchpad/UmiaLBP.sol`
  - Launch flow for venture token distribution, migration to Uniswap v4, and LP registration callback.

- **Incentive / vesting layer**
  - `src/periphery/UmiaTwapMilestoneCondition.sol` — stateless, shared MetaVesT condition singleton (one per chain) that gates a vesting milestone on the spot pool TWAP. It holds no per-allocation state, no auth, and no events: at check time it resolves the milestone's threshold off the allocation's adapter (`allocation → controller → authority → effectiveThreshold`) and compares the venture's full-window TWAP.
  - `src/periphery/VentureVestingAuthority.sol` — per-venture adapter that holds the MetaVesT controller's `authority` role and routes it to the venture treasury (so only futarchy can create/amend/terminate grants post-launch), and is also the per-allocation price-ladder registry: a grant's ladder is written here atomically with `createMetavest`. Absolute thresholds are stored; relative thresholds are resolved live as `multiple × clearingPrice`, so there is no separate ladder-registration or finalize step.
  - Vesting itself runs through MetaVesT, imported as a git submodule at `lib/metavest`.

- **Token layer**
  - `src/tokens/VentureToken.sol` (ERC20Pausable; mint/burn/pause/unpause controlled by Venture owner).

## Core Data Flow

### 1) venture creation and launch

1. `UmiaHub.createVenture(...)` deploys:
   - `Venture`
   - `VentureToken`
   - LBP contract via `UmiaLBPFactory` (`IDistributionStrategy.initializeDistribution`).
2. Hub mints total token supply to itself, transfers token ownership to `Venture`, and sends supply to LBP.
3. LBP runs auction and eventually migrates liquidity to Uniswap v4.
4. `UmiaLBP.migrate()` deploys the venture's `SpotLiquidityVault`, registers it on the hub
   (`registerSpotLiquidityVault`), and hands the raised liquidity to the vault, which holds the
   canonical full-range spot position.
5. `UmiaLBP.migrate()` notifies the treasury via `ILBPMigrationCallback.onLBPMigrated()`, which
   only applies the optional post-migration trading pause.

### 2) Market creation and trading

1. Market creator deposits per-venture stake: `UmiaMarketCore.depositMarketStake(ventureId)`.
2. `createMarket(...)` requires:
   - signature by `UmiaHub.marketCreationSigner()` (EIP-712),
   - valid nonce (`marketCreationNonces[creator]`),
   - valid stake deposit,
   - start time at/before now clamps to `block.timestamp` (open immediately); must be ≤ `TRADING_MAX_START_DELAY` (7 days),
   - duration in `[TRADING_MIN_DURATION, TRADING_MAX_DURATION]` (1h–96h; `0` → default 3 days),
   - proposal count in `[1, 5]` (plus auto no-op proposal).
3. On market creation, the market core removes 50% of venture’s LP liquidity from Uniswap v4 and initializes one CPMM per proposal.
4. During `OPEN` phase, users:
   - `split` real venture/money into virtual tokens across all proposals,
   - trade virtual tokens through the core's swap entrypoints (called directly or via an EIP-712 permit),
   - optionally `merge` equal virtual balances back into real tokens.

### 3) Settlement and execution

1. After `tradingEnd`, anyone calls `settleMarket(marketId)`.
2. The market core updates the oracle and computes proposal TWAPs.
3. Winner logic:
   - highest TWAP vs no-op TWAP,
   - must exceed `UmiaHub.winningMarketThresholdBps()` (default 200 bps) unless no-op remains winner.
4. The market core reserves claimable backing for winning-proposal virtual supply and re-adds excess liquidity to Uniswap v4 LP.
5. Users call `claimSettlement` to redeem winning-proposal virtual balances 1:1 in real assets.
6. Anyone calls `executeWinningProposal`:
   - no-op or empty payload => mark executed,
   - otherwise route to configured `GovernanceExecutor` for that venture.

## Governance Payload Path

1. Proposal stores `executionPayload` bytes in `UmiaMarketCore.Proposal`.
2. `executeWinningProposal` resolves executor from `UmiaHub.governanceExecutor(venture)`.
3. `GovernanceExecutor.executeProposal(...)` enforces:
   - caller must be the current UmiaMarketCore,
   - this executor must match hub config for venture,
   - payload non-empty,
   - venture not already in liquidation.
4. Payload is decoded as `GovernanceTypes.ExecutionPlanV1`.
5. Each action is validated/executed via `GovernanceActions.executeActionV1`.
6. `LIQUIDATE_TREASURY` must be final action in plan.

## Contract Interaction Map (runtime)

- `UmiaHub` configures/points to:
  - `UmiaMarketCore`
  - default/per-venture `GovernanceExecutor`
  - `ConditionalMarketOracle`
  - `UmiaLBPFactory`
- `UmiaMarketCore` depends on:
  - `UmiaHub` registry
  - `Venture` for venture metadata and LP token id
  - `ConditionalMarketOracle` for price history
  - `GovernanceExecutor` for payload execution
- `Venture` authorizes:
  - hub,
  - current `UmiaMarketCore`,
  - current governance executor (for selected functions)

## Storage and State Ownership

- **Registry state**: `UmiaHub`
- **Treasury + governance state**: `Venture`
- **Market and virtual token state**: `UmiaMarketCore`
- **Oracle cumulative state**: `ConditionalMarketOracle`
- **Swap permit nonce state**: `UmiaMarketCore`

## Existing docs to pair with this

- `DECISION_MARKET_FLOW.md` (detailed split/merge and settlement walkthrough)
- `GOVERNANCE_TREASURY_LAYER.md` (typed action model)
- `UPGRADES.md` (upgrade strategy notes)
