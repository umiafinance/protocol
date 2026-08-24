# Umia New Chain Deployment Runbook

This runbook covers deploying Umia protocol contracts to a new EVM chain and wiring the resulting addresses into the rest of the repo.

It is centered on `smart-contracts/script/Deploy.s.sol`, which deploys and configures the core Umia contracts.

## Scope

Use this document when you need to:

- deploy Umia to a public testnet or mainnet,
- redeploy Umia to a new environment on an already-supported chain,
- add support for a brand new chain ID across the repo.

For AWS environment provisioning after contracts are deployed, also follow `infra/aws/NEW_ENVIRONMENT.md`.

## What The Deploy Script Needs

`script/Deploy.s.sol:Deploy` requires these inputs:

- `DEPLOYER_PRIVATE_KEY` - funded deployer key used for all onchain transactions.
- `POOL_MANAGER` - Uniswap v4 `PoolManager` address for the target chain.
- `UMIA_HOOK_DEPLOYER` - EOA passed as `INITIAL_OWNER` to `UmiaHook`. Must match `vm.addr(DEPLOYER_PRIVATE_KEY)`; the script asserts `tx.origin == UMIA_HOOK_DEPLOYER`.
- `UMIA_HOOK_SALT` - CreateX salt mined offline (see "One-Time: Mine the UmiaHook Salt" below). Reused unchanged on every chain.

Operational roles (one of the two forms is required for each):

Both roles are deliberately separate from the Hub owner so an ops key is never the upgrade key, and
both are `address(0)` after `initialize`, which silently means the capability is off. The script
refuses to guess: supply the address, or acknowledge the off state explicitly. A forgotten export
cannot quietly ship a protocol with either capability disabled.

- `VESTING_ADMIN` - address allowed to terminate and reissue vesting grants on every venture adapter (ventures can opt out individually through futarchy). Set `VESTING_ADMIN_UNSET_OK=true` to deploy with no vesting admin.
- `VETO_GUARDIAN` - address allowed to trip (but not reset) decision-market circuit breakers. Set `VETO_GUARDIAN_UNSET_OK=true` to deploy with owner-only tripping.

Optional inputs:

- `MARKET_CREATION_SIGNER_KEY` - private key whose derived address becomes the market creation signer; defaults to the deployer if unset.
- `USDC_ADDRESS` - if set, the script immediately approves that token as a money token in `UmiaHub`.
- `CCA_FACTORY` - reuse an existing Continuous Clearing Auction factory instead of deploying a new one.
- `RECLAIM_ADDRESS` - reuse an existing `Reclaim` verifier instead of deploying a new one.

## One-Time: Mine the UmiaHook Salt

This step happens once for the entire protocol, not per chain. The singleton `UmiaHook` must be deployed at the same address on every chain (so Uniswap Labs only has to whitelist one address). CreateX makes that possible: same salt + same init code + same deployer EOA produces the same address on every chain.

The hook's address must also encode V4 permission flags in its lower 14 bits (`0x38C4`). Optional vanity: a leading byte (e.g. `0xCC`).

### Prerequisites

- Pick the deployer EOA. Same key used to broadcast `Deploy.s.sol` on every chain. Keep it cold.
- Decide vanity target. We use `0xCC` (1 leading byte). Longer prefixes require a native miner.

### Mine

`script/MineUmiaHookSalt.s.sol` is a Foundry script that calls CreateX's view function. Run it against a fork where CreateX (`0xba5Ed099...`) is present (Mainnet, Sepolia, Base, Unichain, etc.; the CreateX address is the same everywhere):

```bash
UMIA_HOOK_DEPLOYER=0xYourColdDeployerEOA \
VANITY_PREFIX=0xCC \
forge script script/MineUmiaHookSalt.s.sol --rpc-url "$MAINNET_RPC" -vv
```

Expected runtime: 5–15 minutes for `0xCC` + flags (~4M attempts average, single-threaded interpreted EVM).

Output ends with:

```
=== MATCH ===
Salt:
  0xdead00000000000000000000000000000000dd00000000000000000003a4f12c
Predicted address: 0xCC1234...0038C4
```

Save the salt and the predicted address. The salt becomes `UMIA_HOOK_SALT` for every chain deploy that follows. **Never re-mine after going live**; the address is part of the protocol's identity.

### When to re-mine

Only if any of these change:
- The deployer EOA (`UMIA_HOOK_DEPLOYER`).
- `UmiaHook` source code (any change to bytecode invalidates the init-code hash).
- CreateX address (canonical at `0xba5Ed099...`; would only change if a chain has a non-standard deployment).

