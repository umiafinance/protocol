# VentureVestingAuthority

Source: `src/periphery/VentureVestingAuthority.sol`

## Purpose

A per-venture adapter that holds a [MetaVesT](../metavest/README.md) controller's
`authority` role and routes it to the venture treasury, so that **after launch only futarchy can
create / amend / terminate vesting allocations**. The launch operator (ADMIN) deploys it before the
venture exists, hands the controller authority to it **before genesis grants**, funds each grant via
`fundGenesisGrant`, closes genesis with `closeGenesis`, and binds it to the treasury after launch.

It exists to bridge a timing gap: at genesis the treasury does not exist yet, but ADMIN must already
be out of the authority seat before the venture goes live. The adapter can accept the authority role
immediately (it is a plain contract) and resolve its treasury later, once the venture is created.

The adapter is **also the per-allocation price-milestone registry**. A grant's price ladder is
written here in the *same transaction* as `createMetavest` (genesis or futarchy), so grants and their
ladders share a single mutating path and a single auth gate. The [`UmiaTwapMilestoneCondition`](./UmiaTwapMilestoneCondition.md)
singleton reads thresholds back from the adapter via `effectiveThreshold` (`allocation → controller →
authority`); there is no separate ladder-registration step and no finalize/anchor step.

## Key design choices

- **Genesis-to-launch bridge** — ADMIN hands the controller authority to the adapter *before*
  genesis grants, so every grant routes through the adapter and emits `AllocationFunded` for the
  indexer (§8.1).
- **`fundGenesisGrant`** — deployer-gated pre-launch path: pulls tokens from the operator, forwards
  `createMetavest` to the controller, emits `AllocationFunded`, and registers the grant's price ladder
  atomically. Reverts after `bind` or `closeGenesis`.
- **`closeGenesis`** — write-once seal on the genesis funding window; post-launch grants use
  `forward` only.
- **`bind` is deployer-gated and write-once** — only the deployer (the launch operator) can bind,
  exactly once, and the treasury is resolved from `UmiaHub.ventureById(id).venture` rather than taken
  from caller input.
- **`forward` is gated to the treasury** — the only mutating path post-launch. A passed market reaches
  it via `Venture.executeCall`. Emits `AllocationFunded` and registers the price ladder when calldata
  is `createMetavest`; `priceProgram.kind` must be `None` for non-`createMetavest` calls.
- **Atomic price-ladder registry** — a grant's ladder is written in the same transaction as the grant.
  The condition resolves thresholds back from this adapter, so there is one write path and one auth
  gate for grants and ladders, and no separate registration on the condition.
- **No stored CCA; lazy relative thresholds** — the adapter stores no auction reference. `cca()`
  resolves the venture's auction live as `IUmiaLBP(venture.lbp()).initializer()` (zero before `bind`),
  so a relative ladder's threshold is computed live at read time against the current clearing price.
  There is no anchoring or finalize step.
- **Funding via a standing allowance** — `createMetavest` pulls a grant's tokens from the controller's
  `authority` (this adapter), so `bind` grants the controller a `type(uint256).max` allowance of the
  venture token.
- **No AGPL linkage** — the controller is reached through local interfaces, so the deployed adapter
  carries no MetaVesT import (cf. `UmiaTwapMilestoneCondition`).

## Key state

- `deployer` / `hub` / `controller` — immutables set in the constructor.
- `treasury` — the bound venture treasury (set once, in `bind`).
- `bound` — whether `bind` has run.
- `genesisClosed` — whether `closeGenesis` has run.
- `_programs[allocation]` — per-allocation price ladder, write-once at grant creation. A
  `PriceProgram` carries a `kind` (`None` / `Absolute` / `Relative`) plus either a `uint160[]` of Q96
  absolute thresholds or a `uint256[]` of `1e6`-scaled multiples; the other array is empty. A relative
  ladder stores **no anchor** — the auction is resolved live at read time. `MULTIPLE_SCALE = 1e6`, so a
  2x multiple is stored as `2_000_000`. An optional `uint48[] cliffs` array (empty, or one unix
  timestamp per milestone) time-gates individual milestones; `0` means price-only.

## Price ladders

A ladder is supplied alongside a grant as a `PriceProgramInput`:

```solidity
enum PriceProgramKind { None, Absolute, Relative }

struct PriceProgramInput {
    PriceProgramKind kind;
    uint160[] absoluteThresholds; // kind == Absolute (Q96, moneyToken per ventureToken)
    uint256[] multiplesX1e6;      // kind == Relative (1e6 scale: 2x == 2_000_000)
    uint48[] cliffs;              // optional per-milestone cliff timestamps (unix seconds); 0 = price-only
}
```

