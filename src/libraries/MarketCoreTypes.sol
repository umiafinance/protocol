// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CPMM} from "./CPMM.sol";

// Storage structs for market, proposal, pool, and settlement state, shared by UmiaMarketCore and
// its market-creation and settlement libraries. Fields are ordered to pack efficiently into slots.

/// @notice Per-market configuration and lifecycle state.
/// @dev Timing, thresholds, and flags pack together to minimize storage slots.
struct MarketData {
    uint256 id; // 0 == not found
    uint256 ventureId;
    uint64 tradingStart;
    uint64 tradingEnd;
    uint32 winningThresholdBps; // snapshotted from Hub at creation
    uint32 executionDelay; // snapshotted from Hub at creation (seconds)
    uint16 swapFeeBps; // decision swap fee (bps of trade), snapshotted from Hub at creation
    uint16 protocolCutBps; // protocol's cut of the fee (bps of fee), snapshotted from Hub at creation
    bool settled;
    bool executed;
    uint256[] proposalIds; // [0] is always the no-op proposal
}

/// @notice Per-proposal metadata.
/// @dev The virtual venture/money token IDs are derived from the proposal ID (id*2, id*2+1)
///      rather than stored; the owning market is held by the proposalToMarket mapping.
struct ProposalData {
    bool isNoOp;
    string title;
    bytes executionPayload; // empty for no-op
}

/// @notice Per-proposal market state: CPMM reserves, accrued protocol fees, and LP accounting.
/// @dev Embeds CPMM.State so the CPMM library operates on the pool's reserves directly.
struct Pool {
    CPMM.State cpmm; // reserve0 (virtual venture), reserve1 (virtual money)
    uint256 accruedFeeVenture; // protocol fees accrued (virtual venture)
    uint256 accruedFeeMoney;
    uint256 userVirtualVentureSupply; // user-claimable supply (excludes reserves)
    uint256 userVirtualMoneySupply;
    uint256 totalLiquidityShares; // incl. protocol-seeded baseline
}

/// @notice Per-market settlement accounting.
struct SettleAcct {
    uint256 realVentureBalance; // real tokens escrowed from splits
    uint256 realMoneyBalance;
    uint256 winningProposalId; // 0 until settled
    uint256 winningPriceX112; // winning TWAP (Q112)
    uint256 lpTokenId; // spot V4 LP NFT removed at creation (0 if none)
    uint256 ventureRemoved; // amounts removed from spot to seed conditionals
    uint256 moneyRemoved;
    uint128 liquidityRemoved;
    uint64 settledAt; // block timestamp settle() ran; 0 until settled. Anchors the execution delay.
}