If you re-mine, you get a new canonical address. Coordinate carefully: every deploy after the change must use the new salt, and any chain already deployed with the old salt stays on the old address forever.

### Factory immutability after `initialize`

Once `umiaHook.initialize(factory, poolManager)` is called, the `factory` address is immutable. Practical consequence: if `UmiaLBPFactory` is ever upgraded, the new factory address is **not** auto-whitelisted by the hook. LBPs deployed by a new factory will fail `registerPool` with `NotFactoryDeployedLBP`.

Two paths if a factory upgrade is needed:
- Mine a new hook address against the new bytecode/init code and go through the Uniswap Labs whitelist process again. The old hook keeps serving its existing pools forever; new pools point at the new hook.
- Migrate by aliasing inside the new factory (out of current scope; would require a design change).

There is intentionally no admin path to update `factory` on the hook. The trade-off is: simpler trust model and easier audit, at the cost of a one-shot commitment to whichever factory exists at the time of the first `initialize`.

## Preflight

Before broadcasting anything, collect and verify:

1. Chain metadata
   - chain ID
   - explorer URL
   - RPC URL
   - environment name you will use elsewhere in the repo, for example `sepolia`, `base`, or `arbitrum`
2. Upstream dependencies
   - official Uniswap v4 deployment addresses for the chain, if they exist
   - the money token address to approve, typically USDC
3. Operational keys
   - funded deployer key
   - dedicated market-creation signer key for non-local environments

Run the contract checks first:

```bash
just forge build
just forge test
```

## Testnet: shorten market lifecycle constants

Before `forge build`, edit the trading constants in
`smart-contracts/src/libraries/MarketCreationLib.sol:27-30` to testing-friendly
values (these are the ones market creation actually validates against). The
defaults are mainnet-tuned; on testnet they make every smoke test wait before
trading can even start.

| Constant                   | Mainnet default | Testnet value         |
| -------------------------- | --------------- | --------------------- |
| `TRADING_MAX_START_DELAY`  | `7 days`        | shorten to taste      |
| `TRADING_MIN_DURATION`     | `1 hours`       | keep or lower         |
| `TRADING_MAX_DURATION`     | `96 hours`      | shorten to taste      |
| `TRADING_DEFAULT_DURATION` | `3 days`        | `1 hours`             |

These are `internal constant`, so the change is a compile-time edit baked into
the deployed `UmiaMarketCore` implementation. Revert the file before any
mainnet deploy — there is no admin setter, and a wrong value means redeploying
the implementation and upgrading the proxy.

There is no on-chain minimum start delay: a `startTimestamp` at or before now
clamps to `block.timestamp` (open immediately). The only bound is
`TRADING_MAX_START_DELAY`. Seeded / CLI markets default to delay `0`; pass
`TRADING_START_DELAY` (or `tradingStartDelaySeconds`) only when you want a
future open.

## Local Chains Only: Deploy Uniswap v4 Infra First

`script/DeployV4Infra.s.sol:DeployV4Infra` is only for fresh local chains such as Anvil. Do not use it as the default path for public networks that already have canonical Uniswap v4 deployments.

```bash
export DEPLOYER_PRIVATE_KEY=0x...

just forge script script/DeployV4Infra.s.sol:DeployV4Infra \
  --rpc-url http://localhost:8545 \
  --broadcast
```

The script prints `POOL_MANAGER`, `PERMIT2`, `POSITION_MANAGER`, `STATE_VIEW`, and `WETH9`. Only `POOL_MANAGER` is an input to `Deploy.s.sol`; the rest belong in `contracts.json` under `uniswap.*`, where the API, hub and devnet fork fixes read them.

## Set Deployment Environment Variables

Example shell setup:

```bash
export RPC_URL=https://...
export DEPLOYER_PRIVATE_KEY=0x...
export MARKET_CREATION_SIGNER_KEY=0x...

export POOL_MANAGER=0x...

# UmiaHook (same values reused on every chain)
export UMIA_HOOK_DEPLOYER=0x...     # must equal vm.addr(DEPLOYER_PRIVATE_KEY)
export UMIA_HOOK_SALT=0xdead...     # from MineUmiaHookSalt.s.sol output

export USDC_ADDRESS=0x...

# Operational roles (separate from the owner). Supply the address, or set the
# matching _UNSET_OK flag to record that leaving the capability off is deliberate.
export VESTING_ADMIN=0x...
export VETO_GUARDIAN=0x...

# Optional reuse points
export CCA_FACTORY=0x...
export RECLAIM_ADDRESS=0x...
export CCA_EXIT_HELPER_ADDRESS=0x...
```

Notes:

