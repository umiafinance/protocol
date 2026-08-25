# Deploy MetaVesT Singletons

Runbook for deploying the per-chain MetaVesT vesting singletons via
`script/DeployMetaVest.s.sol`, with inline contract verification.

> Run this **once per target chain**. Nothing below is hardcoded to a specific
> network: point `RPC_URL` at the chain you're deploying to, set `CHAIN_ID` to its
> id, and record the results under that chain's entry in `contracts.json`
> (e.g. `testnet.base-sepolia`, `testnet.base`, `mainnet.base`).

## What this deploys

Five singletons, deployed **once per chain**:

| Contract                     | Source                 | Notes                        |
| ---------------------------- | ---------------------- | ---------------------------- |
| `MetaVesTFactory`            | MetaVesT (`@metavest`) | no constructor args          |
| `VestingAllocationFactory`   | MetaVesT (`@metavest`) | no constructor args          |
| `TokenOptionFactory`         | MetaVesT (`@metavest`) | no constructor args          |
| `RestrictedTokenFactory`     | MetaVesT (`@metavest`) | no constructor args          |
| `UmiaTwapMilestoneCondition` | Umia (`src/periphery`) | ctor arg `uint32 twapWindow` |

**Not deployed here** (created per-venture by `launch-with-vesting`): the per-venture
`MetaVesTController` and the Umia `VentureVestingAuthority` adapter.

## Prerequisites

Exported in the deploying shell (same env you use for `Deploy.s.sol`):

- `DEPLOYER_PRIVATE_KEY` — funded deployer key on the target chain (needs gas).
- `RPC_URL` — RPC endpoint for the target chain.
- `CHAIN_ID` — the target chain's id (used in verification + artifact paths).
- `ETHERSCAN_API_KEY` — block-explorer API key for the target chain's verifier
  (e.g. Basescan for Base chains, Etherscan for Ethereum).
- `TWAP_WINDOW` — *required*, seconds; no default. This is the condition's immutable
  observation window (30 days = `2592000` on mainnet); only lower it for fast test
  schedules. The deploy aborts without it so a forgotten value can't silently ship a
  30-minute condition that never touches the coarse oracle ring.

## Step 1 — build

```bash
just forge build
```

(`via-ir = true`, so the build is slow — expected.)

## Step 2 — simulate (no broadcast)

Dry-run first to confirm the script and env resolve cleanly:

```bash
just forge script script/DeployMetaVest.s.sol:DeployMetaVest --rpc-url "$RPC_URL" -vvv
```

Check the logged `Deployer:` matches `vm.addr(DEPLOYER_PRIVATE_KEY)` and the
`TWAP window (s):` is what you expect.

## Step 3 — broadcast + verify

```bash
just forge script script/DeployMetaVest.s.sol:DeployMetaVest \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  -vvv
```

`--verify` verifies all five contracts in the same step as the broadcast — no
manual follow-up needed if it succeeds.

## Step 4 — capture the addresses

The script prints them at the end as ready-to-paste `KEY=value` lines:

```
METAVEST_FACTORY=0x…
VESTING_ALLOCATION_FACTORY=0x…
TOKEN_OPTION_FACTORY=0x…
RESTRICTED_TOKEN_FACTORY=0x…
TWAP_MILESTONE_CONDITION=0x…
```

Broadcast artifacts are also saved under
`smart-contracts/broadcast/DeployMetaVest.s.sol/<CHAIN_ID>/`.

## Step 5 — record in `contracts.json` + rebuild

Add the five keys under the **target chain's `umia` block** in the repo-root
`contracts.json` (e.g. `testnet.base-sepolia.umia`, `testnet.base.umia`, `mainnet.base.umia`):

```jsonc
"umia": {
  ...,
  "metavestFactory":          "0x…",  // METAVEST_FACTORY
  "vestingAllocationFactory": "0x…",  // VESTING_ALLOCATION_FACTORY
  "tokenOptionFactory":       "0x…",  // TOKEN_OPTION_FACTORY
  "restrictedTokenFactory":   "0x…",  // RESTRICTED_TOKEN_FACTORY
  "twapMilestoneCondition":   "0x…"   // TWAP_MILESTONE_CONDITION
}
```

These map 1:1 to the optional fields in `shared/chain/src/contracts-config.ts`.
Then rebuild the chain package so services + CLI pick up the addresses:

```bash
bun --filter @umia/chain build
```

## Step 6 — sanity checks

```bash
# condition window matches the TWAP_WINDOW you deployed with
cast call "$TWAP_MILESTONE_CONDITION" "twapWindow()(uint32)" --rpc-url "$RPC_URL"
```

Confirm all five contracts show **Verified** on the target chain's block explorer.

## Troubleshooting verification

If `--verify` fails mid-broadcast (rate limit, indexer lag), re-verify from the
broadcast artifacts without redeploying:

```bash
# Umia condition — has a constructor arg
forge verify-contract "$TWAP_MILESTONE_CONDITION" \
  src/periphery/UmiaTwapMilestoneCondition.sol:UmiaTwapMilestoneCondition \
  --chain "$CHAIN_ID" \
  --constructor-args "$(cast abi-encode 'constructor(uint32)' 1800)" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch

# factories — no constructor args (resolve the path under lib/metavest/src)
forge verify-contract "$METAVEST_FACTORY" MetaVesTFactory \
  --chain "$CHAIN_ID" --etherscan-api-key "$ETHERSCAN_API_KEY" --watch
```

(Use the actual `TWAP_WINDOW` you deployed with in the constructor-args encoding.)

## After the deploy

Contracts alone don't finish the release. With `contracts.json` updated, redeploy
the services that gained vesting code/ABIs — **indexer (with reindex), keeper,
cron, api, hub** — and wire **cron → keeper** (`KEEPER_URL` + `KEEPER_API_SECRET`)
so the milestone cranker can confirm. No proxy upgrades are involved in this release.

Per-venture vesting is then created at launch via `internal-cli`'s
`launch-with-vesting` (which consumes these singletons + deploys the per-venture
`MetaVesTController` and `VentureVestingAuthority`).
