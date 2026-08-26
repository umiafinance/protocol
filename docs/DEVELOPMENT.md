# Smart Contracts Development Guide

This guide is for contributors working inside `smart-contracts/`.

## 1) Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git
- Access to required submodules under `smart-contracts/lib/`

Optional for local infra scripts:
- Anvil

## 2) Setup

From repository root:

```bash
cd smart-contracts
forge --version
```

If submodules are not initialized yet:

```bash
git submodule update --init --recursive
```

## 3) Build and test

```bash
cd smart-contracts
forge build
forge test
```

Useful targeted runs:

```bash
forge test --match-path test/markets/*
forge test --match-path test/governance/*
forge test --match-path test/launchpad/*
forge test --match-path test/periphery/*
```

## 4) Repository layout

- `src/core/` - hub, market manager, treasury, router, governance executor
- `src/periphery/` - TWAP oracle + auction validation routing/hooks
- `src/launchpad/` - LBP strategy and factory
- `src/tokens/` - venture token
- `src/libraries/` - CPMM math, governance action VM/types, helpers
- `script/` - deployment scripts
- `test/` - Foundry test suites
- `docs/` - protocol and contract docs

## 5) Local deployment scripts

For a full new-chain deployment checklist, see `docs/NEW_CHAIN_DEPLOYMENT.md`.

### Deploy protocol contracts (devnet style)

```bash
cd smart-contracts
forge script script/Deploy.s.sol:Deploy \
  --rpc-url <RPC_URL> \
  --broadcast
```

Expected environment variables used by script include:
- `DEPLOYER_PRIVATE_KEY`
- Optional overrides like `POOL_MANAGER`, `MARKET_CREATION_SIGNER_KEY`, `USDC_ADDRESS`

### Deploy local Uniswap v4 infra (for fresh local chains)

```bash
cd smart-contracts
forge script script/DeployV4Infra.s.sol:DeployV4Infra \
  --rpc-url http://localhost:8545 \
  --broadcast
```

## 6) Developing governance execution payloads

Winning proposal execution payload is decoded as:

- `GovernanceTypes.ExecutionPlanV1`
- containing `GovernanceTypes.ActionV1[]`

Current action semantics live in:
- `src/libraries/GovernanceTypes.sol`
- `src/libraries/GovernancePayloadValidator.sol`
- `src/libraries/GovernanceActions.sol`

When adding an action:
1. Extend `ActionType` / payload structs in `GovernanceTypes`.
2. Add validation in `GovernanceActions.validateActionV1` and execution in `GovernanceActions.executeActionV1`.
3. Add test coverage in `test/governance/*`.
4. Update docs in `docs/GOVERNANCE_TREASURY_LAYER.md` and `docs/contracts/`.

## 7) Market development checklist

For changes touching `UmiaMarketCore`:

- Keep split/merge solvency invariant intact.
- Validate proposal lifecycle (`PENDING -> OPEN -> ENDED`).
- Keep swap-permit replay protection intact (EIP-712 signer recovery + `swapNonces`).
- Update TWAP interactions (oracle update + snapshot calls) when changing swap paths.
- Add tests for settlement and claims edge-cases.

## 8) Documentation workflow

If a contract interface changes, update:

1. `docs/contracts/<Contract>.md`
2. `docs/ARCHITECTURE.md` (if interaction flow changed)
3. `smart-contracts/README.md` (if new docs added)

Keep docs aligned with code in `src/` and tests in `test/`.
