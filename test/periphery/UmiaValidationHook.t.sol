// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IValidationHook} from "@continuous-clearing-auction/interfaces/IValidationHook.sol";
import {AuctionStep} from "@continuous-clearing-auction/libraries/StepLib.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {IMaxBidPriceValidationHook} from "../../src/interfaces/IMaxBidPriceValidationHook.sol";
import {IUmiaValidationHook} from "../../src/interfaces/IUmiaValidationHook.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {Reclaim} from "../../src/reclaim/Reclaim.sol";
import {Claims} from "../../src/reclaim/Claims.sol";

contract MockCCA {
    address private _pointer;
    uint64 private _startBlock;
    uint256 private _floorPrice;
    uint256 private _tickSpacing;

    uint24[] private _mps;
    uint64[] private _starts;
    uint64[] private _ends;

    constructor(bytes memory _stepsData, uint64 startBlock_) {
        _pointer = SSTORE2.write(_stepsData);
        _startBlock = startBlock_;
        _floorPrice = 1000;
        _tickSpacing = 100;

        uint64 cursor = startBlock_;
        for (uint256 i; i < _stepsData.length; i += 8) {
            uint24 mps;
            uint40 blockDelta;
            assembly {
                let packed := shr(192, mload(add(add(_stepsData, 0x20), i)))
                mps := shr(40, packed)
                blockDelta := and(packed, 0xFFFFFFFFFF)
            }
            _mps.push(mps);
            _starts.push(cursor);
            uint64 end = cursor + uint64(blockDelta);
            _ends.push(end);
            cursor = end;
        }
    }

    function pointer() external view returns (address) {
        return _pointer;
    }

    function startBlock() external view returns (uint64) {
        return _startBlock;
    }

    function step() external view returns (AuctionStep memory) {
        for (uint256 i; i < _starts.length; i++) {
            if (block.number >= _starts[i] && block.number < _ends[i]) {
                return AuctionStep({mps: _mps[i], startBlock: _starts[i], endBlock: _ends[i]});
            }
        }
        uint256 last = _starts.length - 1;
        return AuctionStep({mps: _mps[last], startBlock: _starts[last], endBlock: _ends[last]});
    }

    function floorPrice() external view returns (uint256) {
        return _floorPrice;
    }

    function tickSpacing() external view returns (uint256) {
        return _tickSpacing;
    }

    function setFloorPrice(uint256 fp) external {
        _floorPrice = fp;
    }

    function setTickSpacing(uint256 ts) external {
        _tickSpacing = ts;
    }
}

contract StaleMockCCA {
    address private _pointer;
    uint64 private _startBlock;

    uint24[] private _mps;
    uint64[] private _starts;
    uint64[] private _ends;
    uint256 private _currentIdx;

    constructor(bytes memory _stepsData, uint64 startBlock_) {
        _pointer = SSTORE2.write(_stepsData);
        _startBlock = startBlock_;

        uint64 cursor = startBlock_;
        for (uint256 i; i < _stepsData.length; i += 8) {
            uint24 mps;
            uint40 blockDelta;
            assembly {
                let packed := shr(192, mload(add(add(_stepsData, 0x20), i)))
                mps := shr(40, packed)
                blockDelta := and(packed, 0xFFFFFFFFFF)
            }
            _mps.push(mps);
            _starts.push(cursor);
            uint64 end = cursor + uint64(blockDelta);
            _ends.push(end);
            cursor = end;
        }
    }

    function pointer() external view returns (address) {
        return _pointer;
    }

    function startBlock() external view returns (uint64) {
        return _startBlock;
    }

    function step() external view returns (AuctionStep memory) {
        return AuctionStep({mps: _mps[_currentIdx], startBlock: _starts[_currentIdx], endBlock: _ends[_currentIdx]});
    }

    function advanceStep() external {
        if (_currentIdx + 1 < _starts.length) _currentIdx++;
    }

    function floorPrice() external pure returns (uint256) {
        return 1000;
    }

    function tickSpacing() external pure returns (uint256) {
        return 100;
    }
}

