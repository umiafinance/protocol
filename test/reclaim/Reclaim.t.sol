// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Reclaim} from "../../src/reclaim/Reclaim.sol";
import {Claims} from "../../src/reclaim/Claims.sol";

contract ReclaimTest is Test {
    Reclaim public reclaim;

    uint256 constant WITNESS_PRIVATE_KEY = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    address witnessAddress;

    function setUp() public {
        reclaim = new Reclaim();
        witnessAddress = vm.addr(WITNESS_PRIVATE_KEY);
    }

    function test_InitialEpochSetup() public view {
        // Check that epoch 1 exists after deployment
        assertEq(reclaim.currentEpoch(), 1);

        Reclaim.Epoch memory epoch = reclaim.fetchEpoch(1);
        assertEq(epoch.id, 1);
        assertEq(epoch.minimumWitnessesForClaimCreation, 1);
        assertEq(epoch.witnesses.length, 1);
        assertEq(epoch.witnesses[0].addr, 0x244897572368Eadf65bfBc5aec98D8e5443a9072);
        assertEq(epoch.witnesses[0].host, "wss://attestor.reclaimprotocol.org/ws");
    }

    function test_FetchEpochZeroReturnsLatest() public view {
        Reclaim.Epoch memory epoch = reclaim.fetchEpoch(0);
        assertEq(epoch.id, 1);
    }

    function test_AddNewEpoch() public {
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](2);
        witnesses[0] = Reclaim.Witness({addr: address(0x1), host: "wss://witness1.example.com"});
        witnesses[1] = Reclaim.Witness({addr: address(0x2), host: "wss://witness2.example.com"});

        reclaim.addNewEpoch(witnesses, 2);

        assertEq(reclaim.currentEpoch(), 2);

        Reclaim.Epoch memory epoch = reclaim.fetchEpoch(2);
        assertEq(epoch.id, 2);
        assertEq(epoch.minimumWitnessesForClaimCreation, 2);
        assertEq(epoch.witnesses.length, 2);
    }

    function test_AddNewEpoch_RevertsTooManyRequiredWitnesses() public {
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness({addr: address(0x1), host: "wss://witness1.example.com"});

        vm.expectRevert("Invalid requisite witnesses count");
        reclaim.addNewEpoch(witnesses, 2);
    }

    function test_AddNewEpoch_RevertsZeroWitnesses() public {
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](0);

        vm.expectRevert("No witnesses provided");
        reclaim.addNewEpoch(witnesses, 0);
    }

    function test_AddNewEpoch_RevertsZeroRequiredWitnesses() public {
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness({addr: address(0x1), host: "wss://witness1.example.com"});

        vm.expectRevert("Invalid requisite witnesses count");
        reclaim.addNewEpoch(witnesses, 0);
    }

    function test_AddNewEpochOnlyOwner() public {
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness({addr: address(0x1), host: "wss://witness1.example.com"});

        vm.prank(address(0xdead));
        vm.expectRevert("Only Owner");
        reclaim.addNewEpoch(witnesses, 1);
    }

    function test_AddNewEpochEndsCurrentEpoch() public {
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness({addr: address(0x1), host: "wss://witness1.example.com"});

        vm.warp(block.timestamp + 1 hours);
        reclaim.addNewEpoch(witnesses, 1);

        Reclaim.Epoch memory epoch1 = reclaim.fetchEpoch(1);
        assertEq(epoch1.timestampEnd, uint32(block.timestamp));
    }

    function test_FetchWitnessesForClaim() public view {
        Reclaim.Witness[] memory witnesses =
            reclaim.fetchWitnessesForClaim(1, bytes32(uint256(123)), uint32(block.timestamp));

        assertEq(witnesses.length, 1);
        assertEq(witnesses[0].addr, 0x244897572368Eadf65bfBc5aec98D8e5443a9072);
    }

    function test_VerifyProofWithValidSignature() public {
        // Setup: Add epoch with our test witness
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness({addr: witnessAddress, host: "wss://test.example.com"});
        reclaim.addNewEpoch(witnesses, 1);

        // Create claim info
        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: "test-context"});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        // Create complete claim data
        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: address(this), timestampS: uint32(block.timestamp), epoch: 2
        });

        // Sign the claim
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

        // This should not revert
        reclaim.verifyProof(proof);
    }

    function test_VerifyProofRevertNoSignatures() public {
        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: "test-context"});

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: Claims.hashClaimInfo(claimInfo),
            owner: address(this),
            timestampS: uint32(block.timestamp),
            epoch: 1
        });

        bytes[] memory signatures = new bytes[](0);

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        vm.expectRevert("No signatures");
        reclaim.verifyProof(proof);
    }

    function test_VerifyRealWorldProof() public {
        // Real-world proof from Reclaim Protocol
        Claims.ClaimInfo memory claimInfo = Claims.ClaimInfo({
            provider: "http",
            parameters: '{"body":"","geoLocation":"in","method":"GET","paramValues":{"CLAIM_DATA":"76561199632643233"},"responseMatches":[{"type":"contains","value":"_steamid\\">Steam ID: {{CLAIM_DATA}}</div>"}],"responseRedactions":[{"jsonPath":"","regex":"_steamid\\">Steam\\\\ ID:\\\\ (.*)</div>","xPath":"id(\\"responsive_page_template_content\\")/div[@class=\\"page_header_ctn\\"]/div[@class=\\"page_content\\"]/div[@class=\\"youraccount_steamid\\"]"}],"url":"https://store.steampowered.com/account/"}',
            context: '{"contextAddress":"user\'s address","contextMessage":"for acmecorp.com on 1st january","extractedParameters":{"CLAIM_DATA":"76561199632643233"},"providerHash":"0x61433e76ff18460b8307a7e4236422ac66c510f0f9faff2892635c12b7c1076e"}'
        });

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: 0x0ae1908b6ea3e2729c930391e2e8e08708f2e04073f000a6c92e4f73bc958e27,
            owner: 0x0D0cC50d2c4DcD65A000304D2Dbdd103C2F37B63,
            timestampS: 1721386619,
            epoch: 1
        });

        bytes[] memory signatures = new bytes[](1);
        signatures[0] =
            hex"2a647de47e8827c54d1078b27341a2838e422e96090aa2bbacffc3d3dee686cc480d05471e03a1f4628546e03b697ae8193d5c91b91e1167ee92082c73d605741c";

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        // Verify the identifier matches the hash of claimInfo
        bytes32 expectedIdentifier = Claims.hashClaimInfo(claimInfo);
        assertEq(claimData.identifier, expectedIdentifier, "Identifier should match hash of claimInfo");

        // This should not revert - proof is valid
        reclaim.verifyProof(proof);
    }

    function test_VerifyProofRevertAlreadyUsed() public {
        // Setup: Add epoch with our test witness
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness({addr: witnessAddress, host: "wss://test.example.com"});
        reclaim.addNewEpoch(witnesses, 1);

        // Create claim info
        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: "test-context"});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        // Create complete claim data
        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: address(this), timestampS: uint32(block.timestamp), epoch: 2
        });

        // Sign the claim
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

        // First verification should succeed
        reclaim.verifyProof(proof);

        // Second verification with same proof should fail
        vm.expectRevert("Proof already used");
        reclaim.verifyProof(proof);
    }

    function test_VerifyProofRevertIdentifierMismatch() public {
        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: "test-context"});

        // Use wrong identifier
        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: bytes32(uint256(123)), // Wrong identifier
            owner: address(this),
            timestampS: uint32(block.timestamp),
            epoch: 1
        });

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = new bytes(65);

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        vm.expectRevert("Claim identifier mismatch");
        reclaim.verifyProof(proof);
    }

    // Helper functions to match StringUtils
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
}
