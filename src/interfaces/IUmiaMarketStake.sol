// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUmiaMarketStake
/// @notice Interface for the standalone market stake contract.
interface IUmiaMarketStake {
    // ─────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────

    struct MarketStake {
        uint256 amount;
        uint256 lockedUntil;
    }

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error MarketStakeNotConfigured();
    error MarketStakeAlreadyDeposited();
    error MarketStakeRequired();
    error MarketStakeStillLocked();
    error Unauthorized();
    error VentureNotFound();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event MarketStakeDeposited(uint256 indexed ventureId, address indexed staker, uint256 amount);
    event MarketStakeLocked(uint256 indexed ventureId, address indexed staker, uint256 marketId, uint256 lockedUntil);
    event MarketStakeWithdrawn(uint256 indexed ventureId, address indexed staker, uint256 amount);

    // ─────────────────────────────────────────────────────────
    // Functions
    // ─────────────────────────────────────────────────────────

    function marketStakes(uint256 ventureId, address staker) external view returns (uint256 amount, uint256 lockedUntil);
    function depositMarketStake(uint256 ventureId) external;
    function withdrawMarketStake(uint256 ventureId) external;
    function verifyAndLockStake(uint256 ventureId, address creator, uint256 tradingEnd, uint256 marketId) external;
}
