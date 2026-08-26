// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {GovernanceActions} from "../../src/libraries/GovernanceActions.sol";
import {GovernancePayloadValidator} from "../../src/libraries/GovernancePayloadValidator.sol";

contract GovernancePayloadValidatorHarness {
    function decode(bytes calldata payload) external pure returns (uint16) {
        return GovernancePayloadValidator.decodePlanVersion(payload);
    }

    function decodeAndValidate(bytes calldata payload) external pure returns (GovernanceTypes.ExecutionPlanV1 memory) {
        return GovernancePayloadValidator.decodeAndValidatePayload(payload);
    }

    function validate(GovernanceTypes.ExecutionPlanV1 memory plan) external pure {
        GovernancePayloadValidator.validatePlanV1(plan);
    }
}

contract GovernancePayloadValidatorTest is Test {
    GovernancePayloadValidatorHarness internal harness;

    function setUp() public {
        harness = new GovernancePayloadValidatorHarness();
    }

    function test_decodePlanVersion() public view {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](0);
        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
        uint16 version = harness.decode(payload);
        assertEq(version, 1);
    }

    function test_validatePlanV1_revertsOnInvalidVersion() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](0);
        GovernanceTypes.ExecutionPlanV1 memory plan = GovernanceTypes.ExecutionPlanV1({version: 2, actions: actions});

        vm.expectRevert(GovernancePayloadValidator.InvalidVersion.selector);
        harness.validate(plan);
    }

    function test_validatePlanV1_revertsOnInvalidAction() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: address(0), amount: 1}))
        });

        GovernanceTypes.ExecutionPlanV1 memory plan = GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions});

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        harness.validate(plan);
    }

    function test_decodeAndValidatePayload_revertsOnTruncatedPayload() public {
        vm.expectRevert(GovernancePayloadValidator.InvalidPayloadEncoding.selector);
        harness.decodeAndValidate(hex"00010203");
    }

    // A plan exceeding MAX_ACTIONS is rejected so a winning outcome can never become permanently
    // unexecutable due to a block-gas-limit overrun on execution.
    function test_validatePlanV1_revertsOnTooManyActions() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](21);
        for (uint256 i = 0; i < 21; i++) {
            actions[i] = GovernanceTypes.ActionV1({
                actionType: GovernanceTypes.ActionType.UPLOAD_DOCUMENT,
                actionVersion: 1,
                data: abi.encode(GovernanceTypes.UploadDocument({name: "n", uri: "u"}))
            });
        }
        GovernanceTypes.ExecutionPlanV1 memory plan = GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions});

        vm.expectRevert(GovernancePayloadValidator.TooManyActions.selector);
        harness.validate(plan);
    }

    function test_validatePlanV1_allowsExactlyMaxActions() public view {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](20);
        for (uint256 i = 0; i < 20; i++) {
            actions[i] = GovernanceTypes.ActionV1({
                actionType: GovernanceTypes.ActionType.UPLOAD_DOCUMENT,
                actionVersion: 1,
                data: abi.encode(GovernanceTypes.UploadDocument({name: "n", uri: "u"}))
            });
        }
        GovernanceTypes.ExecutionPlanV1 memory plan = GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions});
        harness.validate(plan); // does not revert
    }

    // UPDATE_MONTHLY_ALLOWANCE with a zero-address token is rejected.
    function test_validatePlanV1_revertsOnZeroAllowanceToken() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.UpdateMonthlyAllowance({token: address(0), amount: 1e18}))
        });
        GovernanceTypes.ExecutionPlanV1 memory plan = GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions});

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        harness.validate(plan);
    }
}
