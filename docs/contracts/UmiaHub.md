# UmiaHub

Source: `src/core/UmiaHub.sol`

## Purpose

Central registry and factory for ventures.

- Deploys `Venture` + `VentureToken` + launch strategy (`UmiaLBP`) during `createVenture`.
- Stores protocol pointer addresses used by other contracts.
- Stores venture metadata (`VentureInfo`) and approved money tokens.

## Key state

- `ventureCount`, `_ventureById`
- `approvedMoneyTokens`
- configurable pointers:
  - `umiaMarketCore`
  - `defaultGovernanceExecutor`
  - `governanceExecutorByVenture`
  - `conditionalMarketOracle`
  - `marketCreationSigner`
  - `lbpStrategyFactory`
- `winningMarketThresholdBps` (default 200)

## Important functions

- `createVenture(CreateVentureParams)`
- `setUmiaMarketCore`, `setDefaultGovernanceExecutor`, `setVentureGovernanceExecutor`
- `setConditionalMarketOracle`, `setMarketCreationSigner`
- `setApprovedMoneyToken`, `setLbpStrategyFactory`
- `setVentureMinMarketStake`, `approveVenturePositionOperator`
- `governanceExecutor(venture)` (venture override or default)

## Access control

- Most registry setters are `onlyOwner`.
- `setVentureGovernanceExecutor` and `setVentureMinMarketStake` allow either hub owner or venture owner.

## Notes

- venture creation requires:
  - approved money token,
  - non-zero market manager,
  - non-zero LBP strategy factory,
  - initial supply bounds.
