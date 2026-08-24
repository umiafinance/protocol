// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GovernanceTypes} from "../libraries/GovernanceTypes.sol";

/// @title IGovernanceExecutor
/// @notice Interface for executing governance payloads against a venture treasury.
interface IGovernanceExecutor {
    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error OnlyMarketCore();
    error InvalidExecutor();
    error InvalidPayload();
    error LiquidationActive();
    error LiquidationMustBeFinal();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event GovernancePlanExecuted(
        address indexed venture, uint256 indexed marketId, uint256 indexed proposalId, bytes32 planHash
    );

    event GovernanceActionExecuted(
        address indexed venture,
        uint256 indexed marketId,
        uint256 indexed proposalId,
        GovernanceTypes.ActionType actionType
    );

    // ─────────────────────────────────────────────────────────
    // Functions
    // ─────────────────────────────────────────────────────────

    function validatePayload(bytes calldata executionPayload) external pure;

    function executeProposal(address venture, uint256 marketId, uint256 proposalId, bytes calldata executionPayload)
        external;
}