- `UMIA_HOOK_DEPLOYER` and `UMIA_HOOK_SALT` are the same on every chain. Do not re-mine per chain.
- The deploy script asserts `tx.origin == UMIA_HOOK_DEPLOYER`. If the broadcasting key differs, the script aborts before any state change.
- Leave `CCA_FACTORY` unset to deploy a fresh CCA factory.
- Leave `RECLAIM_ADDRESS` unset to deploy a fresh `Reclaim` contract.
- Leave `CCA_EXIT_HELPER_ADDRESS` unset to deploy a fresh `CCAExitHelper` (logged as `CCAExitHelper deployed at:`). Record it into `contracts.json` under `umia.ccaExitHelper` to enable single-tx live out-bid exits on this chain; the hub falls back to a two-tx exit when it is absent.
- Leave `USDC_ADDRESS` unset if you do not want the deploy script to approve a money token yet.
- `VESTING_ADMIN` and `VETO_GUARDIAN` are the only inputs the script will not let you forget: it aborts unless each is either set or explicitly acknowledged as unset. Both are changeable later via `hub.setVestingAdmin` / `hub.setVetoGuardian` (owner-only).

## Simulate Before Broadcast

Run the deploy script once without `--broadcast` to catch missing env vars or constructor issues:

```bash
just forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
```

If the simulation succeeds, broadcast the deployment with contract verification:

```bash
just forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Set `ETHERSCAN_API_KEY` to the appropriate block explorer API key for the target chain (e.g. Basescan for Base, Etherscan for Ethereum). This verifies all deployed contracts in the same step as the broadcast, so you don't have to go back and verify them manually.

## Capture Deployment Artifacts

The deploy script logs the addresses you need immediately after deploy. Record all of them.

Core outputs printed by the script:

- `UMIA_HUB_ADDRESS`
- `UMIA_MARKET_MANAGER_ADDRESS`
- `UMIA_GOVERNANCE_EXECUTOR_ADDRESS`
- `UMIA_SWAP_ROUTER_ADDRESS`
- `CONDITIONAL_MARKET_ORACLE_ADDRESS`
- `SPOT_MARKET_PRICE_GUARD_ADDRESS`
- `CCA_FACTORY_ADDRESS`
- `AUCTION_STATE_LENS_ADDRESS`
- `UMIA_HOOK_ADDRESS` (identical across chains)
- `LBP_FACTORY_ADDRESS`
- `RECLAIM_ADDRESS`
- `UMIA_MARKET_STAKE_ADDRESS`
- `start_block`

Sanity check before recording: `UMIA_HOOK_ADDRESS` must equal the predicted address from the mining step. The deploy script asserts this internally, but worth double-checking against your saved value.

Also keep the implementation-level addresses that are logged earlier in the run:

- `UmiaHub implementation`
- `UmiaMarketCore implementation`
- `Venture implementation`
- `Venture beacon`

Foundry also writes the transaction trace to:

```text
smart-contracts/broadcast/Deploy.s.sol/<chain-id>/run-latest.json
```

Keep that file until the deployment is fully recorded elsewhere.

## Verify Onchain Configuration

After broadcast, confirm that the hub points at the freshly deployed contracts and that the money token approval landed if you set `USDC_ADDRESS`.

```bash
cast call "$UMIA_HUB_ADDRESS" "umiaMarketCore()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "defaultGovernanceExecutor()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "conditionalMarketOracle()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "spotMarketPriceGuard()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "lbpStrategyFactory()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "ccaFactory()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "marketCreationSigner()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "approvedMoneyTokens(address)(bool)" "$USDC_ADDRESS" --rpc-url "$RPC_URL"

