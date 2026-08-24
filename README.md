# Umia Protocol smart contracts

Solidity contracts for Umia: token launches (LBP auctions), Uniswap v4 spot markets, futarchic decision markets, and onchain treasury governance.

## Quick start

```bash
forge build
forge test
```

Verbose output:

```bash
forge test -vvv
```

Run focused suites:

```bash
forge test --match-path test/governance/*
forge test --match-path test/markets/*
forge test --match-path test/launchpad/*
forge test --match-path test/periphery/*
forge test --match-path test/reclaim/*
forge test --match-path test/liquidation/*
```

Format before committing:

```bash
forge fmt
```

## Source layout

| Path               | Role                                                                         |
| ------------------ | ---------------------------------------------------------------------------- |
| `src/core/`        | Hub registry, market manager, market stake, swap router, governance executor |
| `src/launchpad/`   | LBP factory and auction strategy                                             |
| `src/periphery/`   | TWAP oracle, validation hooks, Uniswap v4 hook, TWAP unlock vault            |
| `src/tokens/`      | Venture ERC-20 token                                                         |
| `src/libraries/`   | CPMM math, governance types/actions, Uniswap helpers                         |
| `src/liquidation/` | Treasury liquidation                                                         |
| `src/reclaim/`     | Social recovery / claims utilities                                           |
| `script/`          | Deployment scripts                                                           |
| `test/`            | Foundry test suites                                                          |
| `docs/`            | Protocol and contract reference docs                                         |
| `certora/`         | Formal verification specs                                                    |

## Protocol overview

1. **Launch** — A venture is created via `UmiaHub`, runs a tailored auction through `UmiaLBP`, and migrates liquidity to a Uniswap v4 spot pool.
2. **Trade** — The spot pool provides price discovery; `UmiaHook` routes fees and oracle observations.
3. **Govern** — `UmiaMarketCore` runs decision markets: users split venture tokens into virtual token positions per proposal (a minimal balanceOf ledger, not full ERC-6909), trade on CPMM pools, and settle by TWAP. The winning proposal executes against the venture treasury through `GovernanceExecutor`.

See [Architecture](./docs/ARCHITECTURE.md) for contract-level detail and data flows.

## Documentation

### Protocol

- [Architecture](./docs/ARCHITECTURE.md)
- [Development Guide](./docs/DEVELOPMENT.md)
- [Decision Market Flow](./docs/DECISION_MARKET_FLOW.md)
- [Governance & Treasury Layer](./docs/GOVERNANCE_TREASURY_LAYER.md)
- [Spot Oracle](./docs/SPOT_ORACLE.md)
- [Contract Upgrades](./docs/UPGRADES.md)
- [New Chain Deployment](./docs/NEW_CHAIN_DEPLOYMENT.md)
- [Security Notes](./docs/SECURITY.md)
- [Formal Verification](./certora/README.md)

### Contract references

Full index: [Contract Reference](./docs/contracts/README.md)

**Core**

- [UmiaHub](./docs/contracts/UmiaHub.md)
- [UmiaMarketCore](./docs/contracts/UmiaMarketCore.md)
- [GovernanceExecutor](./docs/contracts/GovernanceExecutor.md)

**Periphery**

- [ConditionalMarketOracle](./docs/contracts/ConditionalMarketOracle.md)
- [UmiaValidationHook](./docs/contracts/UmiaValidationHook.md)
- [UmiaTwapMilestoneCondition](./docs/contracts/UmiaTwapMilestoneCondition.md)

**Launchpad**

- [UmiaLBP](./docs/contracts/UmiaLBP.md)
- [UmiaLBPFactory](./docs/contracts/UmiaLBPFactory.md)

**Governance libraries**

- [GovernanceTypes](./docs/contracts/GovernanceTypes.md)
- [GovernancePayloadValidator + GovernanceActions](./docs/contracts/GovernanceLibraries.md)

## Deployment scripts

| Script                            | Purpose                                              |
| --------------------------------- | ---------------------------------------------------- |
| `script/Deploy.s.sol`             | Deploy Umia contracts and wire hub registry pointers |
| `script/DeployV4Infra.s.sol`      | Deploy local Uniswap v4 infra for dev chains         |
| `script/DeployTestnetToken.s.sol` | Deploy a test ERC-20 for local/testnet use           |
| `script/MineUmiaHookSalt.s.sol`   | Mine CREATE2 salt for `UmiaHook` deployment          |

For production deployment steps, follow [New Chain Deployment](./docs/NEW_CHAIN_DEPLOYMENT.md).

## Licensing

Contracts are licensed per file, with the SPDX identifier on line 1 as the source of
truth. Full texts are in [`licenses/`](./licenses/).

| Surface | License | What |
| --- | --- | --- |
| Integration | `MIT` | `src/interfaces/**`, the shared type libraries, and generic math. Build against Umia freely. |
| Mechanism | `BUSL-1.1` | Markets, settlement, governance, launchpad, hook, and vaults. Converts to MIT on the Change Date. |
| Vendored | `MIT` | `src/reclaim/**` (Reclaim Protocol). |

BUSL-1.1 permits all non-production use — development, testing, testnet deploys,
security research and audits — and restricts production deployment of a competing
decision-market or venture-funding protocol until the Change Date (2030-08-11), when it
converts to MIT. The Licensor may grant further exemptions in writing.

`bash check-licenses.sh` enforces the map in CI. MetaVesT is AGPL-3.0, so `src/` declares
minimal local interfaces instead of importing it; the same check guards that boundary.
