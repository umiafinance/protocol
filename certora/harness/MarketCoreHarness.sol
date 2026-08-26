// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {CPMM} from "../../src/libraries/CPMM.sol";

/// @title MarketCoreHarness
/// @notice Exposes UmiaMarketCore internals for Certora formal verification
contract MarketCoreHarness is UmiaMarketCore {
    constructor(address _hub) UmiaMarketCore(_hub) {}

    // ─── Exposed Internals ──────────────────────────────────

    function checkInvariant(uint256 marketId) external view {
        _checkInvariant(marketId);
    }

    function getMaxUserVirtualSupply(uint256 marketId) external view returns (uint256 maxVenture, uint256 maxMoney) {
        return _getMaxUserVirtualSupply(marketId);
    }

    // ─── View Helpers for CVL ───────────────────────────────

    function getCpmmReserve0(uint256 proposalId) external view returns (uint256) {
        return cpmmStates[proposalId].reserve0;
    }

    function getCpmmReserve1(uint256 proposalId) external view returns (uint256) {
        return cpmmStates[proposalId].reserve1;
    }

    function getUserVirtualVentureSupply(uint256 proposalId) external view returns (uint256) {
        return userVirtualVentureSupply[proposalId];
    }

    function getUserVirtualMoneySupply(uint256 proposalId) external view returns (uint256) {
        return userVirtualMoneySupply[proposalId];
    }

    function getRealVentureBalance(uint256 marketId) external view returns (uint256) {
        return realVentureBalance[marketId];
    }

    function getRealMoneyBalance(uint256 marketId) external view returns (uint256) {
        return realMoneyBalance[marketId];
    }

    function getTotalSupply(uint256 tokenId) external view returns (uint256) {
        return totalSupply[tokenId];
    }

    function getHasClaimed(uint256 marketId, address user) external view returns (bool) {
        return hasClaimed[marketId][user];
    }

    function getIsSettled(uint256 marketId) external view returns (bool) {
        return this.winningProposalByMarketId(marketId).proposalId != 0;
    }

    function getIsExecuted(uint256 marketId) external view returns (bool) {
        return marketExecuted[marketId];
    }

    function getWinningProposalId(uint256 marketId) external view returns (uint256) {
        return this.winningProposalByMarketId(marketId).proposalId;
    }

    function getBalanceOfToken(address user, uint256 tokenId) external view returns (uint256) {
        return balanceOf[user][tokenId];
    }

    function getMarketCounter() external view returns (uint256) {
        return marketCounter;
    }

    function getProposalCounter() external view returns (uint256) {
        return proposalCounter;
    }

    function getProposalMarket(uint256 proposalId) external view returns (uint256) {
        return proposalToMarket[proposalId];
    }

    function getLpVentureRemoved(uint256 marketId) external view returns (uint256) {
        return liquidityRemovalInfo[marketId].ventureRemoved;
    }

    function getLpMoneyRemoved(uint256 marketId) external view returns (uint256) {
        return liquidityRemovalInfo[marketId].moneyRemoved;
    }

    // _proposalById storage mapping is private, so we access via the public proposalInfo getter.
    // This reads the same underlying storage as claimSettlement's internal access.
    function getStoredVirtualVentureId(uint256 proposalId) external view returns (uint256) {
        (,,, uint256 virtualVentureId,) = this.proposalInfo(proposalId);
        return virtualVentureId;
    }

    function getStoredVirtualMoneyId(uint256 proposalId) external view returns (uint256) {
        (,,,, uint256 virtualMoneyId) = this.proposalInfo(proposalId);
        return virtualMoneyId;
    }
}
