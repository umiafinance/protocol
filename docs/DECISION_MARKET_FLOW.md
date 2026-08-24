# Decision Market Flow

## Overview

Umia decision markets allow communities to make decisions through a futarchy mechanism. Market participants trade conditional tokens representing different proposals, and the proposal with the highest price (relative to a threshold) becomes the winning decision.

## Architecture Context

### Ventures

A venture is an entity that:

- Has its own token (e.g., "AliceVenture" token)
- Maintains a spot market on Uniswap V4 for its token
- The venture treasury holds the seed liquidity position (LP token) for the main DEX pair: **venture Token / Money Token** (e.g., AliceVenture/USDC)
- This spot market determines the real-time price of the venture token

### Conditional Markets

Decision markets create **conditional markets** for each proposal:

- Each proposal has its own CPMM (Constant Product Market Maker) using Uniswap V2 logic
- Uses virtual tokens (ERC6909) instead of separate ERC20 contracts for gas efficiency
- Virtual tokens represent conditional claims: "If this proposal wins, I get X tokens"
- Prices in conditional markets reflect market sentiment about each proposal's impact on the venture token value

### Two Market Types

1. **Spot Market (Uniswap V4)**: The real venture token trades against money (USDC) - this is the actual price discovery mechanism
2. **Conditional Markets (CPMM)**: Virtual tokens trade within each proposal's pool - these are prediction markets that determine which proposal wins

## Token Flow Model: Split/Merge

The system uses a **split/merge model** inspired by markets like Gnosis and metaDAO:

### Split Operation

When a user **splits** real tokens:

1. User deposits real tokens (venture and/or Money) into the contract
2. User receives virtual tokens **for ALL proposals** at 1:1 ratio
3. Real tokens are tracked in `realVentureBalance` and `realMoneyBalance`

```
User deposits 100 USDC
→ User receives:
  - 100 virtualMoney in Proposal 1 (no-op)
  - 100 virtualMoney in Proposal 2
  - 100 virtualMoney in Proposal 3
  - ... (for all proposals)
```

### Merge Operation

When a user **merges** virtual tokens:

1. User must have equal amounts of virtual tokens **in ALL proposals**
2. User burns virtual tokens from all proposals
3. User receives real tokens back at 1:1 ratio

```
User merges 50 virtualMoney
→ Burns 50 virtualMoney from Proposal 1
→ Burns 50 virtualMoney from Proposal 2
→ Burns 50 virtualMoney from Proposal 3
→ User receives 50 USDC
```

### Why Split/Merge?

This model ensures **solvency** at all times:

- The contract only needs to pay out the winning proposal's virtual tokens
- Since users must split equally across all proposals, the real token backing is always sufficient
- **Invariant**: `realTokenBalance >= max(userVirtualSupply per proposal)`

## End-to-End Flow

### Stage 1: Market Creation (Before Opening)

**Actor**: Market creator/staker (or Hub owner submitting with creator signature)

**Actions**:

1. Alice creates a venture with an initial spot market on Uniswap V4
2. Alice creates a decision market with multiple proposals
3. The system removes 50% of the venture's seed liquidity from the spot AMM
4. The removed tokens initialize CPMM pools for each proposal (including a "no-op" proposal)

**Example**:

- Alice creates "AliceVenture" with 1,000,000 tokens and $500 USDC seed liquidity
- Alice creates market: "Should we cut yearly emissions?"
  - Proposal 1: "No-op" (default, do nothing)
  - Proposal 2: "Cut emissions by 10%"
  - Proposal 3: "Cut emissions by 15%"
- System removes 50% of seed liquidity from the spot AMM
- Each proposal gets a CPMM initialized with these amounts as virtual tokens
- The contract holds these virtual tokens (minted to `address(this)`) as initial CPMM reserves
- `liquidityRemovalInfo` tracks the removed amounts for later accounting

**State**:

- Market status: `PENDING`
- Trading not yet open
- CPMM pools initialized with equal reserves for all proposals
- `proposalToMarket` mapping set for each proposal

### Stage 2: Market Opening & Splitting

**Actor**: Traders (e.g., Bob)

**Actions**:

1. Market opens at `tradingStart` (at/before now → immediate; otherwise up to `TRADING_MAX_START_DELAY` = 7 days out)
2. Traders call `split()` to deposit real tokens and receive virtual tokens for ALL proposals
3. Traders can now trade in the conditional markets

**Example**:

- Market can open immediately or up to 7 days after creation; trading runs for a per-market duration (1h–96h, default 3 days)
- Bob calls `split(marketId, 0, 1000e6)` to deposit 1,000 USDC
- Bob receives virtual tokens for all proposals:
  - 1,000 virtualMoney in Proposal 1 (no-op)
  - 1,000 virtualMoney in Proposal 2
  - 1,000 virtualMoney in Proposal 3

**State**:

- Market status: `OPEN`
- `realMoneyBalance[marketId]` increased by 1,000 USDC
- `userVirtualMoneySupply[proposalId]` increased for each proposal
- Traders have virtual tokens for all proposals

### Stage 3: Trading Period

**Actor**: Traders

**Actions**:

1. Traders swap virtual tokens within proposal CPMMs using `swapExactIn()` or `swapExactOut()`
2. Swaps transfer tokens between user and CPMM reserves (no minting/burning)
3. `userVirtualSupply` tracking updated on each swap
4. Higher prices indicate market confidence in that proposal
5. Trading continues for 3 days until `tradingEnd`

**Key Mechanism**: When a user swaps:

- Input tokens transfer FROM user TO contract (CPMM reserves)
- Output tokens transfer FROM contract (CPMM reserves) TO user
- Total supply remains constant - tokens just move between parties
- `userVirtualSupply` adjusts to track how much users hold vs CPMM reserves

**Example**:

- Bob believes Proposal 2 will win
- Bob swaps 100 virtualMoney for ~95 virtualVenture in Proposal 2
  - `userVirtualMoneySupply[proposal2]` decreases by 100
  - `userVirtualVentureSupply[proposal2]` increases by 95
  - CPMM reserves adjust accordingly
- After trading:
  - Proposal 1 (no-op): Price = 0.5 (unchanged)
  - Proposal 2: Price = 0.6 (increased due to buying pressure)
  - Proposal 3: Price = 0.55

**Optional**: Traders can call `merge()` to exit positions early by burning equal amounts from all proposals.

**State**:

- Market status: `OPEN`
- CPMM reserves change based on trades
- `userVirtualSupply` tracks user holdings per proposal
- Prices reflect market sentiment

### Stage 4: Market Resolution

**Actor**: Anyone (typically a bot or keeper)

**Actions**:

1. After `tradingEnd`, anyone can call `settleMarket()`
2. System calculates final prices for all proposals
3. System finds the proposal with the highest price
4. System compares highest price vs no-op price
5. If price delta >= `winningMarketThresholdBps`, that proposal wins; otherwise no-op wins
6. System calculates how much users need for claims: `userVirtualSupply[winningProposal]`
7. System calculates excess tokens that can go back to LP
8. System re-adds excess liquidity to the spot AMM
9. Winning proposal stored in `_winningProposalByMarketId`

**Settlement Accounting**:

```
totalRealTokens = realBalance[marketId] + lpRemovalInfo
userClaims = userVirtualSupply[winningProposalId]
excessForLP = totalRealTokens - userClaims - buffer
```

The excess (after reserving for user claims) goes back to the Uniswap V4 LP position.

**Example**:

- Trading ends
- Final prices: Proposal 3 has highest price at 0.7
- Price delta vs no-op: 40% (exceeds 2% threshold)
- Proposal 3 wins
- System reserves tokens for user claims, re-adds excess to LP

**State**:

- Market status: `ENDED` (implicit, based on timestamp)
- Winning proposal stored
- Excess liquidity restored to spot AMM

### Stage 5: Settlement Claims

**Actor**: Traders

**Actions**:

1. Traders call `claimSettlement(marketId)`
2. System checks `hasClaimed[marketId][user]` to prevent double claims
3. System gets trader's balances in the **winning proposal only**
4. System burns ALL virtual tokens in winning proposal
5. System transfers real tokens 1:1 (guaranteed solvent by invariant)
6. System marks user as claimed

**Example Scenarios**:

**Scenario A: Bob traded in losing proposal**

- Bob's balances in Proposal 3 (winner):
  - 0 virtualVenture
  - 1,000 virtualMoney (never traded in winning proposal)
- Bob claims: Receives 1,000 USDC
- Bob's trades in Proposal 2 (loser) don't matter

**Scenario B: Charlie traded in winning proposal**

- Charlie's balances in Proposal 3 (winner):
  - 300 virtualVenture (bought by swapping virtualMoney)
  - 700 virtualMoney (original 1000 - 300 swapped)
- Charlie claims: Receives 300 venture tokens + 700 USDC
- Charlie's bet on Proposal 3 paid off

**State**:

- `hasClaimed[marketId][user]` = true
- Virtual tokens burned
- Real tokens distributed

## Invariant & Solvency Guarantee

The system maintains a critical invariant after every split, merge, and swap:

```solidity
realTokenBalance + lpRemovalInfo >= max(userVirtualSupply per proposal)
```

This guarantees that:

1. The contract always has enough real tokens to pay ALL claims
2. Only ONE proposal wins, so only that proposal's virtual tokens are claimed
3. Split adds to all proposals equally; merge removes from all equally
4. Swaps only redistribute tokens, don't create new ones

## Key Design Principles

1. **Split/Merge Model**: Users split real tokens into virtual tokens across all proposals, can merge back at any time
2. **1:1 Redemption**: Virtual tokens in the winning proposal are redeemed 1:1 for real tokens
3. **Only Winning Proposal Matters**: Balances in losing proposals are irrelevant for claims
4. **Solvency Invariant**: Real token backing always covers worst-case claims
5. **No-Op Default**: If no proposal meets the threshold, the no-op proposal wins
6. **Single Claim**: `hasClaimed` mapping prevents double-claiming
7. **Constant Supply**: Swaps directly manipulate balances to move tokens between users and CPMM reserves (no supply change)

## Price Calculation

Prices are calculated as: `price = reserve1 / reserve0` (virtualMoney per virtualVenture)

- Higher price = market thinks proposal will increase venture value
- Price in Q96 format: `priceX96 = (reserve1 * 2^96) / reserve0`
- Price delta: `deltaBps = ((winningPrice - noOpPrice) * 10,000) / noOpPrice`

## CPMM Mechanics

- Uses constant product formula: `x * y = k`
- 0.3% fee on swaps (stays in reserves)
- Slippage protection via `amountOutMin` / `amountInMax`
- Price impact protection via `maxPriceImpactBps`
- Users can add liquidity to CPMMs (reduces their userVirtualSupply)

## Gas Efficiency

- Uses ERC6909 instead of separate ERC20 contracts for virtual tokens
- Custom CPMM instead of full Uniswap V4 pools for conditional markets
- Single contract manages all proposals and markets
