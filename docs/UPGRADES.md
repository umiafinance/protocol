# Contract Upgrade Strategy

This document specifies the upgrade mechanisms for Umia Protocol smart contracts.

## Architecture Overview

```
┌─────────────┐      ┌─────────────┐      ┌─────────────────────┐
│   UmiaHub   │─────▶│    Venture     │─────▶│ Uniswap V4 Position │
│  (registry) │      │ (treasury)  │      │   (LP NFT owner)    │
└─────────────┘      └─────────────┘      └─────────────────────┘
       │                    │
       │                    │ approves operator
       ▼                    ▼
┌─────────────────────────────────────────┐
│         UmiaMarketCore               │
│  (approved to modify LP positions)      │
└─────────────────────────────────────────┘
```

| Contract          | Description                                                            |
| ----------------- | ---------------------------------------------------------------------- |
| UmiaHub           | Central registry; deploys ventures and stores protocol contract addresses |
| Venture              | Treasury contract; holds venture assets under governance control       |
| UmiaMarketCore | Operates on LP positions to create and settle decision markets         |

## Registry Pattern

UmiaHub implements a registry pattern that enables hot-swapping of stateless periphery contracts without proxies.

Registry setters:
- `setUmiaMarketCore(address)`
- `setDefaultGovernanceExecutor(address)`
- `setConditionalMarketOracle(address)`
- `setLbpStrategyFactory(address)`
- `setVentureBeacon(address)`

Dependent contracts resolve references dynamically:

```solidity
IConditionalMarketOracle oracle = IConditionalMarketOracle(HUB.conditionalMarketOracle());
IGovernanceExecutor(HUB.governanceExecutor(venture)).executeProposal(...);
```

## Contract Classification

| Contract                | State          | Upgrade Strategy | Mechanism                                           |
| ----------------------- | -------------- | ---------------- | --------------------------------------------------- |
| UmiaMarketCore       | Heavy          | UUPS Proxy       | Active markets and ERC6909 balances require proxy   |
| Venture                    | Medium         | Beacon + UUPS    | Beacon for protocol upgrades, UUPS opt-out per venture |
| UmiaHub                 | Medium         | UUPS Proxy       | venture registry requires state preservation           |
| GovernanceExecutor      | Stateless      | Registry Swap    | `hub.setDefaultGovernanceExecutor()`                |
| ConditionalMarketOracle | Per-proposal   | Registry Swap    | `hub.setConditionalMarketOracle()`                  |
| VentureToken               | ERC20 balances | Non-upgradeable  | Token identity tied to address                      |
| UmiaLBP                 | Lifecycle      | Non-upgradeable  | Terminates after migration                          |

---

## UUPS Proxy Contracts

### UmiaMarketCore

State that requires proxy preservation:
- ERC6909 virtual token balances per user per proposal
- Active market state (`_marketById`, `_proposalById`)
- CPMM reserves (`cpmmStates`)
- Settlement state (`hasClaimed`, `liquidityRemovalInfo`)
- Market stake deposits (`marketStakes`)

```solidity
mapping(uint256 => Market) private _marketById;
mapping(uint256 proposalId => CPMM.State) public cpmmStates;
mapping(uint256 tokenId => uint256) public totalSupply;
```

Registry swap is not viable; all active markets and user balances would be invalidated.

`MarketCreationLib` and `SettlementLib` are external libraries linked into every implementation.
A new implementation deploys fresh copies; `script/UpgradeMarketCore.s.sol` reads the linked
addresses out of the bytecode so they can be recorded and verified.

