// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {HookServerPermits} from "../../src/periphery/HookServerPermits.sol";
import {UmiaValidationHookBase} from "./UmiaValidationHookBase.t.sol";

/// @dev Explicit permits must remain independent of standing zkTLS registration and its caps.
contract UmiaValidationHookMixedPermitsTest is UmiaValidationHookBase {
    uint128 constant CAP = 6e6;
    uint128 constant AMOUNT = 1e6;
    bytes32 constant NONCE = keccak256("mixed-step-permit");

    function _mixedStepSetup() internal {
        vm.startPrank(admin);
        hook.setSigner(signerAddress);
        hook.enableStepPermit(0);
        hook.setStepMaxBidAmount(0, CAP);
        hook.setZkGlobalMaxBidAmount(CAP);
        vm.stopPrank();
        vm.roll(step0Start);
    }

    function _proofBid(uint128 amount) internal {
        bytes memory proof = _inlineProof(0, user);
        vm.prank(address(mockCCA));
        hook.validate(0, amount, user, user, proof);
    }

    function _permit(uint256 step, uint128 amount, uint256 deadline) internal view returns (bytes memory) {
        return _encodePermitHookData(
            step, NONCE, deadline, _signServerPermitWithAmount(address(hook), user, step, NONCE, deadline, amount)
        );
    }

    function _assertTotals(uint256 expected) internal view {
        assertEq(hook.zkBidTotal(user, 0), expected, "zk step total");
        assertEq(hook.zkGlobalBidTotal(), expected, "zk global total");
    }

    function _assertPermitBid(bytes memory permit, uint128 amount, uint256 expectedZkTotal) internal {
        vm.recordLogs();
        vm.prank(address(mockCCA));
        hook.validate(0, amount, user, user, permit);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only the permit event, no zk accrual or registration");
        assertEq(logs[0].emitter, address(hook));
        assertEq(logs[0].topics[0], keccak256("PermitConsumed(address,uint256,bytes32)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(user))));
        assertEq(logs[0].topics[2], bytes32(0));
        assertEq(logs[0].topics[3], NONCE);
        assertTrue(hook.isPermitNonceUsed(NONCE));
        _assertTotals(expectedZkTotal);
    }

    function _assertCredentialOrder(bool proofFirst, uint128 zkAmount) internal {
        _mixedStepSetup();
        bytes memory permit = _permit(0, AMOUNT, block.timestamp + 1 hours);
        if (proofFirst) _proofBid(zkAmount);
        _assertPermitBid(permit, AMOUNT, proofFirst ? zkAmount : 0);
        assertEq(hook.isVerified(0, user), proofFirst, "permits do not alter registration");
        if (!proofFirst) _proofBid(zkAmount);
        assertTrue(hook.isVerified(0, user));
        _assertTotals(zkAmount);

        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(HookServerPermits.PermitAlreadyUsed.selector, NONCE));
        hook.validate(0, AMOUNT, user, user, permit);

        // Standing registration still accrues only the proof path, up to the cap.
        if (zkAmount < CAP) {
            vm.prank(address(mockCCA));
            hook.validate(0, CAP - zkAmount, user, user, "");
        }
        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user, CAP + 1, CAP));
        hook.validate(0, 1, user, user, "");
        _assertTotals(CAP);

        // Removing the global cap must not bypass the independently exhausted step cap.
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(0);
        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, CAP + 1, CAP));
        hook.validate(0, 1, user, user, "");
        _assertTotals(CAP);
    }

    function test_permitBeforeProof_remainingQuota() public {
        _assertCredentialOrder(false, AMOUNT);
    }

    function test_permitBeforeProof_exhaustedQuota() public {
        _assertCredentialOrder(false, CAP);
    }

    function test_proofBeforePermit_remainingQuota() public {
        _assertCredentialOrder(true, AMOUNT);
    }

    function test_proofBeforePermit_exhaustedQuota() public {
        _assertCredentialOrder(true, CAP);
    }

    function _registeredPermit() internal returns (bytes memory) {
        _mixedStepSetup();
        _proofBid(AMOUNT);
        return _permit(0, AMOUNT, block.timestamp + 1 hours);
    }

    function _rejectPermit(bytes memory permit, uint128 amount, bytes memory reason) internal {
        vm.prank(address(mockCCA));
        vm.expectRevert(reason);
        hook.validate(0, amount, user, user, permit);
        assertFalse(hook.isPermitNonceUsed(NONCE));
        _assertTotals(AMOUNT);
    }

    function test_registeredPermit_requiresExactAmount() public {
        bytes memory permit = _registeredPermit();
        _rejectPermit(permit, AMOUNT - 1, abi.encodeWithSelector(HookServerPermits.InvalidSignature.selector));
        _rejectPermit(permit, AMOUNT + 1, abi.encodeWithSelector(HookServerPermits.InvalidSignature.selector));
        _assertPermitBid(permit, AMOUNT, AMOUNT);
    }

    function test_registeredPermit_rejectsWrongSigner() public {
        bytes memory permit = _registeredPermit();
        vm.prank(admin);
        hook.setSigner(makeAddr("other-signer"));
        _rejectPermit(permit, AMOUNT, abi.encodeWithSelector(HookServerPermits.InvalidSignature.selector));
    }

    function test_registeredPermit_requiresSigner() public {
        bytes memory permit = _registeredPermit();
        vm.prank(admin);
        hook.setSigner(address(0));
        _rejectPermit(permit, AMOUNT, abi.encodeWithSelector(HookServerPermits.SignerNotSet.selector));
    }

    function test_registeredPermit_rejectsWrongWallet() public {
        _registeredPermit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature =
            _signServerPermitWithAmount(address(hook), makeAddr("other-wallet"), 0, NONCE, deadline, AMOUNT);
        _rejectPermit(
            _encodePermitHookData(0, NONCE, deadline, signature),
            AMOUNT,
            abi.encodeWithSelector(HookServerPermits.InvalidSignature.selector)
        );
    }

    function test_registeredPermit_rejectsExpiredDeadline() public {
        bytes memory permit = _registeredPermit();
        vm.warp(block.timestamp + 1 hours + 1);
        _rejectPermit(permit, AMOUNT, abi.encodeWithSelector(HookServerPermits.ExpiredDeadline.selector));
    }

    function test_registeredPermit_rejectsFutureStep() public {
        _registeredPermit();
        _rejectPermit(
            _permit(1, AMOUNT, block.timestamp + 1 hours),
            AMOUNT,
            abi.encodeWithSelector(UmiaValidationHook.PermitStepTooHigh.selector, 1, 0)
        );
    }

    function test_registeredPermit_checksSignedStep() public {
        _registeredPermit();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signServerPermitWithAmount(address(hook), user, 1, NONCE, deadline, AMOUNT);
        _rejectPermit(
            _encodePermitHookData(0, NONCE, deadline, signature),
            AMOUNT,
            abi.encodeWithSelector(HookServerPermits.InvalidSignature.selector)
        );
    }

    function test_registeredPermit_rejectsMalformedEnvelopeAndSignature() public {
        _registeredPermit();
        _rejectPermit(hex"01", AMOUNT, abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        _rejectPermit(
            _encodePermitHookData(0, NONCE, block.timestamp + 1 hours, hex"1234"),
            AMOUNT,
            abi.encodeWithSelector(HookServerPermits.InvalidSignature.selector)
        );
    }

    function test_registeredPermit_canExceedZkCaps() public {
        _registeredPermit();
        _assertPermitBid(_permit(0, CAP * 2, block.timestamp + 1 hours), CAP * 2, AMOUNT);
    }

    function test_registeredPermit_disabledStepRemainsPublic() public {
        bytes memory permit = _registeredPermit();
        vm.prank(admin);
        hook.disableStep(0);
        vm.prank(address(mockCCA));
        hook.validate(0, AMOUNT, user, user, permit);
        assertFalse(hook.isPermitNonceUsed(NONCE));
        _assertTotals(AMOUNT);
    }

    function test_registeredPermit_removedGatesRemainPublic() public {
        bytes memory permit = _registeredPermit();
        vm.startPrank(admin);
        hook.disableStepPermit(0);
        hook.setStepProviders(0, _emptyHashes(), _emptyIds());
        vm.stopPrank();
        vm.prank(address(mockCCA));
        hook.validate(0, AMOUNT, user, user, permit);
        assertFalse(hook.isPermitNonceUsed(NONCE));
        _assertTotals(AMOUNT);
    }

    function test_registeredPermit_disabledPermitGateStillUsesZkCaps() public {
        bytes memory permit = _registeredPermit();
        vm.prank(admin);
        hook.disableStepPermit(0);
        vm.prank(address(mockCCA));
        hook.validate(0, AMOUNT, user, user, permit);
        assertFalse(hook.isPermitNonceUsed(NONCE));
        _assertTotals(AMOUNT * 2);
    }

    function _registeredAtLaterStep(bool everyBid) internal {
        mockCCA = _deployTwoStepCCA();
        hook = _newHook(admin, address(zktlsVerifier), signerAddress);
        vm.startPrank(admin);
        hook.setCCA(address(mockCCA));
        for (uint256 step; step < 2; ++step) {
            hook.enableStep(step, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
            hook.enableStepPermit(step);
            hook.setStepMaxBidAmount(step, CAP);
        }
        hook.setZkGlobalMaxBidAmount(CAP);
        hook.setVerifyEveryBid(1, everyBid);
        vm.stopPrank();
        vm.roll(step0Start);
        _proofBid(AMOUNT);
        vm.roll(step0End);
    }

    function test_registeredPermit_laterOrdinaryStepChecksSourceGate() public {
        _registeredAtLaterStep(false);
        bytes memory permit = _permit(0, AMOUNT, block.timestamp + 1 hours);
        vm.prank(admin);
        hook.disableStepPermit(0);
        _rejectPermit(permit, AMOUNT, abi.encodeWithSelector(UmiaValidationHook.ServerPermitNotEnabled.selector, 0));
        vm.prank(admin);
        hook.enableStepPermit(0);
        _assertPermitBid(permit, AMOUNT, AMOUNT);
        assertEq(hook.zkBidTotal(user, 1), 0);
    }

    function test_registeredPermit_verifyEveryBidRequiresCurrentStepCredential() public {
        _registeredAtLaterStep(true);
        _rejectPermit("", AMOUNT, abi.encodeWithSelector(UmiaValidationHook.NotVerified.selector, user));
        _rejectPermit(
            _permit(0, AMOUNT, block.timestamp + 1 hours),
            AMOUNT,
            abi.encodeWithSelector(UmiaValidationHook.CredentialStepMismatch.selector, 0, 1)
        );
        bytes memory permit = _permit(1, AMOUNT, block.timestamp + 1 hours);
        vm.prank(address(mockCCA));
        hook.validate(0, AMOUNT, user, user, permit);
        assertTrue(hook.isPermitNonceUsed(NONCE));
        _assertTotals(AMOUNT);
        assertEq(hook.zkBidTotal(user, 1), 0);
    }
}
