// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./StringUtils.sol";

/**
 * Library to assist with requesting,
 * serialising & verifying credentials
 */
library Claims {
    /**
     * Data required to describe a claim
     */
    struct CompleteClaimData {
        bytes32 identifier;
        address owner;
        uint32 timestampS;
        uint32 epoch;
    }

    struct ClaimInfo {
        string provider;
        string parameters;
        string context;
    }

    /**
     * Claim with signatures & signer
     */
    struct SignedClaim {
        CompleteClaimData claim;
        bytes[] signatures;
    }

    /**
     * Asserts that the claim is signed by the expected witnesses
     */
    function assertValidSignedClaim(SignedClaim memory self, address[] memory expectedWitnessAddresses) internal pure {
        require(self.signatures.length > 0, "No signatures");
        address[] memory signedWitnesses = recoverSignersOfSignedClaim(self);
        for (uint256 i = 0; i < expectedWitnessAddresses.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < signedWitnesses.length; j++) {
                if (signedWitnesses[j] == expectedWitnessAddresses[i]) {
                    found = true;
                    break;
                }
            }
            require(found, "Missing witness signature");
        }
    }

    /**
     * @dev recovers the signer of the claim
     */
    function recoverSignersOfSignedClaim(SignedClaim memory self) internal pure returns (address[] memory) {
        bytes memory serialised = serialise(self.claim);
        address[] memory signers = new address[](self.signatures.length);
        for (uint256 i = 0; i < self.signatures.length; i++) {
            signers[i] = verifySignature(serialised, self.signatures[i]);
        }

        return signers;
    }

    /**
     * @dev serialises the credential into a string;
     * the string is used to verify the signature
     *
     * the serialisation is the same as done by the TS library
     */
    function serialise(CompleteClaimData memory self) internal pure returns (bytes memory) {
        return abi.encodePacked(
            StringUtils.bytes2str(abi.encodePacked(self.identifier)),
            "\n",
            StringUtils.address2str(self.owner),
            "\n",
            StringUtils.uint2str(self.timestampS),
            "\n",
            StringUtils.uint2str(self.epoch)
        );
    }

    /**
     * @dev returns the address of the user that generated the signature
     */
    function verifySignature(bytes memory content, bytes memory signature) internal pure returns (address signer) {
        bytes32 signedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n", StringUtils.uint2str(content.length), content)
        );
        return ECDSA.recover(signedHash, signature);
    }

    function hashClaimInfo(ClaimInfo memory claimInfo) internal pure returns (bytes32) {
        bytes memory serialised =
            abi.encodePacked(claimInfo.provider, "\n", claimInfo.parameters, "\n", claimInfo.context);
        return keccak256(serialised);
    }

    function extractFieldFromContext(string memory data, string memory target) public pure returns (string memory) {
        bytes memory dataBytes = bytes(data);
        bytes memory targetBytes = bytes(target);

        require(dataBytes.length >= targetBytes.length, "target is longer than data");
        uint256 start = 0;
        bool foundStart = false;
        // Find start of "contextMessage":"

        for (uint256 i = 0; i <= dataBytes.length - targetBytes.length; i++) {
            bool isMatch = true;

            for (uint256 j = 0; j < targetBytes.length && isMatch; j++) {
                if (dataBytes[i + j] != targetBytes[j]) {
                    isMatch = false;
                }
            }

            if (isMatch) {
                start = i + targetBytes.length; // Move start to the end of "contextMessage":"
                foundStart = true;
                break;
            }
        }

        if (!foundStart) {
            return ""; // Malformed or missing message
        }

        // Find the end of the message, assuming it ends with a quote not preceded by a backslash.
        // The function does not need to handle escaped backslashes specifically because
        // it only looks for the first unescaped quote to mark the end of the field value.
        // Escaped quotes (preceded by a backslash) are naturally ignored in this logic.
        uint256 end = start;
        while (end < dataBytes.length && !(dataBytes[end] == '"' && dataBytes[end - 1] != "\\")) {
            end++;
        }

        if (end >= dataBytes.length || end <= start) {
            return "";
        }

        bytes memory contextMessage = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            contextMessage[i - start] = dataBytes[i];
        }
        return string(contextMessage);
    }

    /// @notice Extracts the raw JSON object substring (including outer braces)
    ///         that follows `target` in `data`. Tracks brace depth and respects
    ///         JSON string escapes so values containing `}` or escaped quotes
    ///         don't truncate the output. Returns empty bytes if the target is
    ///         absent or the object is malformed / never closes.
    /// @dev Used to grab `extractedParameters` verbatim out of a Reclaim
    ///      context for off-/onchain identity hashing without having to parse
    ///      JSON. The returned bytes are byte-equivalent to the substring the
    ///      attestor signed.
    function extractJsonObjectFromContext(string memory data, string memory target)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory dataBytes = bytes(data);
        bytes memory targetBytes = bytes(target);

        if (dataBytes.length < targetBytes.length) return "";

        uint256 start = 0;
        bool foundStart = false;
        for (uint256 i = 0; i <= dataBytes.length - targetBytes.length; i++) {
            bool isMatch = true;
            for (uint256 j = 0; j < targetBytes.length && isMatch; j++) {
                if (dataBytes[i + j] != targetBytes[j]) {
                    isMatch = false;
                }
            }
            if (isMatch) {
                start = i + targetBytes.length;
                foundStart = true;
                break;
            }
        }
        if (!foundStart) return "";

        // Skip optional whitespace between the colon and the opening brace.
        while (start < dataBytes.length && (dataBytes[start] == 0x20 || dataBytes[start] == 0x09)) {
            start++;
        }
        if (start >= dataBytes.length || dataBytes[start] != "{") return "";

        uint256 depth = 0;
        bool inStr = false;
        bool escaped = false;
        uint256 end = dataBytes.length;
        for (uint256 i = start; i < dataBytes.length; i++) {
            bytes1 ch = dataBytes[i];
            if (inStr) {
                if (escaped) {
                    escaped = false;
                } else if (ch == "\\") {
                    escaped = true;
                } else if (ch == '"') {
                    inStr = false;
                }
                continue;
            }
            if (ch == '"') {
                inStr = true;
            } else if (ch == "{") {
                depth++;
            } else if (ch == "}") {
                depth--;
                if (depth == 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        if (end > dataBytes.length || depth != 0) return "";

        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = dataBytes[i];
        }
        return out;
    }
}

