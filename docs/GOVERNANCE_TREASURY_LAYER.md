# Governance & Treasury Execution Layer (v1)

## Overview

This document specifies the governance execution and treasury control layer for Umia ventures. It defines a structured action language for proposal execution, a canonical payload encoding, and the execution flow from decision market settlement to onchain treasury changes. The goal is to replace opaque raw calldata with auditable, typed actions while preserving an escape hatch for advanced use cases.

The spec targets:

- Market settlement → execution of a winning proposal
- A governance VM that executes deterministic, enumerable actions
- Treasury operations on any asset type (native, ERC20, ERC721, ERC1155)
- A document registry for legal/off-chain updates
- A liquidation mechanism with pro rata distribution

## Goals

- Deterministic, typed execution payloads
- Easy to audit and explain proposal outcomes
- Frontend-friendly encoding and validation
- Atomic execution across multiple actions
- Forward-compatible versioning
- Escape hatch for opaque calls

## Non-goals (v1)

- Complex param updates (reserved for future)
- Permissionless upgrades of executor logic
- Custom allowance cadences beyond calendar-month accounting
- NFT pro-rata liquidation (must be converted to fungible assets before liquidation)

## Architecture

### Actors & Contracts

- **UmiaMarketCore**: Settles decision markets and triggers execution of the winning proposal.
- **Venture**: Treasury contract holding assets.
- **GovernanceExecutor**: Per-venture executor contract that decodes and runs execution payloads.
- **GovernancePayloadValidator (library)**: Decodes and validates execution plan structure.
- **GovernanceActions (library)**: Validates and dispatches individual action semantics.

### Execution Flow

1. Market is created with proposals that include `executionPayload` bytes.
2. Market ends and `UmiaMarketCore` determines the winning proposal.
3. `UmiaMarketCore.executeWinningProposal(marketId)` calls:
   - `GovernanceExecutor.executeProposal(venture, marketId, proposalId, executionPayload)`
4. `GovernanceExecutor` decodes the plan via `GovernancePayloadValidator` and executes actions via `GovernanceActions`, atomically.
5. On success, the market is marked as executed and events are emitted.

## Versioning & Payload Encoding

### Canonical Payload

`executionPayload` MUST be ABI-encoded as:

```solidity
struct ExecutionPlanV1 {
    uint16 version; // must be 1
    ActionV1[] actions;
}

struct ActionV1 {
    ActionType actionType;
    uint16 actionVersion; // must be 1
    bytes data; // ABI-encoded action-specific payload
}
```

`executionPayload = abi.encode(ExecutionPlanV1({version: 1, actions}))`

Versioning rules:

- `ExecutionPlanV1.version` identifies the plan format.
- `ActionV1.actionVersion` identifies the action encoding for that action type.
- The executor MUST reject any version != 1 in v1.

## Updating Actions (Guide)

When you want to change a single action’s payload or behavior, prefer incrementing that **action’s version** rather than the whole plan format.

### When to bump the plan version

- You change the **container format** (`ExecutionPlanV1`) or how plans are decoded.
- You need to change how actions are ordered, validated, or executed at the plan level.

### When to bump an action version

- You change the **payload struct** for a specific action.
- You change the **semantics** of a specific action type but can keep the plan format unchanged.

### Recommended upgrade flow

1. **Add a new action version** in the Governance VM implementation.
   - Example: support `UPDATE_MONTHLY_ALLOWANCE` action version `2` while still supporting version `1`.
2. **Deploy or upgrade the GovernanceExecutor** to include the new action version decoding.
3. **Update the Hub executor pointer** (default or per‑venture) to the new executor.
4. **Frontends encode the new action version** for new proposals; old proposals remain valid.

### Example pattern (pseudocode)

```solidity
if (actionType == UPDATE_MONTHLY_ALLOWANCE) {
    if (actionVersion == 1) {
        // decode v1 struct
    } else if (actionVersion == 2) {
        // decode v2 struct
    } else {
        revert InvalidActionVersion();
    }
}
```

This allows incremental action upgrades without forcing a new plan version or re‑encoding all existing actions.

If `version != 1`, execution MUST revert.

### Action Types

```solidity
enum ActionType {
    MINT_TOKENS,
    BURN_TOKENS,
    TRANSFER_TREASURY_ASSETS,
    UPDATE_MONTHLY_ALLOWANCE,
    UPDATE_TEAM_MEMBER,
    UPDATE_PARAMS, // reserved in v1 (MUST revert)
    UPLOAD_DOCUMENT,
    LIQUIDATE_TREASURY,
    CALL,
    UPGRADE_IMPLEMENTATION,
    SET_ALLOWANCE
}
```

New action types MUST be appended at the end. Ordinals are part of the ABI of
every encoded `ExecutionPlanV1` — reordering or inserting values would silently
re-target previously-generated proposal payloads.