Upgrade process: see [Runbook](#runbook) (`just forge-upgrade market-core <env> <chain>`).

File: `src/core/UmiaMarketCore.sol`

### UmiaHub

State that requires proxy preservation:
- `ventureCount`, `_ventureById` (venture registry)
- `approvedMoneyTokens` (token whitelist)

Upgrade process: see [Runbook](#runbook) (`just forge-upgrade hub <env> <chain>`).

File: `src/core/UmiaHub.sol`

---

## Venture: Beacon + UUPS Opt-Out

Venture uses an UpgradeableBeacon for protocol-wide upgrades with per-venture UUPS opt-out via governance.

### Architecture

```
                    ┌────────────────────────────┐
                    │   UpgradeableBeacon        │
                    │   - Stores canonical impl  │
                    │   - Owned by Umia owner    │
                    │   - upgradeTo(VentureV2)      │
                    └─────────────┬──────────────┘
                                  │ implementation()
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
     ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
     │  VentureProxy (A)  │ │  VentureProxy (B)  │ │  VentureProxy (C)  │
     │  follows beacon │ │  follows beacon │ │  opted out ─────┼──▶ CustomImpl
     └─────────────────┘ └─────────────────┘ └─────────────────┘
```

VentureProxy is a custom proxy (`src/core/VentureProxy.sol`) that checks the ERC1967 implementation slot first. If empty (default), it falls back to the beacon. This allows per-venture UUPS opt-out while keeping the beacon as the default upgrade path.

```solidity
function _implementation() internal view override returns (address impl) {
    impl = ERC1967Utils.getImplementation();
    if (impl == address(0)) {
        impl = IBeacon(_beacon).implementation();
    }
}
```

OZ does not provide a hybrid beacon/ERC1967 proxy — VentureProxy is a custom 29-line contract composed from OZ primitives (`Proxy`, `ERC1967Utils`, `IBeacon`). Venture overrides `_checkProxy()` to only verify delegatecall context, since the default OZ check (`getImplementation() == __self`) fails for beacon-mode Ventures where the implementation slot is `address(0)`.

### Upgrade Paths

**Protocol-level upgrades (owner-controlled)**

The beacon owner upgrades the beacon. All ventures that haven't opted out receive the update atomically.

```
Owner (EOA / multisig / timelock) → UpgradeableBeacon.upgradeTo(VentureImplV2)
```

Use cases: bug fixes, security patches, protocol improvements.

**Per-venture upgrades (Decision market)**

A venture opts out of the beacon by writing a direct implementation to its ERC1967 slot via governance.

```
Decision Market wins → GovernanceExecutor → Venture.upgradeToAndCall(CustomImpl, "")
```

Use cases: venture-specific customizations, opting out of protocol updates.

### Default Behavior

New ventures are deployed as VentureProxy pointing to the shared UpgradeableBeacon. Protocol upgrades via the beacon apply to all default ventures automatically. No action required from individual venture communities.

### Opting Out

A venture can vote via decision market to upgrade to a custom implementation. This writes to the ERC1967 implementation slot, and VentureProxy will read that slot instead of the beacon from that point on. The venture no longer receives automatic protocol updates and assumes full responsibility for its implementation.

### Governance Action

```solidity
// GovernanceTypes.sol
enum ActionType {
    // ... existing actions
    UPGRADE_IMPLEMENTATION
}

struct UpgradeImplementation {
    address newImplementation;
    bytes data;
}
```

```solidity
// Venture.sol
function _authorizeUpgrade(address) internal override onlyExecutor {}
```

Files:
- `src/core/Venture.sol`
- `src/core/VentureProxy.sol`
- `src/libraries/GovernanceTypes.sol`
- `src/libraries/GovernancePayloadValidator.sol`
- `src/libraries/GovernanceActions.sol`

---

## Registry Swap Contracts

These contracts are stateless or have ephemeral state, enabling upgrade via registry swap.

### GovernanceExecutor

```solidity
UmiaHub public immutable HUB;
```

Upgrade:
1. Deploy `GovernanceExecutorV2(hubAddress)`
2. Call `hub.setDefaultGovernanceExecutor(v2Address)`

File: `src/core/GovernanceExecutor.sol`

### ConditionalMarketOracle

```solidity
mapping(uint256 proposalId => OracleState) public oracleStates;
```

Per-proposal state is written once by `initialize` (guarded by `AlreadyInitialized`) and cannot be
reconstructed after the fact, so a replacement oracle only serves markets created after the swap.

The `initialize`/`update`/`calculateTWAP` interface is the upgrade seam. `initialize` receives the
scoring window and the market's snapshotted `winningThresholdBps`, so a replacement implementation
(e.g. one whose clamp is calibrated to the threshold) needs no new inputs from the core — the swap
is a Hub pointer change, with no `UmiaMarketCore` implementation upgrade.

Upgrade:
1. Wait for all active markets to settle (oracle data required for settlement); the setter's
   `withNoActiveMarkets` guard enforces this
2. Deploy `ConditionalMarketOracleV2(hubAddress)`
3. Call `hub.setConditionalMarketOracle(v2Address)`

Constraint: Cannot swap during active markets due to cumulative price history dependency.

File: `src/periphery/ConditionalMarketOracle.sol`

### Swaps that are not free

- `hub.setUmiaMarketCore` is gated by `withNoActiveMarkets`; prefer a UUPS upgrade of the existing
  proxy, which needs no quiet window.
- `hub.setLbpStrategyFactory` alone breaks new launches: `UmiaHook` is bound to one factory at
  `initialize` and is CREATE2-canonical, so a new factory means a new hook (salt mining, new pool
  keys for future ventures). Treat it as a redeploy of the launch stack.
- Every address change is a release: `contracts.json` is baked into the api, keeper, cron, and
  indexer images and bundled into the hub, and the indexer config is generated from it with one
  static address per contract (keep the old address listed so history stays indexed).

---

## Non-Upgradeable Contracts

### VentureToken

- ERC20Pausable with mint/burn/pause/unpause controlled by Venture owner
- Lifecycle bound to its venture
- Address change would invalidate holder balances

### UmiaLBP

- Lifecycle contract: auction → migration → dormant
- Fresh deployment per venture via factory
- Post-migration LBPs are dormant and unaffected by upgrades

### Uniswap V4 References

`UmiaHub` holds no Uniswap addresses. The only one baked into the protocol is the
`PoolManager`, fixed at construction on `UmiaLBPFactory` and at `initialize()` on
`UmiaHook`; changing it means redeploying both, not a Hub upgrade. The remaining
addresses (`POSITION_MANAGER`, `PERMIT2`, `STATE_VIEW`) live only in `contracts.json`
for off-chain consumers.

---

## Governance

### Protocol Contracts

UmiaHub, UmiaMarketCore, and the Venture UpgradeableBeacon are owner-gated onchain.
In production, owner can be an EOA, multisig, timelock, or governance contract.

```
Owner (recommended: multisig + timelock)
    ├── UmiaHub UUPS
    ├── UmiaMarketCore UUPS
    └── Venture UpgradeableBeacon
```

### Timelock Adoption

`script/DeployTimelock.s.sol` deploys a stock OpenZeppelin `TimelockController` and
transfers ownership of the UmiaHub proxy (and optionally the Venture beacon) to it.
UmiaMarketCore needs no transfer: its `_authorizeUpgrade` checks `HUB.owner()`.

Role layout:

```
Safe multisig ── PROPOSER_ROLE + CANCELLER_ROLE ──▶ TimelockController ──owns──▶ UmiaHub, beacon
anyone        ── EXECUTOR_ROLE (open)           ──▶ execute() after minDelay
timelock      ── DEFAULT_ADMIN_ROLE (self)      ──▶ role/delay changes via scheduled ops
```

Every owner action becomes `schedule()` (from the Safe) → wait `minDelay`
(default 2 days) → `execute()` (anyone, payload is fixed at schedule time).
The Safe can `cancel()` a queued operation during the delay. Emergency response
stays instant through the separate `vetoGuardian` key, which trips decision-market
circuit breakers without touching the timelock; resets remain owner-gated and
therefore timelocked.

UmiaHub uses single-step `Ownable`, so adoption is irreversible; the script
asserts the timelock's role configuration before transferring. Devnet keeps the
deployer-owned hub (seeding needs instant setter access), so the script is
opt-in and not part of `Deploy.s.sol`.

Tests: `test/governance/HubTimelock.t.sol` (governance flow through the timelock) and
`test/governance/DeployTimelock.t.sol` (adoption script guard rails).

### Per-Venture Opt-Out

Individual ventures can opt out of the beacon via decision market through GovernanceExecutor.

```
Venture Token Holders → Decision Market → GovernanceExecutor → Venture.upgradeToAndCall()
```

---

## Configuration Parameters

These parameters are adjustable without contract upgrades:

```solidity
hub.setApprovedMoneyToken(address token, bool approved);
hub.setWinningMarketThresholdBps(uint256 bps);
hub.setMarketCreationSigner(address signer);
```

---

## Upgrade Path Selection

| Scenario                              | Path                                               |
| ------------------------------------- | -------------------------------------------------- |
| Protocol bug fix (Hub, MarketCore) | UUPS upgrade via owner (recommended: multisig)     |
| Protocol feature addition             | UUPS upgrade via owner (recommended: multisig)     |
| Venture implementation change            | Beacon upgrade (all) or decision market (per-venture) |
| Storage layout modification           | UUPS upgrade (preserve slot ordering)              |
| Stateless contract change             | Registry swap                                      |
| Per-market state contract             | Registry swap (between market cycles)              |
| Token contract                        | Non-upgradeable; deploy new                        |

---

## Storage Layout

All upgradeable contracts reserve storage slots for future variables:

```solidity
uint256[50] private __gap;
```

Storage rules:
- Never reorder, retype, or remove existing storage variables
- Upgrading a deployed layout: append new variables before `__gap` and shrink `__gap` by the
  slots they use. An append that fits in unused bytes of the final pre-gap slot consumes no
  gap slots. Before a contract's first deployment the layout is free to change and the
  gap stays at the full `uint256[50]`
- Never change the members of a struct that lives in storage (add a new mapping instead)
- Beacon-upgraded `Venture` storage must be safe at zero: a beacon upgrade cannot run an initializer

Venture layout history: `allowanceSources` at slot 12 and `allowanceSourceCount` at slot 13
(budget sources and the per-underlying count), gap shrunk to `uint256[48]` at slot 14. No
reinitializer; every new path is gated on an empty registry. `.storage-layouts/Venture.json` is
the authority if this line and the contract ever disagree.

Two checks enforce this, both in `services/internal-cli/scripts/storage-layout.ts`:

| Check | Command | Gate |
| ----- | ------- | ---- |
| Drift: current build equals the committed `.storage-layouts/*.json` | `bun services/internal-cli/scripts/storage-layout.ts check` | Every PR (Foundry CI). Intentional changes: `just forge-update-storage-layouts`, review the diff |
| Compatibility: current build can be upgraded onto the layout at a git ref | `just forge-storage-compat <ref>` | Foundry CI against the latest release tag (with `--allow-renames`, printed as notes); the runbook against the tag live on the target chain |

Compatibility fails on any removed, moved, retyped, or renamed variable (`--allow-renames` accepts
intentional renames), any struct/mapping internals change, a new variable outside the old gap
and the unused bytes of the final pre-gap slot, or a
gap that does not shrink by exactly the appended slots (`--allow-gap-growth` downgrades this to a
note for layouts still awaiting their first deployment). Baselines older than this tooling only have the legacy
table snapshot, so struct internals are reported as unverified for them.

---

## Reinitializers

New storage that needs a non-zero value is seeded by a `reinitializer(n)` delivered atomically
through `upgradeToAndCall(impl, abi.encodeCall(initializeVn, (...)))`. `n` is the next
`Initializable` version: 2 for the hub and market core, 3 for ventures (`initialize` is already
version 2).

A reinitializer is gated by an authority that can actually reach it: `onlyOwner` on the hub,
`HUB.owner()` on the market core, and on ventures the governance executor or the hub owner. The
delegatecall inside `upgradeToAndCall` preserves `msg.sender`, so the atomic path passes the gate
(for ventures that is the executor, via the `UPGRADE_IMPLEMENTATION` action's `data`), and an
upgrade that lands without its payload leaves nothing anyone else can call. OZ's
`_disableInitializers` in the constructor keeps the implementation contract itself uninitializable.

Beacon upgrades carry no calldata, so after `beacon.upgradeTo` the hub owner sweeps each venture
with a separate reinitializer call; the implementation must behave correctly before it runs.

Reference shapes and tests: `test/mocks/UpgradedImplementations.sol`, `test/proxy/UpgradeabilityTest.t.sol`
(`Reinitializers` section), `test/governance/HubTimelock.t.sol`.

---

## Runbook

Every upgrade is a cross-stack release with an on-chain step in the middle. The on-chain step is
the same for all three targets (`hub`, `market-core`, `venture-beacon`): `script/UpgradeBase.s.sol`
resolves the target from the hub registry of the `contracts.json` entry named by `UMIA_ENV` and
`UMIA_CHAIN`, and the three `Upgrade*.s.sol` entrypoints only choose which implementation to deploy.

1. deploy the new implementation (the only transaction the deployer key sends by default)
2. check it is a locked UUPS implementation (`proxiableUUID`, initializers disabled)
3. rehearse the upgrade in the fork as the live owner and diff protocol state reads before/after
   (`script/ProtocolState.sol`: hub registry, market core, and the newest ventures and markets)
4. if `EXECUTE_UPGRADE=true` and the deployer is the owner: send the upgrade;
   otherwise print the calldata the owner must send (Safe transaction builder, or the
   `schedule`/`execute` pair plus operation id when the owner is a `TimelockController`)

### Before

```bash
# 1. layout is upgrade-safe against the tag that is live on the target chain
just forge-storage-compat <live tag>

# 2. the scripts run end to end on a fork of the live deployment, through execution
#    (test/proxy/UpgradeRehearsal.t.sol takes over the proxies with a throwaway key)
just forge-upgrade-rehearsal <env> <chain>             # e.g. testnet base-sepolia

# 3. contracts.json still matches chain (catches a stale record before you overwrite it)
just contracts-check-live <env> <chain>
```

Offchain goes first: ship ABI (`just abi`), indexer handlers, and API/hub code that tolerate both
the old and the new implementation. New events on the indexer mean a blue/green resync, so the
green stack should be syncing before the upgrade executes. Gate offchain behavior on chain truth
(the implementation slot), not on deploy order.

### Upgrade

```bash
export DEPLOYER_PRIVATE_KEY=...            # deploys the implementation; need not be the owner
export UPGRADE_INIT_DATA=0x...             # optional reinitializer calldata (proxies only)

# dry run: deploys + rehearses in a fork, prints the handoff
just forge-upgrade hub <env> <chain> --rpc-url $RPC_URL

# real run: deploys + verifies the implementation (and, for market-core, its libraries)
just forge-upgrade hub <env> <chain> --rpc-url $RPC_URL --broadcast --verify --etherscan-api-key $KEY
```

Then the owner acts on the printed calldata. With an EOA owner that is the deployer,
`EXECUTE_UPGRADE=true` sends it in the same run. With a Safe, paste the calldata into the
transaction builder. With a timelock, the Safe schedules, anyone executes after `minDelay`.

### After

```bash
just contracts-check-live <env> <chain> --write   # records hubImpl / marketCoreImpl / ventureImpl / libraries
```

Write mode treats refreshed bookkeeping differences as informational; registry mismatches and
owner expectation failures still fail the command. Older hubs without `vestingAdmin` report
that getter as not present; RPC failures still fail the check.

Commit `contracts.json`, redeploy the services that bake it into their images (api, keeper, cron,
indexer) and the hub, and tag the release. The implementation addresses are bookkeeping only;
nothing reads them at runtime.

### Rehearsal on testnet

Run the full cycle on Base Sepolia before any mainnet upgrade, using the real owner path (Safe,
not the deployer EOA), so the handoff is exercised end to end. Devnet cannot stand in: it redeploys
from scratch on every reset and never upgrades anything.
