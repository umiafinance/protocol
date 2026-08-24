# GovernancePayloadValidator + GovernanceActions

Source: `src/libraries/GovernancePayloadValidator.sol`, `src/libraries/GovernanceActions.sol`

## Purpose

Stateless libraries for governance payload decoding, validation, and action dispatch:

- **GovernancePayloadValidator**: Decodes plan version, validates `ExecutionPlanV1` structure, and enforces `LIQUIDATE_TREASURY` as the final action.
- **GovernanceActions**: Validates individual action payloads and executes them against a `Venture`.

## Important functions

### GovernancePayloadValidator

- `decodePlanVersion(bytes calldata executionPayload)` - extracts `uint16 version`
- `validatePlanV1(ExecutionPlanV1 memory plan)` - validates plan version and all actions
- `decodeAndValidatePayload(bytes calldata executionPayload)` - combined decode + validate

### GovernanceActions

- `validateActionV1(ActionV1 memory action)` - validates a single action's payload
- `executeActionV1(Venture venture, ActionV1 memory action)` - validates and executes a single action

## Behavior notes

- Requires `action.actionVersion == 1` for all current actions.
- `UPDATE_PARAMS` reverts with `UnsupportedAction`.
- `LIQUIDATE_TREASURY` delegates to `venture.setLiquidator(...)` and initializes the external `ILiquidator`; final-action enforcement is done in `GovernancePayloadValidator.validatePlanV1`.
- `CALL` blocks self-calls (`target == address(venture)`).
- `UPGRADE_IMPLEMENTATION` emits `ImplementationOptOut` for indexing.
