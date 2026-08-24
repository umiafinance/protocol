// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {GovernanceTypes} from "./GovernanceTypes.sol";
import {GovernanceActions} from "./GovernanceActions.sol";
import {IGovernanceExecutor} from "../interfaces/IGovernanceExecutor.sol";

library GovernancePayloadValidator {
    error InvalidVersion();
    error InvalidPayloadEncoding();
    error TooManyActions();

    /// @notice Upper bound on actions per plan.
    /// @dev Prevents a winning plan whose execution loop exceeds the block gas limit,
    ///      which would make the decided outcome permanently unexecutable.
    uint256 private constant MAX_ACTIONS = 20;

    function decodePlanVersion(bytes calldata executionPayload) internal pure returns (uint16 version) {
        if (executionPayload.length < 64) revert InvalidPayloadEncoding();
        version = abi.decode(executionPayload[32:], (uint16));
    }

    function validatePlanV1(GovernanceTypes.ExecutionPlanV1 memory plan) internal pure {
        if (plan.version != 1) revert InvalidVersion();

        uint256 actionCount = plan.actions.length;
        if (actionCount > MAX_ACTIONS) revert TooManyActions();
        for (uint256 i = 0; i < actionCount; i++) {
            if (plan.actions[i].actionType == GovernanceTypes.ActionType.LIQUIDATE_TREASURY && i + 1 != actionCount) {
                revert IGovernanceExecutor.LiquidationMustBeFinal();
            }
            GovernanceActions.validateActionV1(plan.actions[i]);
        }
    }

    function decodeAndValidatePayload(bytes calldata executionPayload)
        internal
        pure
        returns (GovernanceTypes.ExecutionPlanV1 memory plan)
    {
        uint16 planVersion = decodePlanVersion(executionPayload);
        if (planVersion != 1) revert InvalidVersion();

        plan = abi.decode(executionPayload, (GovernanceTypes.ExecutionPlanV1));
        validatePlanV1(plan);
    }
}
