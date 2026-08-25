# Building a Liquidation Proposal

Practical guide for constructing a correct `LIQUIDATE_TREASURY` decision-market
proposal. Liquidation is terminal and irreversible, and two ordering details
decide whether treasury value is distributed **fairly and completely** or is
silently lost. Both are properties of the **execution plan**, not the contracts —
a plan that skips them still executes, just wrongly.

See [GOVERNANCE_TREASURY_LAYER.md](./GOVERNANCE_TREASURY_LAYER.md) for the action
language and encoding. This doc is the liquidation-specific checklist.

## What liquidation does

`LIQUIDATE_TREASURY` (in `GovernanceActions._executeLiquidation`):

1. Redeems the venture's spot-LP shares into the treasury.
2. Snapshots the pro-rata denominator as `claimableSupply = totalSupply − treasuryHeld`.
3. Calls `venture.setLiquidator(liquidator)` → sets `liquidationActive = true` (terminal).
4. `ILiquidator(liquidator).initialize(venture, assets, claimableSupply)`.

Holders then `claim()` on the liquidator: it burns the caller's entire venture-token
balance and pays `assetBalance × userBalance / claimableSupply` of each listed asset,
withdrawn straight from the treasury. Assets never move into the liquidator — it
authorizes treasury withdrawals per claim.

## The canonical action ordering

A correct plan is ordered so every state change that must precede the snapshot runs
**before** `LIQUIDATE_TREASURY`, which is always last:

```
CALL → VentureVestingAuthority.terminateGrant(allocation_i)   // one per grant, see §1
...
SET_ALLOWANCE(moneyToken, spender_j, 0)                       // one per live allowance, see §2
...
LIQUIDATE_TREASURY(liquidator, assets)                        // always last
```

Once `LIQUIDATE_TREASURY` runs, `liquidationActive` is `true` and the venture is
frozen: `executeCall` (`whenNotLiquidating`) and every vesting-admin path
(`LiquidationActive` guard) revert. Anything you did not do before this action can
never be done. That is why both concerns below are *pre-liquidate* actions in the
same atomic plan.

## §1 — Terminate vesting/price-milestone grants first

**The hazard.** The snapshot denominator is `totalSupply − treasuryHeld`, which
**includes tokens held by MetaVesT vesting allocation contracts**. Those contracts
cannot call `claim()`. Worse, tokens gated on a **price milestone that was never met**
(and any still-unvested tokens) will never reach a wallet that can claim. Their share
of the treasury is neither delivered to the grantee nor redistributed to claimers — it
is allocated in the denominator and then **stranded in the treasury forever**. A pure
deadweight loss, and it is borne entirely by the locked holders while every claimer
still receives their exact pro-rata.

**The fix.** Prepend a `CALL` action per grant that invokes
`VentureVestingAuthority.terminateGrant(allocation)` — ordered before
`LIQUIDATE_TREASURY`. This works on the deployed contracts, no protocol change,
because of two facts that hold only *before* the liquidate action runs:

- A `CALL` action executes via `venture.executeCall(...)`, so `msg.sender` reaching
  the vesting authority is the **venture itself**, and `_requireVestingAdmin` allows
  `msg.sender == treasury`. (`executeCall`'s `whenNotLiquidating` is also still
  satisfied.)
- `liquidationActive` is still `false`, so the authority's `LiquidationActive` guard
  does not trip.

`terminateGrant` keeps each grantee's **earned (vested)** portion in their allocation
and claws the **unearned** portion — unvested time plus unmet price milestones,
evaluated at the liquidation instant — back to the treasury via `_sweep`. Because the
clawed-back tokens now count as `treasuryHeld`, the subsequent snapshot **excludes
them automatically**. No new denominator logic; the existing `totalSupply −
treasuryHeld` does the work.

Result: unearned performance forfeits, earned holders keep exactly what they earned,
claimers split the treasury with no dilution, and nothing strands.

**Notes.**
- Enumerate a venture's grants from the vesting authority's indexed
  `AllocationFunded(controller, allocation, beneficiary, …)` events (same source the
  runtime-verify tooling uses).
- Grantees still `claim()` for their **earned** share: they withdraw the vested tokens
  from their allocation to a wallet, then call `claim()`. The plan handles the
  *exclusion* of the unearned part; collecting the earned part is the holder's action
  (their allocation withdrawal is not blocked by liquidation — only the admin
  terminate path is).
- One `CALL` per grant: plan size and execution gas scale with grant count. Fine for
  tens of grants; batch or add a terminate-all helper if a venture has hundreds.

## §2 — Zero every live money-token allowance first

**The hazard.** `setLiquidator` only flips the terminal flag; it does **not** revoke
standing ERC20 approvals, and after it runs they can no longer be cleared. Any spender
still approved on a claim-backing asset can `transferFrom` the treasury **after** the
snapshot and drain assets that claimants are owed.

**The fix.** Prepend a `SET_ALLOWANCE(token, spender, 0)` action for **every live
allowance** on each distributable asset (the money token, plus any other listed
treasury asset), ordered before `LIQUIDATE_TREASURY`.

**Notes.**
- ERC20 allowances are not enumerable on-chain. Build the spender set from the indexed
  `AllowanceSet(token, spender, amount)` events, plus any known integrations (vault,
  market stake, market core, executor, Permit2 / position manager / router). Treat it
  as best-effort: one live allowance left open can drain claims.
- Never list the **venture token** as a distributable asset. It is the claim-burn
  token; the liquidator skips it (paying it out pro-rata would let a claimant forward
  the payout and claim again).

## Tooling

`services/internal-cli/scripts/create-liquidation-dm.ts` builds the plan and already
handles §2 (allowance zeroing, with `--allowance-spender` for spenders the derived set
misses). Extending it to auto-discover grants and prepend the §1 `terminateGrant`
`CALL`s makes fair liquidations a one-command operation.

## Ordering rule of thumb

> Everything that must be true at the snapshot has to happen **before**
> `LIQUIDATE_TREASURY`, in the same atomic plan. After it, the venture is frozen.
> Terminate grants, then zero allowances, then liquidate — always in that order,
> liquidate last.
