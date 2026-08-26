// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BlockNumberish} from "@blocknumberish/src/BlockNumberish.sol";
import {IContinuousClearingAuction} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";

/// @title CCAExitHelper
/// @notice Collapses a live "out-bid bid" exit into a single transaction.
/// @dev `IContinuousClearingAuction.exitPartiallyFilledBid` already checkpoints internally
///      and, when `outbidBlock` equals the current block, uses that freshly-written
///      checkpoint instead of a storage read. The only reason a live out-bid exit needed
///      two transactions was that calldata cannot express "the current block": a caller
///      cannot predict which block its transaction will be mined in, so it could not supply
///      a valid `outbidBlock` hint and had to `checkpoint()` in a separate transaction
///      first. This helper reads the block number on-chain at execution time instead.
///
///      It inherits `BlockNumberish` so the value it passes matches what the auction
///      computes in the same transaction (Arbitrum One reports the L2 block via ArbSys, not
///      `block.number`). The helper holds no funds and needs no access control:
///      `exitPartiallyFilledBid` is permissionless and refunds the stored bid owner, never
///      `msg.sender`.
contract CCAExitHelper is BlockNumberish {
    /// @notice Exit a bid out-bid by the current, not-yet-checkpointed clearing price, in
    ///         one transaction.
    /// @dev For the live out-bid case only (off-chain hint computation returns
    ///      `outbidBlock == 0`). A bid already out-bid in a stored checkpoint has no two-tx
    ///      problem and should call `exitPartiallyFilledBid` directly with that stored block.
    ///      Reverts (bubbled up from the auction) if the bid is not actually out-bid at the
    ///      current clearing price.
    /// @param auction The auction holding the bid.
    /// @param bidId The id of the bid to exit.
    /// @param lastFullyFilledCheckpointBlock The last stored checkpoint whose clearing price
    ///        is strictly below the bid's max price (computed off-chain from stored state).
    function exitOutbidBid(IContinuousClearingAuction auction, uint256 bidId, uint64 lastFullyFilledCheckpointBlock)
        external
    {
        auction.exitPartiallyFilledBid(bidId, lastFullyFilledCheckpointBlock, uint64(_getBlockNumberish()));
    }
}
