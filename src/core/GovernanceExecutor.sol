// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {IGovernanceExecutor} from "../interfaces/IGovernanceExecutor.sol";
import {GovernanceTypes} from "../libraries/GovernanceTypes.sol";
import {GovernanceActions} from "../libraries/GovernanceActions.sol";
import {GovernancePayloadValidator} from "../libraries/GovernancePayloadValidator.sol";

/// @title GovernanceExecutor
/// @notice Executes governance action payloads against a venture treasury.
contract GovernanceExecutor is ReentrancyGuard, IGovernanceExecutor {
    IUmiaHub public immutable HUB;

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Constructor
    /// @param _hub The UmiaHub address.
    constructor(address _hub) {
        HUB = IUmiaHub(_hub);
    }

    // ─────────────────────────────────────────────────────────
    // Execution
    // ─────────────────────────────────────────────────────────

    /// @notice Validate a governance plan payload without executing it.
    /// @param executionPayload The governance execution payload.
    function validatePayload(bytes calldata executionPayload) external pure {
        _validatePayload(executionPayload);
    }

    /// @notice Execute a governance plan against a venture treasury.
    /// @dev Callable only by UmiaMarketCore.
    /// @param venture The venture treasury address.
    /// @param marketId The market ID.
    /// @param proposalId The winning proposal ID.
    /// @param executionPayload The governance execution payload.
    function executeProposal(address venture, uint256 marketId, uint256 proposalId, bytes calldata executionPayload)
        external
        nonReentrant
    {
        if (msg.sender != HUB.umiaMarketCore()) revert OnlyMarketCore();
        if (HUB.governanceExecutor(venture) != address(this)) revert InvalidExecutor();
        if (IVenture(venture).liquidationActive()) revert LiquidationActive();

        GovernanceTypes.ExecutionPlanV1 memory plan = _validatePayload(executionPayload);

        uint256 actionCount = plan.actions.length;
        for (uint256 i = 0; i < actionCount; i++) {
            GovernanceTypes.ActionV1 memory action = plan.actions[i];
            GovernanceActions.executeActionV1(IVenture(venture), action);
            emit GovernanceActionExecuted(venture, marketId, proposalId, action.actionType);
        }

        emit GovernancePlanExecuted(venture, marketId, proposalId, keccak256(executionPayload));
    }

    function _validatePayload(bytes calldata executionPayload)
        internal
        pure
        returns (GovernanceTypes.ExecutionPlanV1 memory plan)
    {
        if (executionPayload.length == 0) revert InvalidPayload();

        plan = GovernancePayloadValidator.decodeAndValidatePayload(executionPayload);
    }
}
