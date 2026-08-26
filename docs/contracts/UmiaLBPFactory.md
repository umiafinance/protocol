# UmiaLBPFactory

Source: `src/launchpad/UmiaLBPFactory.sol`

## Purpose

Factory for deploying `UmiaLBP` strategy contracts (CREATE2 via inherited `StrategyFactory`).

## Key state

- `poolManager` (immutable)

## Important behavior

- `_validateParamsAndReturnDeployedBytecode(...)`:
  - validates `totalSupply <= uint128.max`
  - decodes expected config tuple
  - returns deployment bytecode for `UmiaLBP` with constructor args.

## Notes

- Validates non-zero manager addresses in constructor.