### Action Payloads

#### MINT_TOKENS

Mints venture token supply to a recipient.

```solidity
struct MintTokens {
    address to;
    uint256 amount;
}
```

Rules:

- Only the venture token may be minted.
- `amount > 0` required.

#### BURN_TOKENS

Burns venture tokens held by the treasury.

```solidity
struct BurnTokens {
    uint256 amount;
}
```

Rules:

- Burn occurs from the treasury balance (`Venture`).
- `amount > 0` required.

#### TRANSFER_TREASURY_ASSETS

Transfers assets held by the treasury to a recipient.

```solidity
enum AssetType { NATIVE, ERC20, ERC721, ERC1155 }

struct TransferTreasuryAssets {
    AssetType assetType;
    address token;   // ignored for NATIVE
    address to;
    uint256 amount;  // NATIVE/ERC20/ERC1155
    uint256 tokenId; // ERC721/ERC1155
    bytes data;      // ERC1155 receiver data
}
```

Rules:

- `to != address(0)` required.
- `amount > 0` for NATIVE/ERC20/ERC1155.
- `tokenId` required for ERC721/ERC1155.

#### UPDATE_MONTHLY_ALLOWANCE

Updates the monthly allowance amount for a token. Allowance withdrawals are available to team members.

```solidity
struct UpdateMonthlyAllowance {
    address token;   // ERC20 or address(0) for native
    uint256 amount;  // allowance per period
}
```

Rules:

- No rollover: each period starts fresh.
- Periods are calendar months (UTC) computed as `YYYYMM` via `CalendarLib.timestampToMonth(block.timestamp)`.
- On month change, `spent` resets to `0`.
- Withdrawal is permitted by any account that is a venture team member (registry updated via `UPDATE_TEAM_MEMBER`).
- If `amount == 0`, allowance is effectively disabled.

#### SET_ALLOWANCE

Sets an ERC20 allowance on the treasury for a specific spender address. Enables controlled programmatic access (e.g. a keeper or bot executing recurring TWAP buybacks via pull) without resorting to the raw `CALL` escape hatch.

```solidity
struct SetAllowance {
    address token;   // ERC20 only (address(0) not supported)
    address spender;
    uint256 amount;  // 0 to revoke the allowance
}
```

Rules:

- `token != address(0)` and `spender != address(0)` required.
- `amount` may be zero (revokes the allowance).
- Uses `forceApprove` internally for broad ERC20 compatibility.
- Distinct from `UPDATE_MONTHLY_ALLOWANCE` (the latter is calendar-month team pull allowances with spend tracking).
- **Standing allowances persist into liquidation and are not auto-revoked.** Before liquidating, a `LIQUIDATE_TREASURY` plan MUST first zero every live allowance with `SET_ALLOWANCE(token, spender, 0)` actions — see [LIQUIDATE_TREASURY](#liquidate_treasury). Enumerate live allowances from the indexed `AllowanceSet(token, spender, amount)` events.

#### UPDATE_TEAM_MEMBER

Updates a single team member address.

```solidity
struct UpdateTeamMember {
    address member;
    bool approved;
}
```

Rules:

- `member != address(0)` required.
- This action is the only way to update team membership after deployment.

#### UPDATE_PARAMS (reserved)

Reserved for future governance parameter updates. In v1:

- Any `UPDATE_PARAMS` action MUST revert.

#### UPLOAD_DOCUMENT

Stores a document record for off-chain legal or governance context.

```solidity
struct UploadDocument {
    string name;
    string uri; // IPFS CID or ipfs:// URI or content hash string
}
```

Rules:

- Documents are stored in an onchain enumerable mapping.
- Document IDs start at 1 and increment by 1 per upload.
- Empty `name` or `uri` MUST revert.

#### LIQUIDATE_TREASURY

Starts liquidation and enables pro rata redemption of treasury assets by token holders.

```solidity
struct LiquidationAsset {
    AssetType assetType;
    address token;
    uint256 tokenId; // ERC721/ERC1155 only
}

struct LiquidationPlan {
    address liquidator;
    LiquidationAsset[] assets;
}
```

Rules:

- Liquidation is a terminal state: once activated, only liquidation claims are allowed.
- The `liquidator` address points to an external `ILiquidator` contract that handles the actual distribution strategy (pro-rata, auction, etc.) while assets remain in the Venture treasury.
- On execution, `GovernanceActions` redeems the venture's spot-LP shares into the treasury, then calls `venture.setLiquidator(liquidator)` and `ILiquidator(liquidator).initialize(venture, assets, claimableSupply)`.
- Token holders call `ILiquidator.claim()` to burn all their venture tokens and receive pro-rata shares of each asset.
- Claims are proportional to burned venture tokens over the **claimable** supply, which excludes venture tokens held by the treasury itself (redeemed LP + any treasury balance) because those can never claim:
  - `payout = assetBalance * burnAmount / (totalSupply - treasuryVentureBalance)`
- **Do not list the venture token in `assets`.** It is the claim-burn token, not a distributable asset; `SimpleLiquidator` skips it if listed. Paying it back out pro-rata would let a claimant recycle the payout through fresh addresses and over-draw. List the money token (and any other real treasury assets) instead.

##### Mandatory: revoke standing allowances first

**Liquidation does NOT revoke standing ERC20 allowances.** `setLiquidator` only flips the terminal flag, and afterwards `setAllowance` and the whole executor path are blocked — so a stale approval can never be cleared once liquidation starts. Any spender still holding an allowance (granted via `SET_ALLOWANCE` **or** a raw `CALL` `approve`) can then `transferFrom` treasury assets directly on the token *after* the liquidator snapshots balances, draining assets that back claims and reverting later claimants.

The liquidation governance plan therefore MUST include a `SET_ALLOWANCE(token, spender, 0)` action for every live allowance, **ordered before** the `LIQUIDATE_TREASURY` action in the same plan. Actions execute in array order (`GovernanceExecutor` loops them sequentially), and `setAllowance` runs while still not liquidating, so the approvals are zeroed before `setLiquidator` runs. Enumerate live allowances from the indexed `AllowanceSet(token, spender, amount)` events (surfaced by the indexer); this is the single source of truth for what to revoke, and covers both `SET_ALLOWANCE`- and `CALL`-created approvals.

Example plan action order:

```
[ SET_ALLOWANCE(moneyToken, keeperA, 0),
  SET_ALLOWANCE(moneyToken, keeperB, 0),
  LIQUIDATE_TREASURY({ liquidator, assets: [moneyToken, ...] }) ]
```

#### CALL

Executes an opaque call from the treasury context.

```solidity
struct Call {
    address target;
    uint256 value;
    bytes data;
}
```

Rules:

- `target != address(0)` required.
- Execution MUST use `call` (not `delegatecall`).
- Reverts MUST bubble.
- No allowlists are enforced (by design).

#### UPGRADE_IMPLEMENTATION

Upgrades a venture to a custom implementation and optionally runs initialization calldata.

```solidity
struct UpgradeImplementation {
    address newImplementation;
    bytes data;
}
```

Rules:

- Uses `UUPSUpgradeable(address(venture)).upgradeToAndCall(newImplementation, data)`.
- Emits implementation opt-out events for indexing and governance audit trails.

## GovernanceExecutor Requirements

### Access Control

- Only the **current** `UmiaMarketCore` (from `UmiaHub`) MAY call `executeProposal`.
- Executor is configured per venture, set by the Hub or at venture initialization.

### Atomicity

- All actions execute in order, atomically.
- Any failure MUST revert the entire execution.

### Idempotency

- Each market should be executable at most once (tracked in `UmiaMarketCore`).
- The executor MAY emit a `planHash = keccak256(executionPayload)` for indexing.

### Events (recommended)

```solidity
event GovernancePlanExecuted(
    address indexed venture,
    uint256 indexed marketId,
    uint256 indexed proposalId,
    bytes32 planHash
);

event GovernanceActionExecuted(
    address indexed venture,
    uint256 indexed marketId,
    uint256 indexed proposalId,
    ActionType actionType
);

event DocumentUploaded(
    address indexed venture,
    uint256 indexed docId,
    string name,
    string uri
);

event MonthlyAllowanceUpdated(address indexed venture, address indexed token, uint256 amount);

event LiquidationStarted(address indexed venture, uint256 totalSupply, uint256 assetCount);
event LiquidationClaimed(address indexed venture, address indexed claimer, uint256 burnAmount);
```

## Venture Requirements

The executor must be able to operate on the treasury. Venture MUST provide restricted hooks for:

- `mint(address to, uint256 amount)`
- `burn(uint256 amount)` (from treasury balance)
- `withdraw(address token, address to, uint256 amount)` (native or ERC20)
- ERC721/1155 withdrawals:
  - `withdrawERC721(address token, address to, uint256 tokenId)`
  - `withdrawERC1155(address token, address to, uint256 tokenId, uint256 amount, bytes data)`
- `executeCall(address target, uint256 value, bytes data)` for `CALL`

Venture MUST allow calls from the GovernanceExecutor (in addition to Hub/MarketCore).

Team members MUST be specified at venture deployment time as part of `CreateVentureParams.teamMembers`.

## Monthly Allowance

State (per venture, per token):

- `monthlyAllowance[token].amount`
- `monthlyAllowance[token].spent`
- `monthlyAllowance[token].currentMonth` (encoded as `YYYYMM`)

Rules:

- Periods follow UTC calendar months from `CalendarLib.timestampToMonth(block.timestamp)`.
- When the computed month changes, `monthlyAllowance[token].spent` resets to `0`.
- Any team member can withdraw up to `monthlyAllowance[token].amount - monthlyAllowance[token].spent`.
- Withdrawal uses `TRANSFER_TREASURY_ASSETS` internally or a dedicated function.

## Document Registry

State:

```solidity
struct Document {
    string name;
    string uri;
    uint256 createdAt;
}

mapping(uint256 => Document) public documents;
uint256 public documentCount;
```

Rules:

- IDs start at 1.
- `documentCount` increments by 1 per upload.
- Documents are immutable after upload in v1.

## Liquidation Mechanics

1. On `LIQUIDATE_TREASURY`, the executor:
   - Calls `venture.setLiquidator(liquidator)` which sets `liquidationActive = true`
   - Calls `ILiquidator(liquidator).initialize(venture, assets, totalSupply)` which snapshots total supply and asset balances
2. Token holders call `ILiquidator.claim()`:
   - Burns all caller's venture tokens via the Venture
   - Transfers each asset pro rata based on burned amount vs total supply snapshot
3. After liquidation starts, all governance actions MUST revert (enforced by `whenNotLiquidating` modifier on Venture).

## Security Considerations

- `CALL` is deliberately unrestricted. This makes governance powerful but increases risk:
  - Malicious proposals can drain funds or interact with unsafe contracts.
  - Frontends should warn users when a proposal contains a `CALL` action.
- Executor MUST be non-reentrant.
- All external calls MUST be guarded by checks-effects-interactions.
- Use `SafeERC20` and ERC721/1155 safe transfer methods where appropriate.
- Liquidation should be single-shot and irreversible in v1.

## Implementation Checklist

- **GovernanceExecutor**
  - Decode `ExecutionPlanV1` via `GovernancePayloadValidator` and dispatch actions via `GovernanceActions`.
  - Enforce access control: only the current `UmiaMarketCore`.
  - Emit `GovernancePlanExecuted` and `GovernanceActionExecuted`.
- **GovernancePayloadValidator (library)**
  - Decode plan version, validate plan structure, enforce LIQUIDATE_TREASURY ordering.
- **GovernanceActions (library)**
  - Stateless action validation and dispatch.
  - Shared helpers for asset transfers and allowance updates.
- **Venture**
  - Add executor authorization (alongside Hub/MarketCore).
  - Add NFT withdrawal helpers:
    - `withdrawERC721(token, to, tokenId)`
    - `withdrawERC1155(token, to, tokenId, amount, data)`
  - Add `executeCall(target, value, data)` for `CALL`.
  - Add allowance state + period reset logic (team membership registry TBD).
  - Add document registry storage and events.
  - Add liquidation state, snapshot, and claim flow.
- **UmiaMarketCore**
  - Replace raw `venture.call(executionPayload)` with:
    - `GovernanceExecutor.executeProposal(venture, marketId, proposalId, executionPayload)`.
  - Optional: store `planHash` in `WinningProposalExecuted`.
- **UmiaHub**
  - Store and expose governance executor address per venture (or global default).
- **Indexer**
  - Index document uploads, allowance updates, liquidation events.
- **Frontend**
  - Encode `ExecutionPlanV1` from form inputs.
  - Display structured actions, and warn for `CALL`.
- **Tests**
  - Unit tests per action type + failure paths.
  - End-to-end test: market settle → execute → state changes.

## Example Payloads

### Mint 1,000 venture tokens to a recipient

```solidity
ActionV1[] memory actions = new ActionV1[](1);
actions[0] = ActionV1({
    actionType: ActionType.MINT_TOKENS,
    actionVersion: 1,
    data: abi.encode(MintTokens({to: recipient, amount: 1_000e18}))
});

bytes memory payload = abi.encode(ExecutionPlanV1({version: 1, actions: actions}));
```

### Transfer 50 USDC from treasury

```solidity
actions[0] = ActionV1({
    actionType: ActionType.TRANSFER_TREASURY_ASSETS,
    actionVersion: 1,
    data: abi.encode(
        TransferTreasuryAssets({
            assetType: AssetType.ERC20,
            token: usdc,
            to: recipient,
            amount: 50e6,
            tokenId: 0,
            data: ""
        })
    )
});
```

### Upload document

```solidity
actions[0] = ActionV1({
    actionType: ActionType.UPLOAD_DOCUMENT,
    actionVersion: 1,
    data: abi.encode(UploadDocument({
        name: "Operating Agreement v2",
        uri: "ipfs://bafybeigdyr..."
    }))
});
```