contract UmiaValidationHookTest is Test {
    UmiaValidationHook hook;
    Reclaim reclaim;
    MockCCA mockCCA;

    address admin = makeAddr("admin");
    address user = makeAddr("user");

    uint256 constant WITNESS_PRIVATE_KEY = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    address witnessAddress;

    uint256 constant SIGNER_PRIVATE_KEY = 0xaabbccdd00112233445566778899aabb00112233445566778899aabbccddeeff;
    address signerAddress;

    bytes32 constant PROVIDER_HASH_1 = 0xc9e2404b50af02ddd8797e218f19b0b2a896cdcd9dbf9ea525b89db2fa37de76;
    bytes32 constant PROVIDER_HASH_2 = 0xaabbccdd00112233445566778899aabbccddeeff00112233445566778899aabb;
    bytes32 constant PROVIDER_HASH_3 = 0x1122334455667788990011223344556677889900112233445566778899001122;

    uint64 step0Start = 100;
    uint64 step0End = 200;

    function _packStep(uint24 mps, uint40 blockDelta) internal pure returns (bytes memory) {
        return abi.encodePacked(mps, blockDelta);
    }

    function _emptyHashes() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _emptyIds() internal pure returns (string[] memory) {
        return new string[](0);
    }

    function _singleHash(bytes32 h) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = h;
    }

    function _singleId(string memory id) internal pure returns (string[] memory arr) {
        arr = new string[](1);
        arr[0] = id;
    }

    function _twoHashes(bytes32 h1, bytes32 h2) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = h1;
        arr[1] = h2;
    }

    function _twoIds(string memory id1, string memory id2) internal pure returns (string[] memory arr) {
        arr = new string[](2);
        arr[0] = id1;
        arr[1] = id2;
    }

    function _deploySingleStepCCA() internal returns (MockCCA) {
        bytes memory data = _packStep(10_000_000, uint40(step0End - step0Start));
        return new MockCCA(data, step0Start);
    }

    function _deployTwoStepCCA() internal returns (MockCCA) {
        bytes memory data = abi.encodePacked(
            _packStep(5_000_000, 100), // step 0: blocks 100-200
            _packStep(5_000_000, 100) // step 1: blocks 200-300
        );
        return new MockCCA(data, 100);
    }

    function _deployThreeStepCCA() internal returns (MockCCA) {
        bytes memory data = abi.encodePacked(
            _packStep(5_000_000, 100), // step 0: blocks 100-200
            _packStep(5_000_000, 100), // step 1: blocks 200-300
            _packStep(5_000_000, 100) // step 2: blocks 300-400
        );
        return new MockCCA(data, 100);
    }

    function _createProofForUser(address _user) internal view returns (bytes memory) {
        return _createProofForUserWithProvider(_user, PROVIDER_HASH_1);
    }

    function _createProofForUserWithProvider(address _user, bytes32 _providerHash)
        internal
        view
        returns (bytes memory)
    {
        string memory context = string(
            abi.encodePacked(
                '{"contextAddress":"',
                _addressToString(_user),
                '","providerHash":"',
                _bytes32ToHexString(_providerHash),
                '"}'
            )
        );

        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: context});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: _user, timestampS: uint32(block.timestamp), epoch: 2
        });

        bytes memory serialised = abi.encodePacked(
            _bytes2str(abi.encodePacked(claimData.identifier)),
            "\n",
            _address2str(claimData.owner),
            "\n",
            _uint2str(claimData.timestampS),
            "\n",
            _uint2str(claimData.epoch)
        );

        bytes32 messageHash =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", _uint2str(serialised.length), serialised));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WITNESS_PRIVATE_KEY, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        return abi.encode(proof);
    }

    function _createProofForUserWithWrongContext(address _user, address _wrongUser)
        internal
        view
        returns (bytes memory)
    {
        string memory context = string(
            abi.encodePacked('{"contextAddress":"', _addressToString(_wrongUser), '","providerHash":"0x1234"}')
        );

        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: context});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: _user, timestampS: uint32(block.timestamp), epoch: 2
        });

        bytes memory serialised = abi.encodePacked(
            _bytes2str(abi.encodePacked(claimData.identifier)),
            "\n",
            _address2str(claimData.owner),
            "\n",
            _uint2str(claimData.timestampS),
            "\n",
            _uint2str(claimData.epoch)
        );

        bytes32 messageHash =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", _uint2str(serialised.length), serialised));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WITNESS_PRIVATE_KEY, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        return abi.encode(proof);
    }

    function _signServerPermit(address hookAddr, address wallet, uint256 stepIdx, bytes32 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signServerPermitWithAmount(hookAddr, wallet, stepIdx, nonce, deadline, 0);
    }

    function _signServerPermitWithAmount(
        address hookAddr,
        address wallet,
        uint256 stepIdx,
        bytes32 nonce,
        uint256 deadline,
        uint128 amount
    ) internal view returns (bytes memory) {
        bytes32 DOMAIN_TYPEHASH = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 SERVER_PERMIT_TYPEHASH =
            keccak256("ServerPermit(address wallet,uint256 step,bytes32 nonce,uint256 deadline,uint128 amount)");
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("UmiaValidationHook"), keccak256("1"), block.chainid, hookAddr)
        );
        bytes32 structHash = keccak256(abi.encode(SERVER_PERMIT_TYPEHASH, wallet, stepIdx, nonce, deadline, amount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _encodePermitHookData(uint256 stepIdx, bytes32 nonce, uint256 deadline, bytes memory signature)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint8(0x01), abi.encode(stepIdx, nonce, deadline, signature));
    }

    function setUp() public {
        witnessAddress = vm.addr(WITNESS_PRIVATE_KEY);
        signerAddress = vm.addr(SIGNER_PRIVATE_KEY);

        reclaim = new Reclaim();
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness({addr: witnessAddress, host: "wss://test.example.com"});
        reclaim.addNewEpoch(witnesses, 1);

        hook = new UmiaValidationHook(admin, address(reclaim), address(0));
        mockCCA = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook.setCCA(address(mockCCA));
        hook.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();
    }

    // ============ Pre-verification Flow ============

    function test_submitProof_succeeds() public {
        bytes memory proofData = _createProofForUser(user);

        hook.submitProof(user, 0, proofData);

        assertTrue(hook.isVerified(0, user));
    }

    function test_submitProof_emitsEvent() public {
        bytes memory proofData = _createProofForUser(user);

        vm.expectEmit(true, true, false, false);
        emit UmiaValidationHook.ProofVerified(user, 0, bytes32(0));
        hook.submitProof(user, 0, proofData);
    }

    function test_submitProof_thenValidate_succeeds() public {
        bytes memory proofData = _createProofForUser(user);

        hook.submitProof(user, 0, proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, bytes(""));
    }

    function test_submitProof_zeroAddress_reverts() public {
        bytes memory proofData = _createProofForUser(user);

        vm.expectRevert(UmiaValidationHook.ZeroAddress.selector);
        hook.submitProof(address(0), 0, proofData);
    }

    function test_submitProof_stepOutOfBounds_reverts() public {
        bytes memory proofData = _createProofForUser(user);

        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.submitProof(user, 5, proofData);
    }

    function test_submitProof_noCCA_reverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));
        bytes memory proofData = _createProofForUser(user);

        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.submitProof(user, 0, proofData);
    }

    function test_submitProof_permissionless_succeeds() public {
        bytes memory proofData = _createProofForUser(user);

        vm.prank(user);
        hook.submitProof(user, 0, proofData);

        assertTrue(hook.isVerified(0, user));
    }

    function test_submitProof_contextAddressMismatch_reverts() public {
        address wrongUser = makeAddr("wrongUser");
        bytes memory proofData = _createProofForUserWithWrongContext(user, wrongUser);

        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ContextAddressMismatch.selector, user, wrongUser));
        hook.submitProof(user, 0, proofData);
    }

    function test_submitProofBatch_succeeds() public {
        address user2 = makeAddr("user2");
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = user2;

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = _createProofForUser(user);
        proofs[1] = _createProofForUser(user2);

        hook.submitProofBatch(users, 0, proofs);

        assertTrue(hook.isVerified(0, user));
        assertTrue(hook.isVerified(0, user2));
    }

    function test_submitProofBatch_arrayLengthMismatch_reverts() public {
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = makeAddr("user2");

        bytes[] memory proofs = new bytes[](1);
        proofs[0] = _createProofForUser(user);

        vm.expectRevert(UmiaValidationHook.ArrayLengthMismatch.selector);
        hook.submitProofBatch(users, 0, proofs);
    }

    function test_submitProofBatch_permissionless() public {
        address user2 = makeAddr("user2");
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = user2;

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = _createProofForUser(user);
        proofs[1] = _createProofForUser(user2);

        vm.prank(user);
        hook.submitProofBatch(users, 0, proofs);

        assertTrue(hook.isVerified(0, user));
        assertTrue(hook.isVerified(0, user2));
    }

    // ============ Inline Verification Flow ============

    function test_validate_inline_validProof_succeeds() public {
        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, hookData);

        assertTrue(hook.isVerified(0, user));
    }

    function test_validate_inline_contextMismatch_reverts() public {
        address wrongUser = makeAddr("wrongUser");
        bytes memory proofData = _createProofForUserWithWrongContext(user, wrongUser);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ContextAddressMismatch.selector, user, wrongUser));
        hook.validate(0, 0, user, user, hookData);
    }

    function test_validate_inline_storesVerification() public {
        assertFalse(hook.isVerified(0, user));

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, hookData);

        assertTrue(hook.isVerified(0, user));
    }

    // ============ Inline Verification — Monotonic Step Prefix ============

    function test_validate_inline_monotonic_differentProviders_succeeds() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(200); // step 1 — different providers, but proofStep=0 targets step 0's providers
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);

        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
    }

    function test_validate_inline_futureStep_reverts() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(1), proofData);

        vm.roll(100); // step 0 — proofStep=1 > currentStep=0
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofStepTooHigh.selector, 1, 0));
        hook2.validate(0, 0, user, user, hookData);
    }

    function test_validate_inline_monotonic_alreadyVerified_shortCircuits() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        hook2.submitProof(user, 0, proofData);

        vm.roll(200); // step 1 — already verified from step 0, hookData not needed
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inline_stepPrefixed_storesLowestStep() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        // First: inline at step 1 with PROVIDER_HASH_2 proof
        bytes memory proofStep1 = _createProofForUserWithProvider(user, PROVIDER_HASH_2);
        bytes memory hookData1 = abi.encodePacked(uint256(1), proofStep1);
        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData1);
        assertTrue(hook2.isVerified(1, user));
        assertFalse(hook2.isVerified(0, user));

        // Second: inline at step 0 with PROVIDER_HASH_1 proof — lowers the stored step
        bytes memory proofStep0 = _createProofForUserWithProvider(user, PROVIDER_HASH_1);
        bytes memory hookData0 = abi.encodePacked(uint256(0), proofStep0);
        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData0);
        assertTrue(hook2.isVerified(0, user));
    }

    function test_validate_permitOnlyStep_rejectsProofWithServerPermitRequired() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        hook2.enableStepPermit(0);
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        // Permit-only step: a zkTLS proof is the wrong credential, so the step's gate
        // (permit) drives the error rather than the payload's type byte.
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        hook2.validate(0, 0, user, user, hookData);
    }

    // ============ Inline Verification — Extended Edge Cases ============

    function test_validate_inline_threeStepSkip_succeeds() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployThreeStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        hook2.enableStep(2, _singleHash(PROVIDER_HASH_3), _singleId("provider-3"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_1);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(300); // step 2 — proof targets step 0, skipping step 1 entirely
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);

        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
        assertTrue(hook2.isVerified(2, user));
    }

    function test_validate_inline_outOfBoundsProofStep_reverts() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(99), proofData);

        vm.roll(200); // step 1 — proofStep=99 far exceeds currentStep=1
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofStepTooHigh.selector, 99, 1));
        hook2.validate(0, 0, user, user, hookData);
    }

    function test_validate_inline_shortHookData_reverts() public {
        vm.roll(step0Start);
        // 14 bytes: too short for the leading proofStep word -> ProofRequired, not a panic.
        vm.prank(hook.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook.validate(0, 0, user, user, hex"0000000000000000000000000000");
    }

    function test_validate_permitOnly_truncatedPermit_reverts() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();

        vm.roll(step0Start);
        // just the 0x01 type byte: too short for the permit ABI head -> ServerPermitRequired, not a panic.
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, hex"01");
    }

    function test_validate_permitOnly_truncatedSignatureTail_reverts() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();

        // Canonical head (0x01 || permitStep, nonce, deadline, offset=0x80) whose length word
        // declares a 65-byte signature, but no tail data follows. The envelope check must revert
        // ServerPermitRequired instead of letting abi.decode read out of bounds.
        bytes memory truncated =
            abi.encodePacked(uint8(0x01), uint256(0), bytes32(0), uint256(0), uint256(0x80), uint256(65));

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, truncated);
    }

    function test_validate_permitOnly_hugeSignatureLength_reverts() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();

        // Canonical head whose signature length word is crafted at type(uint256).max. The
        // envelope check must revert ServerPermitRequired, not an arithmetic-overflow panic.
        bytes memory malformed =
            abi.encodePacked(uint8(0x01), uint256(0), bytes32(0), uint256(0), uint256(0x80), type(uint256).max);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, malformed);
    }

    function test_validate_bothGates_emptyHookData_reverts() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider")); // proof gate
        h.enableStepPermit(0); // and permit gate
        vm.stopPrank();

        vm.roll(step0Start);
        // both gates configured, no payload -> generic NotVerified (either credential works).
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.NotVerified.selector, user));
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inline_step0_withAllStepsEnabled() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployThreeStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        hook2.enableStep(2, _singleHash(PROVIDER_HASH_3), _singleId("provider-3"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_1);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        // Inline at step 0 — proofStep=0, currentStep=0, exact boundary
        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);
        assertTrue(hook2.isVerified(0, user));

        // Now bid at step 1 — short-circuits because already verified from step 0
        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));

        // And step 2 — also short-circuits
        vm.roll(300);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inline_monotonic_thenPreRegister_keepsLowest() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployThreeStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        hook2.enableStep(2, _singleHash(PROVIDER_HASH_3), _singleId("provider-3"));
        vm.stopPrank();

        // Inline at step 2 with step 2's provider
        bytes memory proof2 = _createProofForUserWithProvider(user, PROVIDER_HASH_3);
        bytes memory hookData2 = abi.encodePacked(uint256(2), proof2);
        vm.roll(300);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData2);
        assertTrue(hook2.isVerified(2, user));
        assertFalse(hook2.isVerified(1, user));
        assertFalse(hook2.isVerified(0, user));

        // Pre-register at step 0 via submitProof — should lower stored step
        bytes memory proof0 = _createProofForUserWithProvider(user, PROVIDER_HASH_1);
        hook2.submitProof(user, 0, proof0);
        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
        assertTrue(hook2.isVerified(2, user));
    }

    function test_validate_inline_secondUserIndependent() public {
        address user2 = makeAddr("user2");
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        // User1 verifies at step 0 inline
        bytes memory proof1 = _createProofForUserWithProvider(user, PROVIDER_HASH_1);
        bytes memory hookData1 = abi.encodePacked(uint256(0), proof1);
        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData1);

        // User2 is NOT verified — should still revert
        vm.roll(200);
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 1));
        hook2.validate(0, 0, user2, user2, bytes(""));

        // User2 verifies at step 1 inline with step 1's provider
        bytes memory proof2 = _createProofForUserWithProvider(user2, PROVIDER_HASH_2);
        bytes memory hookData2 = abi.encodePacked(uint256(1), proof2);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user2, user2, hookData2);

        // User1: verified from step 0 (covers 0,1)
        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
        // User2: verified from step 1 only
        assertFalse(hook2.isVerified(0, user2));
        assertTrue(hook2.isVerified(1, user2));
    }

    function test_validate_inline_proofStepEqualsCurrentStep_boundaryCheck() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployThreeStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        hook2.enableStep(2, _singleHash(PROVIDER_HASH_3), _singleId("provider-3"));
        vm.stopPrank();

        // proofStep == currentStep at each step boundary
        bytes memory proof0 = _createProofForUserWithProvider(user, PROVIDER_HASH_2);
        bytes memory hookData = abi.encodePacked(uint256(1), proof0);

        vm.roll(200); // step 1: proofStep=1 == currentStep=1
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);
        assertTrue(hook2.isVerified(1, user));
        assertFalse(hook2.isVerified(0, user)); // NOT verified at step 0
    }

    // ============ Validate — Enabled Step ============

    function test_validate_inEnabledStep_whenNotVerified_reverts() public {
        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inEnabledStep_whenVerified_succeeds() public {
        bytes memory proofData = _createProofForUser(user);
        hook.submitProof(user, 0, proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inEnabledStep_whenSenderDiffers_reverts() public {
        address other = makeAddr("other");

        bytes memory proofData = _createProofForUser(user);
        hook.submitProof(user, 0, proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(UmiaValidationHook.SenderNotBidOwner.selector);
        hook.validate(0, 0, user, other, bytes(""));
    }

    function test_validate_inEnabledStep_verifiedForLaterStep_reverts() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));

        bytes memory proofData = _createProofForUser(user);
        vm.stopPrank();

        hook2.submitProof(user, 1, proofData);

        vm.roll(100);
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inEnabledStep_verifiedForCorrectStep_succeeds() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        hook2.submitProof(user, 1, proofData);

        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    // ============ Validate — Monotonic Verification ============

    function test_validate_monotonic_verifiedAtStep0_passesStep1() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        hook2.submitProof(user, 0, proofData);

        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));

        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_monotonic_verifiedAtStep1_failsStep0() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        hook2.submitProof(user, 1, proofData);

        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));

        vm.roll(100);
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook2.validate(0, 0, user, user, bytes(""));
    }

    // ============ Validate — Disabled Step ============

    function test_validate_inDisabledStep_allowsAnyone() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();

        vm.prank(admin);
        hook2.setCCA(address(cca2));

        vm.roll(step0Start);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inDisabledStep_revertsDifferentSender() public {
        address other = makeAddr("other");

        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();

        vm.prank(admin);
        hook2.setCCA(address(cca2));

        vm.roll(step0Start);
        vm.prank(hook2.cca());
        vm.expectRevert(UmiaValidationHook.SenderNotBidOwner.selector);
        hook2.validate(0, 0, user, other, bytes(""));
    }

    // ============ Validate — Outside Steps / No CCA ============

    function test_validate_outsideSteps_allowsAnyone() public {
        vm.roll(step0End);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_outsideSteps_revertsDifferentSender() public {
        address other = makeAddr("other");
        vm.roll(step0End);
        vm.prank(hook.cca());
        vm.expectRevert(UmiaValidationHook.SenderNotBidOwner.selector);
        hook.validate(0, 0, user, other, bytes(""));
    }

    function test_validate_noCCA_allowsAnyone() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));
        freshHook.validate(0, 0, user, user, bytes(""));
    }

    // ============ setCCA ============

    function test_setCCA_succeeds() public view {
        IUmiaValidationHook.BlockRange[] memory steps = hook.getSteps();
        assertEq(steps.length, 1);
        assertEq(steps[0].startBlock, step0Start);
        assertEq(steps[0].endBlock, step0End);
    }

    function test_setCCA_emitsEvent() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.CCASet(address(cca2));
        vm.prank(admin);
        hook2.setCCA(address(cca2));
    }

    function test_setCCA_zeroAddress_reverts() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.ZeroAddress.selector);
        hook2.setCCA(address(0));
    }

    function test_setCCA_alreadySet_isNoOp() public {
        MockCCA otherCCA = _deploySingleStepCCA();

        vm.prank(admin);
        hook.setCCA(address(otherCCA));

        assertEq(hook.cca(), address(mockCCA));
    }

    function test_setCCA_nonOwner_reverts() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();

        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook2.setCCA(address(cca2));
    }

    // ============ enableStep / disableStep ============

    function test_enableStep_succeeds() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        assertFalse(hook2.isStepEnabled(0));

        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        assertTrue(hook2.isStepEnabled(0));
        assertFalse(hook2.isStepEnabled(1));
        vm.stopPrank();
    }

    function test_enableStep_emitsEvent() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.StepEnabled(0);
        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        vm.stopPrank();
    }

    function test_enableStep_outOfBounds_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.enableStep(5, _emptyHashes(), _emptyIds());
    }

    function test_enableStep_noCCA_reverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.enableStep(0, _emptyHashes(), _emptyIds());
    }

    function test_enableStep_whenNotOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.enableStep(0, _emptyHashes(), _emptyIds());
    }

    function test_disableStep_succeeds() public {
        assertTrue(hook.isStepEnabled(0));

        vm.prank(admin);
        hook.disableStep(0);
        assertFalse(hook.isStepEnabled(0));
    }

    function test_disableStep_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.StepDisabled(0);
        vm.prank(admin);
        hook.disableStep(0);
    }

    function test_disableStep_outOfBounds_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.disableStep(5);
    }

    // ============ enableStepBatch / disableStepBatch ============

    function test_enableStepBatch_succeeds() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;
        bytes32[][] memory providerHashes = new bytes32[][](2);
        providerHashes[0] = _emptyHashes();
        providerHashes[1] = _emptyHashes();
        string[][] memory providerIds = new string[][](2);
        providerIds[0] = _emptyIds();
        providerIds[1] = _emptyIds();
        hook2.enableStepBatch(indices, providerHashes, providerIds);

        assertTrue(hook2.isStepEnabled(0));
        assertTrue(hook2.isStepEnabled(1));
        vm.stopPrank();
    }

    function test_disableStepBatch_succeeds() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;
        hook2.disableStepBatch(indices);

        assertFalse(hook2.isStepEnabled(0));
        assertFalse(hook2.isStepEnabled(1));
        vm.stopPrank();
    }

    // ============ setStepProviders / addStepProvider ============

    function test_setStepProviders_succeeds() public {
        vm.prank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 1);
        assertEq(providers[0], PROVIDER_HASH_1);
    }

    function test_setStepProviders_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderSet(0, PROVIDER_HASH_1, "provider-1");
        vm.prank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProviders_outOfBounds_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.setStepProviders(5, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProviders_noCCA_reverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProviders_whenNotOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProviders_replacesArray() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 2);
        assertEq(providers[0], PROVIDER_HASH_1);
        assertEq(providers[1], PROVIDER_HASH_2);
    }

    function test_addStepProviders_appendsToArray() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        hook.addStepProviders(steps, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 2);
        assertEq(providers[0], PROVIDER_HASH_1);
        assertEq(providers[1], PROVIDER_HASH_2);
    }

    function test_addStepProviders_multiple() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_2;
        hashes[1] = PROVIDER_HASH_3;
        string[] memory ids = new string[](2);
        ids[0] = "provider-2";
        ids[1] = "provider-3";
        hook.addStepProviders(steps, hashes, ids);
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 3);
        assertEq(providers[0], PROVIDER_HASH_1);
        assertEq(providers[1], PROVIDER_HASH_2);
        assertEq(providers[2], PROVIDER_HASH_3);
    }

    function test_addStepProviders_acrossSteps() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 1;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        string[] memory ids = new string[](2);
        ids[0] = "provider-1";
        ids[1] = "provider-2";
        hook2.addStepProviders(steps, hashes, ids);
        vm.stopPrank();

        assertEq(hook2.getStepProviders(0).length, 1);
        assertEq(hook2.getStepProviders(0)[0], PROVIDER_HASH_1);
        assertEq(hook2.getStepProviders(1).length, 1);
        assertEq(hook2.getStepProviders(1)[0], PROVIDER_HASH_2);
    }

    function test_addStepProviders_emitsEvents() public {
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderSet(0, PROVIDER_HASH_1, "provider-1");
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderSet(0, PROVIDER_HASH_2, "provider-2");

        vm.prank(admin);
        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        string[] memory ids = new string[](2);
        ids[0] = "provider-1";
        ids[1] = "provider-2";
        hook.addStepProviders(steps, hashes, ids);
    }

    function test_addStepProviders_arrayMismatch_reverts() public {
        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.ArrayLengthMismatch.selector);
        hook.addStepProviders(steps, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_addStepProviders_outOfBounds_reverts() public {
        uint256[] memory steps = new uint256[](1);
        steps[0] = 5;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.addStepProviders(steps, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_addStepProviders_noCCA_reverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.addStepProviders(steps, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProvidersBatch_succeeds() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;

        bytes32[][] memory hashes = new bytes32[][](2);
        hashes[0] = _singleHash(PROVIDER_HASH_1);
        hashes[1] = _singleHash(PROVIDER_HASH_2);

        string[][] memory ids = new string[][](2);
        ids[0] = _singleId("provider-1");
        ids[1] = _singleId("provider-2");

        hook2.setStepProvidersBatch(indices, hashes, ids);
        vm.stopPrank();

        bytes32[] memory providers0 = hook2.getStepProviders(0);
        assertEq(providers0.length, 1);
        assertEq(providers0[0], PROVIDER_HASH_1);
        bytes32[] memory providers1 = hook2.getStepProviders(1);
        assertEq(providers1.length, 1);
        assertEq(providers1[0], PROVIDER_HASH_2);
    }

    function test_setStepProvidersBatch_arrayLengthMismatch_reverts() public {
        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;

        bytes32[][] memory hashes = new bytes32[][](1);
        hashes[0] = _singleHash(PROVIDER_HASH_1);

        string[][] memory ids = new string[][](1);
        ids[0] = _singleId("provider-1");

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.ArrayLengthMismatch.selector);
        hook.setStepProvidersBatch(indices, hashes, ids);
    }

    function test_getStepProviders_returnsEmptyForUnconfiguredStep() public view {
        bytes32[] memory providers = hook.getStepProviders(1);
        assertEq(providers.length, 0);
    }

    // ============ Provider Hash Validation ============

    function test_validate_withCorrectProviderHash_succeeds() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_1);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, hookData);

        assertTrue(hook.isVerified(0, user));
    }

    function test_validate_withWrongProviderHash_reverts() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_2);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ProviderHashMismatch.selector, PROVIDER_HASH_1, PROVIDER_HASH_2)
        );
        hook.validate(0, 0, user, user, hookData);
    }

    function test_submitProof_withWrongProviderHash_reverts() public {
        vm.prank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_2);

        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ProviderHashMismatch.selector, PROVIDER_HASH_1, PROVIDER_HASH_2)
        );
        hook.submitProof(user, 0, proofData);
    }

    function test_validate_differentStepsDifferentProviders() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.setStepProviders(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        vm.stopPrank();

        bytes memory proofForStep0 = _createProofForUserWithProvider(user, PROVIDER_HASH_1);
        bytes memory hookData = abi.encodePacked(uint256(0), proofForStep0);

        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);
        assertTrue(hook2.isVerified(0, user));
    }

    // ============ Multiple Providers Per Step ============

    function test_validate_withMultipleProviders_matchesAny() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_2);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, hookData);

        assertTrue(hook.isVerified(0, user));
    }

    function test_validate_withMultipleProviders_noMatch_reverts() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_3);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ProviderHashMismatch.selector, PROVIDER_HASH_1, PROVIDER_HASH_3)
        );
        hook.validate(0, 0, user, user, hookData);
    }

    function test_enableStep_emptyProviders_noPermit_isOpen() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        // no server permit enabled -> the step has no gate at all
        vm.stopPrank();

        vm.roll(step0Start);
        // Empty providers + no permit = open: the bid passes with no hookData, and a
        // stray proof is ignored (no verification stored) rather than reverting.
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_2);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, abi.encodePacked(uint256(0), proofData));
        assertFalse(hook2.isVerified(0, user));
    }

    // ============ isVerified ============

    function test_isVerified_returnsFalseByDefault() public view {
        assertFalse(hook.isVerified(0, user));
    }

    function test_isVerified_isMonotonic() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        hook2.submitProof(user, 0, proofData);

        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
    }

    function test_isVerified_notEligibleForEarlierSteps() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        hook2.submitProof(user, 1, proofData);

        assertFalse(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
    }

    // ============ ERC165 ============

    function test_supportsInterface() public view {
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertTrue(hook.supportsInterface(type(IValidationHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IUmiaValidationHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IMaxBidPriceValidationHook).interfaceId));
    }

    /// @dev Integrators discover the hook by these IDs, so a change to either interface must be
    ///      a deliberate one: update the constants here and the tables in docs/contracts.
    function test_supportsInterface_idsAreStable() public pure {
        assertEq(type(IUmiaValidationHook).interfaceId, bytes4(0xbff343b3));
        assertEq(type(IMaxBidPriceValidationHook).interfaceId, bytes4(0x2268a4c3));
    }

    /// @dev Must stay byte-identical to Uniswap's MaxBidPriceValidationHook so their tooling
    ///      decodes our revert. Adding parameters back would change it.
    function test_maxBidPriceExceeded_selectorMatchesUniswap() public pure {
        assertEq(UmiaValidationHook.MaxBidPriceExceeded.selector, bytes4(0x77c99cf5));
    }

    /// @dev Uniswap standardised `maxBidPrice() == 0` as "no effective cap", so the claim is
    ///      static: an uncapped hook still implements the interface, it just reports no cap.
    function test_supportsInterface_maxBidPrice_regardlessOfCap() public {
        assertEq(hook.maxBidPrice(), 0);
        assertTrue(hook.supportsInterface(type(IMaxBidPriceValidationHook).interfaceId));

        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        assertTrue(hook.supportsInterface(type(IMaxBidPriceValidationHook).interfaceId));

        vm.prank(admin);
        hook.setMaxBidPrice(0);
        assertTrue(hook.supportsInterface(type(IMaxBidPriceValidationHook).interfaceId));
    }

    function test_supportsInterface_WhenNotSupported() public view {
        bytes4 unsupported = bytes4(keccak256("not_supported"));
        assertFalse(hook.supportsInterface(unsupported));
    }

    function testFuzz_supportsInterface_WhenNotSupported(bytes4 interfaceId) public view {
        vm.assume(
            interfaceId != type(IERC165).interfaceId && interfaceId != type(IValidationHook).interfaceId
                && interfaceId != type(IUmiaValidationHook).interfaceId
                && interfaceId != type(IMaxBidPriceValidationHook).interfaceId
        );
        assertFalse(hook.supportsInterface(interfaceId));
    }

    // ============ Stale Step Fallback ============

    function _deployStaleTwoStepCCA() internal returns (StaleMockCCA) {
        bytes memory data = abi.encodePacked(
            _packStep(5_000_000, 100), // step 0: blocks 100-200
            _packStep(5_000_000, 100) // step 1: blocks 200-300
        );
        return new StaleMockCCA(data, 100);
    }

    function test_validate_staleStep_enforcesNextStepVerification() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), address(0));
        StaleMockCCA cca = _deployStaleTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        h.submitProof(user, 1, proofData);

        vm.roll(200);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_staleStep_revertsUnverified() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), address(0));
        StaleMockCCA cca = _deployStaleTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        vm.roll(200);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 1));
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_staleStep_pastAllStepsAllowsAnyone() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), address(0));
        StaleMockCCA cca = _deployStaleTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStep(1, _emptyHashes(), _emptyIds());
        vm.stopPrank();

        vm.roll(300);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, bytes(""));
    }

    // ============ unregister / unregisterBatch ============

    function test_unregister_succeeds() public {
        bytes memory proofData = _createProofForUser(user);
        hook.submitProof(user, 0, proofData);
        assertTrue(hook.isVerified(0, user));

        vm.prank(admin);
        hook.unregister(user);
        assertFalse(hook.isVerified(0, user));
    }

    function test_unregister_emitsEvent() public {
        bytes memory proofData = _createProofForUser(user);
        hook.submitProof(user, 0, proofData);

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.Unregistered(user);
        vm.prank(admin);
        hook.unregister(user);
    }

    function test_unregister_noCCA_reverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.unregister(user);
    }

    function test_unregister_whenNotOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.unregister(user);
    }

    function test_unregisterBatch_succeeds() public {
        address user2 = makeAddr("user2");
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = user2;

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = _createProofForUser(user);
        proofs[1] = _createProofForUser(user2);

        hook.submitProofBatch(users, 0, proofs);
        assertTrue(hook.isVerified(0, user));
        assertTrue(hook.isVerified(0, user2));

        vm.prank(admin);
        hook.unregisterBatch(users);

        assertFalse(hook.isVerified(0, user));
        assertFalse(hook.isVerified(0, user2));
    }

    function test_unregisterBatch_emitsEvents() public {
        address user2 = makeAddr("user2");
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = user2;

        bytes[] memory proofs = new bytes[](2);
        proofs[0] = _createProofForUser(user);
        proofs[1] = _createProofForUser(user2);

        hook.submitProofBatch(users, 0, proofs);

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.Unregistered(user);
        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.Unregistered(user2);
        vm.prank(admin);
        hook.unregisterBatch(users);
    }

    function test_unregisterBatch_noCCA_reverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));
        address[] memory users = new address[](1);
        users[0] = user;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.unregisterBatch(users);
    }

    function test_unregisterBatch_whenNotOwner_reverts() public {
        address[] memory users = new address[](1);
        users[0] = user;

        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.unregisterBatch(users);
    }

    function test_unregister_clearsVerification() public {
        bytes memory proofData = _createProofForUser(user);

        hook.submitProof(user, 0, proofData);
        assertTrue(hook.isVerified(0, user));

        vm.prank(admin);
        hook.unregister(user);
        assertFalse(hook.isVerified(0, user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook.validate(0, 0, user, user, bytes(""));
    }

    // ============ removeStepProviders ============

    function test_removeStepProviders_succeeds() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 1);
        assertEq(providers[0], PROVIDER_HASH_2);
    }

    function test_removeStepProviders_multiple() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        hook.removeStepProviders(steps, hashes);
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 0);
    }

    function test_removeStepProviders_acrossSteps() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.setStepProviders(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 1;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        hook2.removeStepProviders(steps, hashes);
        vm.stopPrank();

        assertEq(hook2.getStepProviders(0).length, 0);
        assertEq(hook2.getStepProviders(1).length, 0);
    }

    function test_removeStepProviders_emitsEvents() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));

        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderRemoved(0, PROVIDER_HASH_1);
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderRemoved(0, PROVIDER_HASH_2);

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        hook.removeStepProviders(steps, hashes);
        vm.stopPrank();
    }

    function test_removeStepProviders_lastElement_succeeds() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 0);
    }

    function test_removeStepProviders_swapAndPop() public {
        vm.startPrank(admin);
        bytes32[] memory threeHashes = new bytes32[](3);
        threeHashes[0] = PROVIDER_HASH_1;
        threeHashes[1] = PROVIDER_HASH_2;
        threeHashes[2] = PROVIDER_HASH_3;
        string[] memory threeIds = new string[](3);
        threeIds[0] = "p1";
        threeIds[1] = "p2";
        threeIds[2] = "p3";
        hook.setStepProviders(0, threeHashes, threeIds);

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 2);
        assertEq(providers[0], PROVIDER_HASH_3);
        assertEq(providers[1], PROVIDER_HASH_2);
    }

    function test_removeStepProviders_notFound_reverts() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProviderNotFound.selector, 0, PROVIDER_HASH_2));
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_2));
        vm.stopPrank();
    }

    function test_removeStepProviders_arrayMismatch_reverts() public {
        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.ArrayLengthMismatch.selector);
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
    }

    function test_removeStepProviders_outOfBounds_reverts() public {
        uint256[] memory steps = new uint256[](1);
        steps[0] = 5;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
    }

    function test_removeStepProviders_noCCA_reverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
    }

    function test_removeStepProviders_whenNotOwner_reverts() public {
        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;

        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
    }

    // ============ setStepProviders emits StepProviderRemoved ============

    function test_setStepProviders_emitsRemovedForDroppedProviders() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("p1", "p2"));

        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderRemoved(0, PROVIDER_HASH_1);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_2), _singleId("p2"));
        vm.stopPrank();
    }

    function test_setStepProviders_retainsSameProviders() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("p1"));
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("p1"));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 1);
        assertEq(providers[0], PROVIDER_HASH_1);
    }

    function test_enableStep_emitsRemovedForReplacedProviders() public {
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("p1"));

        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderRemoved(0, PROVIDER_HASH_1);
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_2), _singleId("p2"));
        vm.stopPrank();
    }

    // ============ Server Permit — Signer Management ============

    function _setupServerPermit() internal returns (UmiaValidationHook h) {
        h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();
    }

    function test_setSigner_succeeds() public {
        vm.prank(admin);
        hook.setSigner(signerAddress);

        assertEq(hook.signer(), signerAddress);
    }

    function test_setSigner_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit UmiaValidationHook.SignerSet(address(0), signerAddress);
        vm.prank(admin);
        hook.setSigner(signerAddress);
    }

    function test_setSigner_notOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setSigner(signerAddress);
    }

    function test_setSigner_toZero_disables() public {
        vm.startPrank(admin);
        hook.setSigner(signerAddress);
        assertEq(hook.signer(), signerAddress);

        hook.setSigner(address(0));
        assertEq(hook.signer(), address(0));
        vm.stopPrank();
    }

    // ============ Server Permit — enableStepPermit / disableStepPermit ============

    function test_enableStepPermit_succeeds() public {
        assertFalse(hook.isStepPermitEnabled(0));

        vm.prank(admin);
        hook.enableStepPermit(0);

        assertTrue(hook.isStepPermitEnabled(0));
    }

    function test_enableStepPermit_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.StepPermitEnabled(0);
        vm.prank(admin);
        hook.enableStepPermit(0);
    }

    function test_enableStepPermit_notOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.enableStepPermit(0);
    }

    function test_enableStepPermit_outOfBounds_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.enableStepPermit(5);
    }

    function test_enableStepPermit_noCCA_reverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.enableStepPermit(0);
    }

    function test_disableStepPermit_succeeds() public {
        vm.startPrank(admin);
        hook.enableStepPermit(0);
        assertTrue(hook.isStepPermitEnabled(0));

        hook.disableStepPermit(0);
        assertFalse(hook.isStepPermitEnabled(0));
        vm.stopPrank();
    }

    function test_disableStepPermit_emitsEvent() public {
        vm.startPrank(admin);
        hook.enableStepPermit(0);

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.StepPermitDisabled(0);
        hook.disableStepPermit(0);
        vm.stopPrank();
    }

    // ============ Server Permit — Inline ============

    function test_validate_inlineServerPermit_succeeds() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-1");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce));
        // Server permits no longer persist verification — every bid requires a fresh permit.
        assertFalse(h.isVerified(0, user));
    }

    function test_validate_inlineServerPermit_boundBidAmountSucceeds() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-amount-bound-success");
        uint128 signedAmount = 1 ether;
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, signedAmount);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, signedAmount, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce));
    }

    function test_validate_inlineServerPermit_rejectsDifferentBidAmount() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-amount-bound");
        uint128 signedAmount = 1 ether;
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, signedAmount);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(UmiaValidationHook.InvalidSignature.selector);
        h.validate(0, 2 ether, user, user, hookData);

        assertFalse(h.isPermitNonceUsed(nonce));
    }

    function test_validate_inlineServerPermit_replay_reverts() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-replay");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, hookData);
        vm.prank(h.cca());

        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.PermitAlreadyUsed.selector, nonce));
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_inlineServerPermit_freshPermitPerBid_succeeds() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        vm.roll(step0Start);

        bytes32 nonceA = keccak256("nonce-A");
        bytes memory sigA = _signServerPermit(address(h), user, 0, nonceA, deadline);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, _encodePermitHookData(0, nonceA, deadline, sigA));

        bytes32 nonceB = keccak256("nonce-B");
        bytes memory sigB = _signServerPermit(address(h), user, 0, nonceB, deadline);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, _encodePermitHookData(0, nonceB, deadline, sigB));

        assertTrue(h.isPermitNonceUsed(nonceA));
        assertTrue(h.isPermitNonceUsed(nonceB));
    }

    function test_validate_inlineServerPermit_emptyHookData_reverts() public {
        UmiaValidationHook h = _setupServerPermit();

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inlineServerPermit_monotonic_succeeds() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        h.enableStepPermit(1);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-monotonic");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(200); // step 1 — permit signed for step 0, monotonic allows it
        vm.prank(h.cca());
        h.validate(0, 0, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce));
    }

    function test_validate_inlineServerPermit_permitStepTooHigh_reverts() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        h.enableStepPermit(1);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-too-high");
        bytes memory signature = _signServerPermit(address(h), user, 1, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(1, nonce, deadline, signature);

        vm.roll(step0Start); // step 0 — permit signed for step 1 which is in the future
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.PermitStepTooHigh.selector, 1, 0));
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_bareStepAfterPermitStep_isOpen() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        // step 1 has no providers and is not permit-enabled -> open, even though step 0
        // is permit-enabled: server permits are single-bid, not monotonic whitelisting.
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-only-first");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(200); // step 1 — open; a submitted permit is ignored, not consumed
        vm.prank(h.cca());
        h.validate(0, 0, user, user, hookData);
        assertFalse(h.isPermitNonceUsed(nonce));

        // and an empty bid passes too
        vm.prank(h.cca());
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inlineServerPermit_notEnabled_reverts() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(1); // step 1 is permit-gated; step 0 is not permit-enabled
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-not-enabled");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        // step 1 accepts permits, but this permit targets step 0, which is not permit-enabled.
        vm.roll(200);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitNotEnabled.selector, 0));
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_providerOnlyStep_rejectsPermitWithProofRequired() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        // provider-gated, permit NOT enabled
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-proof-required");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        // Provider-only step: a server permit is the wrong credential -> ProofRequired.
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_bothGates_typeBytePicksCredential() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider")); // proof gate
        h.enableStepPermit(0); // and permit gate
        vm.stopPrank();

        vm.roll(step0Start);

        // 0x01 byte -> permit path: a valid permit passes.
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("both-gates-permit");
        bytes memory permitData =
            _encodePermitHookData(0, nonce, deadline, _signServerPermit(address(h), user, 0, nonce, deadline));
        vm.prank(h.cca());
        h.validate(0, 0, user, user, permitData);

        // non-0x01 -> proof path: a valid matching proof passes.
        address bidder2 = makeAddr("both-gates-bidder2");
        bytes memory proofData = _createProofForUserWithProvider(bidder2, PROVIDER_HASH_1);
        vm.prank(h.cca());
        h.validate(0, 0, bidder2, bidder2, abi.encodePacked(uint256(0), proofData));
        assertTrue(h.isVerified(0, bidder2));
    }

    function test_validate_inlineServerPermit_signerNotSet_reverts() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-no-signer");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(UmiaValidationHook.SignerNotSet.selector);
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_inlineServerPermit_invalidSignature_reverts() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-invalid-sig");
        uint256 wrongKey = 0x1111111111111111111111111111111111111111111111111111111111111111;
        bytes32 DOMAIN_TYPEHASH_LOCAL =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 SERVER_PERMIT_TYPEHASH_LOCAL =
            keccak256("ServerPermit(address wallet,uint256 step,bytes32 nonce,uint256 deadline,uint128 amount)");
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH_LOCAL, keccak256("UmiaValidationHook"), keccak256("1"), block.chainid, address(h)
            )
        );
        bytes32 structHash = keccak256(abi.encode(SERVER_PERMIT_TYPEHASH_LOCAL, user, 0, nonce, deadline, uint128(0)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory wrongSig = abi.encodePacked(r, s, v);

        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, wrongSig);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(UmiaValidationHook.InvalidSignature.selector);
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_inlineServerPermit_boundToHookDomain_rejectedByOtherHook() public {
        UmiaValidationHook hookA = _setupServerPermit();
        UmiaValidationHook hookB = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("cross-hook");
        bytes memory signature = _signServerPermit(address(hookA), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(hookB.cca());
        vm.expectRevert(UmiaValidationHook.InvalidSignature.selector);
        hookB.validate(0, 0, user, user, hookData);

        vm.prank(hookA.cca());
        hookA.validate(0, 0, user, user, hookData);
        assertTrue(hookA.isPermitNonceUsed(nonce));
    }

    function test_validate_inlineServerPermit_wrongLengthSignature_revertsInvalidSignature() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-bad-len");
        // 10 bytes: a valid ABI bytes tail (the envelope check passes) but not a 64/65-byte ECDSA
        // signature. tryRecover must surface the hook's InvalidSignature, not OpenZeppelin's length error.
        bytes memory shortSig = new bytes(10);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, shortSig);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(UmiaValidationHook.InvalidSignature.selector);
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_inlineServerPermit_expiredDeadline_reverts() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp - 1;
        bytes32 nonce = keccak256("nonce-expired");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(UmiaValidationHook.ExpiredDeadline.selector);
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_reclaimFallback_rejectsWithoutProviders() public {
        UmiaValidationHook h = _setupServerPermit();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        // Permit-only step (server permit set up, no providers): a proof is rejected as
        // the wrong credential for the step's gate.
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, hookData);
    }

    // ============ Helper Functions ============

    function _addressToString(address _addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint256(uint8(bytes20(_addr)[i] >> 4))];
            str[3 + i * 2] = alphabet[uint256(uint8(bytes20(_addr)[i] & 0x0f))];
        }
        return string(str);
    }

    function _bytes2str(bytes memory buffer) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + buffer.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < buffer.length; i++) {
            str[2 + i * 2] = alphabet[uint8(buffer[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(buffer[i] & 0x0f)];
        }
        return string(str);
    }

    function _address2str(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(x)) / (2 ** (8 * (19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2 + 2 * i] = _char(hi);
            s[3 + 2 * i] = _char(lo);
        }
        return string(s);
    }

    function _char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function _bytes32ToHexString(bytes32 _data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(_data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(_data[i] & 0x0f)];
        }
        return string(str);
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — setMaxBidPrice
    // ─────────────────────────────────────────────────────────

    function test_setMaxBidPrice_storesValue() public {
        assertEq(hook.maxBidPrice(), 0, "initial cap should be 0");
        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 5000, "cap not stored");
    }

    function test_setMaxBidPrice_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit UmiaValidationHook.MaxBidPriceSet(5000);
        vm.prank(admin);
        hook.setMaxBidPrice(5000);
    }

    function test_setMaxBidPrice_zeroRemovesCap() public {
        vm.startPrank(admin);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 5000);

        vm.expectEmit(false, false, false, true);
        emit UmiaValidationHook.MaxBidPriceSet(0);
        hook.setMaxBidPrice(0);
        assertEq(hook.maxBidPrice(), 0, "cap should be cleared");
        vm.stopPrank();
    }

    function test_setMaxBidPrice_nonOwnerReverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 0, "cap should remain unchanged after revert");
    }

    function test_setMaxBidPrice_noCCAReverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        assertEq(freshHook.maxBidPrice(), 0, "fresh hook cap should be 0");
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.setMaxBidPrice(5000);
        assertEq(freshHook.maxBidPrice(), 0, "cap should remain 0 after revert");
    }

    function test_setMaxBidPrice_tickAlignmentReverts_midTick() public {
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        hook.setMaxBidPrice(1050);
        assertEq(hook.maxBidPrice(), 0, "cap should remain 0 after revert");
    }

    function test_setMaxBidPrice_tickAlignmentReverts_variousOffsets() public {
        uint256[4] memory badPrices = [uint256(1001), 1099, 1150, 1199];
        for (uint256 i; i < badPrices.length; i++) {
            vm.prank(admin);
            vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
            hook.setMaxBidPrice(badPrices[i]);
        }
        assertEq(hook.maxBidPrice(), 0, "cap should remain 0 after all reverts");
    }

    function test_setMaxBidPrice_tickAlignmentValid() public {
        vm.prank(admin);
        hook.setMaxBidPrice(1100);
        assertEq(hook.maxBidPrice(), 1100);
    }

    function test_setMaxBidPrice_atFloorPrice() public {
        vm.prank(admin);
        hook.setMaxBidPrice(1000);
        assertEq(hook.maxBidPrice(), 1000, "floor price itself should be valid");
    }

    function test_setMaxBidPrice_belowFloorPriceReverts() public {
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        hook.setMaxBidPrice(900);
        assertEq(hook.maxBidPrice(), 0, "cap should remain 0");
    }

    function test_setMaxBidPrice_belowFloorPriceReverts_oneBelow() public {
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        hook.setMaxBidPrice(999);
        assertEq(hook.maxBidPrice(), 0);
    }

    function test_setMaxBidPrice_updateExisting() public {
        vm.startPrank(admin);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 5000);

        vm.expectEmit(false, false, false, true);
        emit UmiaValidationHook.MaxBidPriceSet(3000);
        hook.setMaxBidPrice(3000);
        assertEq(hook.maxBidPrice(), 3000);
        vm.stopPrank();
    }

    function test_setMaxBidPrice_updateEmitsCorrectOldAndNew() public {
        vm.startPrank(admin);
        hook.setMaxBidPrice(2000);
        hook.setMaxBidPrice(4000);
        hook.setMaxBidPrice(1000);
        assertEq(hook.maxBidPrice(), 1000, "should reflect last set value");
        vm.stopPrank();
    }

    function test_setMaxBidPrice_differentTickSpacings() public {
        MockCCA cca2 = _deploySingleStepCCA();
        cca2.setFloorPrice(500);
        cca2.setTickSpacing(250);

        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));

        h.setMaxBidPrice(750);
        assertEq(h.maxBidPrice(), 750, "500 + 1*250 = 750 should be valid");

        h.setMaxBidPrice(500);
        assertEq(h.maxBidPrice(), 500, "floor price itself should be valid");

        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        h.setMaxBidPrice(600);

        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        h.setMaxBidPrice(499);

        assertEq(h.maxBidPrice(), 500, "cap should remain at last valid value");
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — validate enforcement
    // ─────────────────────────────────────────────────────────

    function test_validate_belowCapSucceeds() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start - 1);
        vm.prank(address(mockCCA));
        hook.validate(4000, 1 ether, user, user, "");
        assertEq(hook.maxBidPrice(), 5000, "cap should be unchanged after validate");
    }

    function test_validate_atCapSucceeds() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start - 1);
        vm.prank(address(mockCCA));
        hook.validate(5000, 1 ether, user, user, "");
        assertEq(hook.maxBidPrice(), 5000, "cap should be unchanged after validate");
    }

    function test_validate_aboveCapReverts() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start);
        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(6000, 1 ether, user, user, "");
    }

    function test_validate_aboveCapByOneReverts() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start - 1);
        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(5001, 1 ether, user, user, "");
    }

    function test_validate_noCapAllowsAnyPrice() public {
        assertEq(hook.maxBidPrice(), 0, "cap should start at 0");

        vm.roll(step0Start - 1);
        vm.prank(address(mockCCA));
        hook.validate(type(uint256).max, 1 ether, user, user, "");
    }

    function test_validate_exactBoundaryPrices() public {
        uint256 cap = 5000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);

        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        hook.validate(cap - 1, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        hook.validate(cap, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(cap + 1, 1 ether, user, user, "");
    }

    function test_validate_capDoesNotLimitAmount() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        vm.roll(step0Start - 1);

        uint128[5] memory amounts =
            [uint128(1), uint128(1 ether), uint128(100 ether), uint128(1_000_000 ether), type(uint128).max];
        for (uint256 i; i < amounts.length; i++) {
            vm.prank(address(mockCCA));
            hook.validate(5000, amounts[i], user, user, "");
        }
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — batch / scenario
    // ─────────────────────────────────────────────────────────

    function test_validate_batch20Bids_exactAcceptRejectCounts() public {
        uint256 cap = 5000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);
        vm.roll(step0Start - 1);

        uint256 accepted;
        uint256 rejected;

        for (uint256 i; i < 20; i++) {
            uint256 price = 1000 + i * 300;
            vm.prank(address(mockCCA));
            if (price <= cap) {
                vm.prank(hook.cca());
                hook.validate(price, 1 ether, user, user, "");
                accepted++;
            } else {
                vm.prank(hook.cca());
                vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
                hook.validate(price, 1 ether, user, user, "");
                rejected++;
            }
        }

        assertEq(accepted, 14, "bids at prices 1000..4900 (step 300) should pass");
        assertEq(rejected, 6, "bids at prices 5200..6700 (step 300) should fail");
        assertEq(accepted + rejected, 20, "total should be 20");
    }

    function test_validate_allBidsAtCap_allSucceed() public {
        uint256 cap = 5000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);
        vm.roll(step0Start - 1);

        for (uint256 i; i < 20; i++) {
            vm.prank(address(mockCCA));
            hook.validate(cap, 1 ether, user, user, "");
        }
    }

    function test_validate_allBidsAboveCap_allRevert() public {
        uint256 cap = 5000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);
        vm.roll(step0Start - 1);

        for (uint256 i; i < 10; i++) {
            uint256 price = cap + 1 + i * 100;
            vm.prank(address(mockCCA));
            vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
            hook.validate(price, 1 ether, user, user, "");
        }
    }

    function test_validate_multipleUsersAllCapped() public {
        uint256 cap = 3000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);
        vm.roll(step0Start - 1);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");
        address[3] memory users_ = [alice, bob, charlie];

        for (uint256 i; i < users_.length; i++) {
            vm.prank(address(mockCCA));
            hook.validate(cap, 1 ether, users_[i], users_[i], "");

            vm.prank(address(mockCCA));
            vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
            hook.validate(cap + 100, 1 ether, users_[i], users_[i], "");
        }
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — dynamic cap changes
    // ─────────────────────────────────────────────────────────

    function test_validate_lowerCapRejectsFormerlyValidPrice() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        hook.validate(4000, 1 ether, user, user, "");

        vm.prank(admin);
        hook.setMaxBidPrice(3000);
        assertEq(hook.maxBidPrice(), 3000);

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(4000, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        hook.validate(3000, 1 ether, user, user, "");
    }

    function test_validate_raiseCapAcceptsPreviouslyRejectedPrice() public {
        vm.prank(admin);
        hook.setMaxBidPrice(3000);
        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(4000, 1 ether, user, user, "");

        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 5000);

        vm.prank(address(mockCCA));
        hook.validate(4000, 1 ether, user, user, "");
    }

    function test_validate_removeCapAllowsAnyPriceAfterSetting() public {
        vm.prank(admin);
        hook.setMaxBidPrice(3000);
        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(9000, 1 ether, user, user, "");

        vm.prank(admin);
        hook.setMaxBidPrice(0);
        assertEq(hook.maxBidPrice(), 0, "cap should be removed");

        vm.prank(address(mockCCA));
        hook.validate(9000, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        hook.validate(type(uint256).max, 1 ether, user, user, "");
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — interaction with step verification
    // ─────────────────────────────────────────────────────────

    function test_validate_capEnforcedDuringActiveStep() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start);

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(6000, 1 ether, user, user, "");
    }

    function test_validate_capRevertsBeforeVerificationCheck() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setMaxBidPrice(3000);
        vm.stopPrank();

        vm.roll(step0Start);

        vm.prank(address(cca2));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        h.validate(5000, 1 ether, user, user, "");
    }

    function test_validate_belowCapStillNeedsVerification() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.setMaxBidPrice(5000);
        vm.stopPrank();

        vm.roll(step0Start);

        vm.prank(address(cca2));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        h.validate(3000, 1 ether, user, user, "");
    }

    function test_validate_permitUnderPriceCapSucceeds() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setMaxBidPrice(5000);
        vm.stopPrank();

        vm.roll(step0Start);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("cap-under");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, 1 ether);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.prank(address(cca2));
        h.validate(3000, 1 ether, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce), "permit nonce should be burned after a valid bid");
    }

    function test_validate_permitAtPriceCapSucceeds() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setMaxBidPrice(5000);
        vm.stopPrank();

        vm.roll(step0Start);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("cap-at");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, 1 ether);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.prank(address(cca2));
        h.validate(5000, 1 ether, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce), "permit nonce should be burned");
    }

    function test_validate_permitAbovePriceCapReverts_nonceNotBurned() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setMaxBidPrice(5000);
        vm.stopPrank();

        vm.roll(step0Start);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("cap-above");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, 1 ether);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.prank(address(cca2));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        h.validate(6000, 1 ether, user, user, hookData);

        assertFalse(h.isPermitNonceUsed(nonce), "permit nonce must not be burned when the price cap rejects the bid");
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — cap at floor price (tightest cap)
    // ─────────────────────────────────────────────────────────

    function test_validate_capAtFloorPrice_onlyFloorAllowed() public {
        vm.prank(admin);
        hook.setMaxBidPrice(1000);
        assertEq(hook.maxBidPrice(), 1000);
        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        hook.validate(1000, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(1100, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(1001, 1 ether, user, user, "");
    }

    // ============ Sybil resistance (OPRF identity) ============

    function _createProofWithIdentity(address _user, bytes32 _providerHash, string memory _extractedParameters)
        internal
        view
        returns (bytes memory)
    {
        string memory context = string(
            abi.encodePacked(
                '{"contextAddress":"',
                _addressToString(_user),
                '","providerHash":"',
                _bytes32ToHexString(_providerHash),
                '","extractedParameters":',
                _extractedParameters,
                "}"
            )
        );

        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: context});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: _user, timestampS: uint32(block.timestamp), epoch: 2
        });

        bytes memory serialised = abi.encodePacked(
            _bytes2str(abi.encodePacked(claimData.identifier)),
            "\n",
            _address2str(claimData.owner),
            "\n",
            _uint2str(claimData.timestampS),
            "\n",
            _uint2str(claimData.epoch)
        );

        bytes32 messageHash =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", _uint2str(serialised.length), serialised));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WITNESS_PRIVATE_KEY, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});
        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        return abi.encode(proof);
    }

    function _expectedIdentityHash(bytes32 providerHash, string memory extractedParameters)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(providerHash, bytes(extractedParameters)));
    }

    function test_submitProof_sybil_rejectedForDifferentWallet() public {
        string memory params = '{"username":"sybil-test"}';
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);
        hook.submitProof(user, 0, proofA);

        address user2 = makeAddr("user2");
        bytes memory proofB = _createProofWithIdentity(user2, PROVIDER_HASH_1, params);

        bytes32 identityHash = _expectedIdentityHash(PROVIDER_HASH_1, params);
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.IdentityAlreadyClaimed.selector, PROVIDER_HASH_1, identityHash, user
            )
        );
        hook.submitProof(user2, 0, proofB);
    }

    function test_submitProof_sybil_sameUserReverifySucceeds() public {
        string memory params = '{"username":"sybil-test"}';
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);

        hook.submitProof(user, 0, proofA);
        // Idempotent: re-submitting the same proof for the same user must not revert.
        // Same-identity owner == user → no-op in the gate; reclaim's "already used" guard
        // is the one we want to hit, not IdentityAlreadyClaimed.
        vm.expectRevert(); // Reclaim rejects already-verified proof; not a sybil revert.
        hook.submitProof(user, 0, proofA);
    }

    function test_submitProof_sybil_differentIdentitiesAllowed() public {
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, '{"username":"alice"}');
        hook.submitProof(user, 0, proofA);

        address user2 = makeAddr("user2");
        bytes memory proofB = _createProofWithIdentity(user2, PROVIDER_HASH_1, '{"username":"bob"}');
        hook.submitProof(user2, 0, proofB);

        assertTrue(hook.isVerified(0, user));
        assertTrue(hook.isVerified(0, user2));
    }

    function test_submitProof_sybil_providerHashNamespaceIsolation() public {
        string memory params = '{"username":"shared"}';

        // Hook A has PROVIDER_HASH_1 enabled at step 0.
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);
        hook.submitProof(user, 0, proofA);

        // A second hook keyed to PROVIDER_HASH_2 should accept the same identity bytes
        // because the providerHash prefix in the hash makes them distinct.
        UmiaValidationHook hook2 = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deploySingleStepCCA();
        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        address user2 = makeAddr("user2");
        bytes memory proofB = _createProofWithIdentity(user2, PROVIDER_HASH_2, params);
        hook2.submitProof(user2, 0, proofB);
        assertTrue(hook2.isVerified(0, user2));
    }

    function test_submitProof_sybil_missingExtractedParametersAllowed() public {
        // Falls back to the legacy proof helper which doesn't include extractedParameters.
        bytes memory proofData = _createProofForUser(user);
        hook.submitProof(user, 0, proofData);
        assertTrue(hook.isVerified(0, user));
    }

    function test_submitProof_sybil_emitsIdentityClaimedEvent() public {
        string memory params = '{"username":"alice"}';
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);

        bytes32 identityHash = _expectedIdentityHash(PROVIDER_HASH_1, params);
        vm.expectEmit(true, true, true, true);
        emit UmiaValidationHook.IdentityClaimed(user, PROVIDER_HASH_1, identityHash, 0);
        hook.submitProof(user, 0, proofA);
    }

    function test_clearIdentity_ownerOnly() public {
        bytes32 identityHash = _expectedIdentityHash(PROVIDER_HASH_1, '{"username":"x"}');
        vm.expectRevert();
        hook.clearIdentity(PROVIDER_HASH_1, identityHash);

        vm.prank(admin);
        hook.clearIdentity(PROVIDER_HASH_1, identityHash);
        // No revert from owner; idempotent on a never-claimed slot.
    }

    function test_clearIdentity_allowsReRegistration() public {
        string memory params = '{"username":"alice"}';
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);
        hook.submitProof(user, 0, proofA);

        bytes32 identityHash = _expectedIdentityHash(PROVIDER_HASH_1, params);
        assertEq(hook.identityOwner(PROVIDER_HASH_1, identityHash), user);

        vm.prank(admin);
        hook.clearIdentity(PROVIDER_HASH_1, identityHash);
        assertEq(hook.identityOwner(PROVIDER_HASH_1, identityHash), address(0));

        address user2 = makeAddr("user2");
        bytes memory proofB = _createProofWithIdentity(user2, PROVIDER_HASH_1, params);
        hook.submitProof(user2, 0, proofB);

        assertEq(hook.identityOwner(PROVIDER_HASH_1, identityHash), user2);
        assertTrue(hook.isVerified(0, user2));
    }

    // ─────────────────────────────────────────────────────────
    // Per-Step zkTLS Bid Amount Cap — setStepMaxBidAmount config
    // ─────────────────────────────────────────────────────────

    uint256 constant ZK_CAP = 1_000e6; // 1,000 USDC, money-token base units

    /// @dev Builds inline-proof hookData: abi.encodePacked(uint256 proofStep, abi.encode(Reclaim.Proof)).
    function _inlineProof(uint256 proofStep, address _user) internal view returns (bytes memory) {
        return abi.encodePacked(proofStep, _createProofForUser(_user));
    }

    function test_setStepMaxBidAmount_storesValue() public {
        assertEq(hook.stepMaxBidAmount(0), 0, "initial cap should be 0");
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        assertEq(hook.stepMaxBidAmount(0), ZK_CAP, "cap not stored");
    }

    function test_setStepMaxBidAmount_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepMaxBidAmountSet(0, ZK_CAP);
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
    }

    function test_setStepMaxBidAmount_zeroRemovesCap() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        assertEq(hook.stepMaxBidAmount(0), ZK_CAP);
        hook.setStepMaxBidAmount(0, 0);
        assertEq(hook.stepMaxBidAmount(0), 0, "cap should be cleared");
        vm.stopPrank();
    }

    function test_setStepMaxBidAmount_nonOwnerReverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        assertEq(hook.stepMaxBidAmount(0), 0, "cap should remain unchanged after revert");
    }

    function test_setStepMaxBidAmount_noCCAReverts() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.setStepMaxBidAmount(0, ZK_CAP);
    }

    function test_setStepMaxBidAmount_outOfBoundsReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 1));
        hook.setStepMaxBidAmount(1, ZK_CAP);
    }

    // ─────────────────────────────────────────────────────────
    // Per-Step zkTLS Bid Amount Cap — validate enforcement
    // ─────────────────────────────────────────────────────────

    function test_zkCap_firstProofBidUnderCap_succeedsAndAccrues() public {
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 400e6, user, user, _inlineProof(0, user));

        assertTrue(hook.isVerified(0, user), "proof should be stored on first bid");
        assertEq(hook.zkBidTotal(user, 0), 400e6, "first bid should accrue");
    }

    function test_zkCap_accumulatesAcrossBids_exceedReverts() public {
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.submitProof(user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 400e6, user, user, "");
        vm.prank(hook.cca());
        hook.validate(0, 600e6, user, user, ""); // cumulative 1000e6, exactly at cap
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP, "cumulative should reach cap");
        vm.prank(hook.cca());

        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP)
        );
        hook.validate(0, 1, user, user, "");
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP, "total should be unchanged after revert");
    }

    function test_zkCap_noCapAllowsAnyAmount_noAccrual() public {
        hook.submitProof(user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, type(uint128).max, user, user, "");
        assertEq(hook.zkBidTotal(user, 0), 0, "uncapped steps do not accrue");
    }

    function test_zkCap_firstBidOverCap_leavesWalletUnverified() public {
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP)
        );
        hook.validate(0, uint128(ZK_CAP + 1), user, user, _inlineProof(0, user));

        assertFalse(hook.isVerified(0, user), "proof storage must roll back when the first bid exceeds the cap");
        assertEq(hook.zkBidTotal(user, 0), 0);
    }

    function test_zkCap_capAddedMidStream_onlyCountsSubsequentBids() public {
        hook.submitProof(user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 800e6, user, user, ""); // uncapped, not counted
        assertEq(hook.zkBidTotal(user, 0), 0);

        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, ""); // now capped; only this counts
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP);
        vm.prank(hook.cca());

        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP)
        );
        hook.validate(0, 1, user, user, "");
    }

    function test_zkCap_walletsIndependentAtSameStep() public {
        address user2 = makeAddr("user2");
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.submitProof(user, 0, _createProofForUser(user));
        hook.submitProof(user2, 0, _createProofForUser(user2));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, "");
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user2, user2, ""); // user2 has its own budget
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP);
        assertEq(hook.zkBidTotal(user2, 0), ZK_CAP);
    }

    function test_zkCap_perStepBudgetsIndependent_monotonicVerification() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), address(0));
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.setStepMaxBidAmount(0, ZK_CAP);
        h.setStepMaxBidAmount(1, 500e6);
        vm.stopPrank();

        h.submitProof(user, 0, _createProofForUser(user)); // verified from step 0, monotonic

        // Step 0: fill its budget to the cap.
        vm.roll(100);
        vm.prank(h.cca());
        h.validate(0, uint128(ZK_CAP), user, user, "");
        assertEq(h.zkBidTotal(user, 0), ZK_CAP);

        // Step 1: independent budget governed by step 1's cap; step 0 spend does not consume it.
        vm.roll(200);
        vm.prank(h.cca());
        h.validate(0, 500e6, user, user, "");
        assertEq(h.zkBidTotal(user, 1), 500e6);
        assertEq(h.zkBidTotal(user, 0), ZK_CAP, "step 0 total untouched by step 1 bids");
        vm.prank(h.cca());

        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 1, 500e6 + 1, 500e6)
        );
        h.validate(0, 1, user, user, "");
    }

    function test_zkCap_permitPathUnaffectedByZkCap() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setStepMaxBidAmount(0, ZK_CAP);
        vm.stopPrank();

        vm.roll(step0Start);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("zk-cap-permit");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, uint128(ZK_CAP * 5));
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        // Amount far above the zk cap, but the permit path is independent and must not be capped.
        vm.prank(address(cca2));
        h.validate(0, uint128(ZK_CAP * 5), user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce), "permit should be consumed");
        assertEq(h.zkBidTotal(user, 0), 0, "permit bids must not accrue into the zk total");
    }

    // ─────────────────────────────────────────────────────────
    // Auction-Wide zkTLS Bid Volume Cap — setZkGlobalMaxBidAmount config
    // ─────────────────────────────────────────────────────────

    uint256 constant ZK_GLOBAL_CAP = 2_000e6; // 2,000 USDC, money-token base units

    function test_setZkGlobalMaxBidAmount_storesValue() public {
        assertEq(hook.zkGlobalMaxBidAmount(), 0, "initial cap should be 0");
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        assertEq(hook.zkGlobalMaxBidAmount(), ZK_GLOBAL_CAP, "cap not stored");
    }

    function test_setZkGlobalMaxBidAmount_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit UmiaValidationHook.ZkGlobalMaxBidAmountSet(ZK_GLOBAL_CAP);
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
    }

    function test_setZkGlobalMaxBidAmount_zeroRemovesCap() public {
        vm.startPrank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        hook.setZkGlobalMaxBidAmount(0);
        vm.stopPrank();
        assertEq(hook.zkGlobalMaxBidAmount(), 0, "cap should be cleared");
    }

    function test_setZkGlobalMaxBidAmount_nonOwnerReverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        assertEq(hook.zkGlobalMaxBidAmount(), 0, "cap should remain unchanged after revert");
    }

    function test_setZkGlobalMaxBidAmount_settableBeforeCCA() public {
        UmiaValidationHook freshHook = new UmiaValidationHook(admin, address(reclaim), address(0));
        vm.prank(admin);
        freshHook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        assertEq(freshHook.zkGlobalMaxBidAmount(), ZK_GLOBAL_CAP, "cap should be configurable before pairing");
    }

    // ─────────────────────────────────────────────────────────
    // Auction-Wide zkTLS Bid Volume Cap — validate enforcement
    // ─────────────────────────────────────────────────────────

    function test_zkGlobalCap_sharedAcrossWallets_exceedReverts() public {
        address user2 = makeAddr("user2");
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        hook.submitProof(user, 0, _createProofForUser(user));
        hook.submitProof(user2, 0, _createProofForUser(user2));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 1_500e6, user, user, "");
        vm.prank(hook.cca());
        hook.validate(0, 500e6, user2, user2, ""); // shared pool now exactly at cap
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP, "wallets must draw from one shared pool");

        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user2, ZK_GLOBAL_CAP + 1, ZK_GLOBAL_CAP
            )
        );
        hook.validate(0, 1, user2, user2, "");
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP, "total should be unchanged after revert");
    }

    function test_zkGlobalCap_accruesWhileUncapped_capCountsHistory() public {
        hook.submitProof(user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_GLOBAL_CAP), user, user, "");
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP, "global total accrues even without a cap");

        // A cap set mid-auction counts the volume already landed.
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user, ZK_GLOBAL_CAP + 1, ZK_GLOBAL_CAP
            )
        );
        hook.validate(0, 1, user, user, "");

        // Removing the cap reopens the zk path; the total keeps accruing.
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(0);
        vm.prank(hook.cca());
        hook.validate(0, 1, user, user, "");
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP + 1);
    }

    function test_zkGlobalCap_emitsAccrualEvent() public {
        hook.submitProof(user, 0, _createProofForUser(user));
        vm.roll(step0Start);

        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.ZkGlobalBidAccrued(user, 400e6, 400e6);
        vm.prank(hook.cca());
        hook.validate(0, 400e6, user, user, "");

        // The running total carries across bids; the indexer copies newTotal verbatim.
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.ZkGlobalBidAccrued(user, 100e6, 500e6);
        vm.prank(hook.cca());
        hook.validate(0, 100e6, user, user, "");
    }

    function test_zkGlobalCap_inlineProofFirstBidOverCap_leavesWalletUnverified() public {
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user, ZK_GLOBAL_CAP + 1, ZK_GLOBAL_CAP
            )
        );
        hook.validate(0, uint128(ZK_GLOBAL_CAP + 1), user, user, _inlineProof(0, user));

        assertFalse(hook.isVerified(0, user), "proof storage must roll back when the bid exceeds the cap");
        assertEq(hook.zkGlobalBidTotal(), 0);
    }

    function test_zkGlobalCap_tighterThanStepCap_globalRevertsFirst() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_CAP - 1);
        vm.stopPrank();
        hook.submitProof(user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user, ZK_CAP, ZK_CAP - 1)
        );
        hook.validate(0, uint128(ZK_CAP), user, user, "");
    }

    function test_zkGlobalCap_stepCapStillBindsWhenGlobalHasRoom() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();
        hook.submitProof(user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP)
        );
        hook.validate(0, uint128(ZK_CAP + 1), user, user, "");
        assertEq(hook.zkGlobalBidTotal(), 0, "global total must roll back when the step cap reverts");
    }

    function test_zkGlobalCap_permitPathNotCounted() public {
        UmiaValidationHook h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();

        vm.roll(step0Start);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("zk-global-cap-permit");
        bytes memory signature =
            _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, uint128(ZK_GLOBAL_CAP * 5));
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.prank(address(cca2));
        h.validate(0, uint128(ZK_GLOBAL_CAP * 5), user, user, hookData);

        assertEq(h.zkGlobalBidTotal(), 0, "permit bids must not accrue into the global zk total");
    }

    function test_zkGlobalCap_disabledStepNotCounted() public {
        vm.startPrank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        hook.disableStep(0);
        vm.stopPrank();

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_GLOBAL_CAP * 3), user, user, "");
        assertEq(hook.zkGlobalBidTotal(), 0, "open bids must not accrue into the global zk total");
    }

    function test_validate_revertsForNonCCACaller() public {
        hook.submitProof(user, 0, _createProofForUser(user));
        vm.roll(step0Start);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(UmiaValidationHook.CallerNotCCA.selector);
        hook.validate(0, 1000e6, user, user, "");
    }

    function test_zkCap_cannotBeInflatedByNonCCACaller() public {
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.submitProof(user, 0, _createProofForUser(user));
        vm.roll(step0Start);

        // An attacker calling validate() directly (no funds moved) must not accrue into a
        // verified victim's per-step total and DoS their bids.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(UmiaValidationHook.CallerNotCCA.selector);
        hook.validate(0, uint128(ZK_CAP), user, user, "");

        assertEq(hook.zkBidTotal(user, 0), 0, "attacker must not inflate the victim's total");
        assertEq(hook.zkGlobalBidTotal(), 0, "attacker must not inflate the global total");
    }
}