`kind` selects which array applies; the other must be empty. Registration is **write-once** per
allocation and validates the ladder: a `None` input must carry no data and is a no-op (the grant
simply has no price milestones — arrays alongside `kind == None` revert `InvalidPriceProgram`),
and a non-empty ladder must have strictly **ascending**, **non-zero** thresholds / multiples
(`EmptyThresholds`, `ZeroThreshold`, `ThresholdsNotAscending`). A ladder may only ride a
`createMetavest` call; attaching one to an amend/terminate reverts `InvalidPriceProgram`.

`cliffs` is either empty (no milestone has a cliff — today's price-only behavior) or exactly one
entry per milestone (`CliffsLengthMismatch` otherwise). A non-zero entry is an **absolute unix
timestamp** the milestone cannot confirm before, even when the price gate is already met; a `0`
entry leaves that milestone price-only. Cliffs are stored verbatim for absolute and relative
ladders alike.

## Important functions

### Mutating (grants + ladders)

- `claim()` — accept the controller's pending-authority role (its two-step handoff).
- `fundGenesisGrant(token, amount, createMetavestCalldata, priceProgram)` — fund and create a genesis
  grant and register its price ladder atomically; emits `AllocationFunded` and, for a non-`None`
  ladder, `PriceProgramRegistered`. Deployer-gated, pre-`bind`. Any over-funded remainder (`amount`
  above the grant total the controller pulls) is returned to the deployer.
- `forward(data, priceProgram)` — forward an authority call (`createMetavest` / amend / terminate) to
  the controller, and register the price ladder when the call is `createMetavest`. Gated to the bound
  treasury, so only futarchy drives it. `priceProgram.kind` must be `None` for non-`createMetavest`
  calls (else `InvalidPriceProgram`).
- `closeGenesis()` — permanently close the genesis funding window; emits `GenesisSealed` and reverts
  if already closed.
- `bind(ventureId)` — resolve the treasury from the Hub and lock it in (deployer-gated, write-once),
  and grant the controller a standing allowance of the venture token. Emits
  `Bound(ventureId, treasury, token)`.

### Read surface (consumed by the condition)

- `effectiveThreshold(allocation, idx)` — the threshold the condition compares the TWAP against. For
  an **absolute** program returns the stored Q96 threshold; for a **relative** program returns
  `multiple × clearingPrice / 1e6` computed **live** at read time (capped at `type(uint160).max`).
  Reverts `NotRegistered` (no program, or `idx` out of range) and `AuctionNotCleared` (unbound, or the
  auction's `clearingPrice()` is 0).
- `cca()` — the venture's auction, resolved live as `IUmiaLBP(venture.lbp()).initializer()`. Returns
  zero before `bind`. **No stored CCA**: relative thresholds are lazy and always reflect the current
  clearing price.
- `effectiveCliff(allocation, idx)` — the milestone's cliff timestamp (unix seconds); `0` when the
  milestone has no cliff. Reverts `NotRegistered` (no program, or `idx` out of range). Never needs
  the auction — cliffs resolve pre-`bind` even for relative programs.
- `priceProgramKind(allocation)` — `None` / `Absolute` / `Relative` for the allocation.
- `programLength(allocation)` — number of milestones in the ladder.
- `absoluteThresholdAt(allocation, idx)` — the stored absolute threshold (reverts for a relative
  program).
- `multipleAt(allocation, idx)` — the stored `1e6`-scaled multiple (reverts for an absolute program).

## Events

- `AllocationFunded(controller, allocation, beneficiary, token, allocationType, streamTotal, milestoneAwardTotal)`
  — authoritative indexer discovery signal for every grant (genesis and post-launch).
- `PriceProgramRegistered(allocation, token, programKind, count, cliffs)` — emitted (in the same tx
  as funding) when a non-`None` price ladder is registered; `programKind` is `1` for absolute, `2`
  for relative, `count` is the number of milestones, and `cliffs` is the per-milestone cliff array
  (empty when the program has none). The indexer reads this to flag a milestone as price-gated and
  record its cliff.
- `Bound(ventureId, treasury, token)` — links orphan genesis allocations to the venture by token.
- `GenesisSealed()` — the genesis funding window has been permanently closed.

## Integration

At genesis the operator deploys the adapter, hands authority, funds grants (with their ladders) via
`fundGenesisGrant`, calls `closeGenesis`, launches, and binds (§8.1). Post-launch, governance funds
and creates grants (with their ladders) through `forward` (§8.2). The `UmiaTwapMilestoneCondition`
singleton resolves each milestone's threshold from this adapter at check time; there is no separate
registration or finalize step. See [the MetaVesT integration doc](../metavest/README.md) (authority model + adapter).
