# GovernanceExecutor

Source: `src/core/GovernanceExecutor.sol`

## Purpose

Executes typed governance plans for a venture after market settlement.

- Entry point called by `UmiaMarketCore.executeWinningProposal`.
- Decodes and validates `ExecutionPlanV1` via `GovernancePayloadValidator`, dispatches actions via `GovernanceActions`.

## Preconditions enforced

- Caller must be `HUB.umiaMarketCore()`.
- Executor instance must match `HUB.governanceExecutor(venture)`.
- Payload must be non-empty.
- venture liquidation must not already be active.
- Plan version must be `1`.

## Execution behavior

- Validates plan via `GovernancePayloadValidator.decodeAndValidatePayload`.
- Iterates actions in order, executing each via `GovernanceActions.executeActionV1`.
- `LIQUIDATE_TREASURY` must be the final action (enforced in `GovernancePayloadValidator.validatePlanV1`).

## Events

- `GovernanceActionExecuted(...)` per action
- `GovernancePlanExecuted(...)` with `planHash = keccak256(executionPayload)`