# UmiaHook wiring
cast call "$LBP_FACTORY_ADDRESS" "umiaHook()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HOOK_ADDRESS" "factory()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HOOK_ADDRESS" "poolManager()(address)" --rpc-url "$RPC_URL"
```

Expected result:

- each hub getter returns the address printed by the deploy script,
- `approvedMoneyTokens` returns `true` if you passed `USDC_ADDRESS`,
- `lbpFactory.umiaHook()` returns `UMIA_HOOK_ADDRESS`,
- `umiaHook.factory()` returns `LBP_FACTORY_ADDRESS`,
- `umiaHook.poolManager()` returns the `POOL_MANAGER` you passed in,
- `UMIA_HOOK_ADDRESS` is byte-for-byte identical to the predicted address from the mining step and to any prior chain's `UMIA_HOOK_ADDRESS`.

If you did not set `USDC_ADDRESS`, skip the final call.

## Update `contracts.json`

Add or update the target chain entry under its environment in the repo root `contracts.json`.

Example (deploying to a new chain `monad-testnet` in the testnet environment):

```json
{
  "testnet": {
    "monad-testnet": {
      "chainId": 10143,
      "umia": {
        "hub": "0x...",
        "marketCore": "0x...",
        "conditionalMarketOracle": "0x...",
        "spotMarketPriceGuard": "0x...",
        "ccaFactory": "0x...",
        "auctionStateLens": "0x...",
        "umiaHook": "0xCC...",
        "lbpFactory": "0x...",
        "governanceExecutor": "0x...",
        "marketStake": "0x...",
        "reclaim": "0x..."
      },
      "uniswap": {
        "poolManager": "0x...",
        "positionManager": "0x...",
        "permit2": "0x...",
        "stateView": "0x..."
      },
      "usdc": "0x..."
    }
  }
}
```

This file is consumed by the API, CLI, cron jobs, and other services that resolve chain-specific addresses at runtime.

## Update Indexer Config

For local development, update `services/indexer/config.yaml`.

For AWS environments, create or update `infra/aws/configs/indexer.<env>.yaml` as described in `infra/aws/NEW_ENVIRONMENT.md`.

Each network entry must include:

- `id` - target chain ID
- `start_block` - use the block number printed by the deploy script
- `UmiaHub`
- `UmiaMarketCore`
- `PoolManager`
- `CCAFactory`
- `UmiaHook` (singleton, same address across chains)
- `UmiaLBPFactory`

Keep placeholder `0x000...` addresses for dynamically created contracts that the indexer discovers from events:

- `Venture`
- `VentureToken`
- `CCA`
- `UmiaLBP`
- `UmiaValidationHook`

Note: `UmiaLBP` is still per-launch (one deployed per project) but no longer the V4 hook. Pool swap/liquidity/oracle events now fire on `UmiaHook` (singleton). If the indexer watches V4 hook events, the listening address moves from per-launch `UmiaLBP` to the singleton `UmiaHook`.

## Repo-Wide Chain Registration

If this is a brand new chain ID for the repo, contract deployment is only part of the work. Several services keep explicit chain maps and must be updated before the environment works end-to-end.

At minimum, review these files:

- `shared/types/src/chains.ts`
- `services/indexer/src/utils/rpc.ts`
- `services/keeper/src/lib/chains.ts`
- `web/hub/lib/wagmi-config.ts`
- `web/admin/lib/wagmi-config.ts`
- `web/inbound/app/api/venture-callback/route.ts`

When adding the chain, confirm:

- `chainId -> chain name` resolution matches the key you used in `contracts.json`
- viem or wagmi chain metadata exists, or you define a custom chain
- the correct explorer URL is wired everywhere that renders links
- `blockscout` is set on the chain's `CHAIN_ENTRIES` entry in `shared/types/src/chains.ts` if a public Blockscout instance exists — the /buy swap history reads it client-side and silently skips chains without one
- `SUPPORTED_CHAINS` and per-chain RPC variables are set in deployed services

## Service Configuration Handoff

After contracts are deployed and recorded, the rest of the stack normally needs:

- `SUPPORTED_CHAINS=<chain-id>` or a comma-separated list including the new chain
- `RPC_URL_<chain-id>=https://...` or an `ERPC_URL` that covers that chain
- `UMIA_MARKET_MANAGER_ADDRESS=0x...`
- `UMIA_HUB_ADDRESS=0x...` where applicable
- frontend `CHAIN_ID` or `NEXT_PUBLIC_CHAIN_ID` set to the target chain

For AWS-managed environments, use `infra/aws/NEW_ENVIRONMENT.md` for the full infra, secret, and service deployment checklist.

## Final Checklist

- `just forge build` and `just forge test` passed before deployment
- `UMIA_HOOK_SALT` and `UMIA_HOOK_DEPLOYER` are set to the values from the one-time mining step
- `UMIA_HOOK_DEPLOYER` matches `vm.addr(DEPLOYER_PRIVATE_KEY)`
- deploy script simulated successfully without `--broadcast`
- deploy script broadcast successfully
- `UMIA_HOOK_ADDRESS` matches the predicted address from mining (and matches any prior chain's hook address)
- `lbpFactory.umiaHook()` == `umiaHook.address`, `umiaHook.factory()` == `lbpFactory`, `umiaHook.poolManager()` == `POOL_MANAGER`
- all printed addresses were copied into `contracts.json`
- indexer config was updated with the right `chain id`, `start_block`, and singleton `UmiaHook` address
- service secrets and env vars were updated
- chain metadata maps were updated if the chain ID was new to the repo
- onchain hub getters match the deployment output
