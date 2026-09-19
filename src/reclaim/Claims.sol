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
     *
     * Each expected witness must be matched by a *distinct* signature. Counting a single signature
     * against several expected witnesses would let one witness that signed twice satisfy an
     * n-of-n witness set, which is the whole guarantee this function exists to provide.
     */
    function assertValidSignedClaim(SignedClaim memory self, address[] memory expectedWitnessAddresses) internal pure {
        require(self.signatures.length > 0, "No signatures");
        require(self.signatures.length >= expectedWitnessAddresses.length, "Not enough signatures");

        address[] memory signedWitnesses = recoverSignersOfSignedClaim(self);
        bool[] memory consumed = new bool[](signedWitnesses.length);

        for (uint256 i = 0; i < expectedWitnessAddresses.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < signedWitnesses.length; j++) {
                if (!consumed[j] && signedWitnesses[j] == expectedWitnessAddresses[i]) {
                    consumed[j] = true;
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

    /// @dev Maximum JSON nesting the context scanner will follow. A context deeper than this is
    ///      rejected rather than silently mis-parsed; the depth-type bitmap below holds 256 levels.
    uint256 private constant MAX_JSON_DEPTH = 256;

    /// @dev True when `targetBytes` occurs in `dataBytes` starting exactly at `offset`.
    function _matchesAt(bytes memory dataBytes, bytes memory targetBytes, uint256 offset)
        private
        pure
        returns (bool)
    {
        if (offset + targetBytes.length > dataBytes.length) return false;
        for (uint256 j = 0; j < targetBytes.length; j++) {
            if (dataBytes[offset + j] != targetBytes[j]) return false;
        }
        return true;
    }

    /// @dev Finds the value that follows `target` in `data`, where `target` is a key pattern beginning
    ///      with the key's opening quote (e.g. `"providerHash":"`). Returns the offset of the first
    ///      byte after the match.
    ///
    ///      The search is anchored twice over: a match only counts when it starts at a position where a
    ///      JSON object key can legally begin — outside any string literal, immediately after `{` or a
    ///      `,` inside an object — **and** when that position is a top-level key of the context object
    ///      (`depth == 1`).
    ///
    ///      Both restrictions matter, and each blocks a different forgery:
    ///
    ///      * The plain substring search this replaced matched anywhere, including inside a string
    ///        value. A context is only a signed blob of bytes; nothing forces it to be well-formed
    ///        JSON, so a value carrying raw `"` bytes could spell out a whole key/value pair.
    ///      * Depth restriction blocks the well-formed case, which needs no raw quotes at all:
    ///        `extractedParameters` is scraped provider data and therefore prover-influenced, so
    ///        `{"extractedParameters":{"contextAddress":"0xattacker"},"contextAddress":"0xvictim"}`
    ///        puts a *legitimate* `"contextAddress"` key earlier in the byte stream than the real one.
    ///        Reclaim places `contextAddress`, `providerHash` and `extractedParameters` at the top
    ///        level, so nothing legitimate is lost by refusing to look deeper.
    ///
    ///      Everything downstream — the bound address, the provider hash, the OPRF identity — is
    ///      derived from these extractions, so the first match must be the real key or nothing.
    function _findValueStart(bytes memory dataBytes, bytes memory targetBytes)
        private
        pure
        returns (uint256 start, bool found)
    {
        if (targetBytes.length == 0 || dataBytes.length < targetBytes.length) return (0, false);

        bool inStr;
        bool escaped;
        // Bit `depth - 1` records the container opened at that depth: 1 = object, 0 = array. Only an
        // object's `,` introduces a key, so an array element cannot be mistaken for one.
        uint256 containerIsObject;
        uint256 depth;
        bool expectKey;

        for (uint256 i = 0; i < dataBytes.length; i++) {
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
                if (expectKey && depth == 1 && _matchesAt(dataBytes, targetBytes, i)) {
                    return (i + targetBytes.length, true);
                }
                // Not the key we want: step over this string (key or value) without inspecting it.
                inStr = true;
                expectKey = false;
            } else if (ch == "{" || ch == "[") {
                if (depth == MAX_JSON_DEPTH) return (0, false);
                depth++;
                if (ch == "{") {
                    containerIsObject |= (1 << (depth - 1));
                    expectKey = true;
                } else {
                    containerIsObject &= ~(1 << (depth - 1));
                    expectKey = false;
                }
            } else if (ch == "}" || ch == "]") {
                if (depth == 0) return (0, false); // unbalanced context
                depth--;
                expectKey = false;
            } else if (ch == ",") {
                expectKey = depth > 0 && (containerIsObject >> (depth - 1)) & 1 == 1;
            }
        }

        return (0, false);
    }

    /// @notice Extracts the string value that follows `target` in `data`.
    /// @param target Key pattern including the key's opening quote and the `":"` that introduces the
    ///        value, e.g. `'"providerHash":"'`. A target that does not start at a key boundary can
    ///        never match — see `_findValueStart`.
    /// @return The value bytes, or the empty string if the key is absent or its value is unterminated.
    function extractFieldFromContext(string memory data, string memory target) public pure returns (string memory) {
        bytes memory dataBytes = bytes(data);
        bytes memory targetBytes = bytes(target);

        // An empty target used to match at offset 0 and then read `dataBytes[end - 1]` with `end == 0`,
        // reverting with an arithmetic panic instead of a stated reason.
        require(targetBytes.length > 0, "target is empty");
        require(dataBytes.length >= targetBytes.length, "target is longer than data");

        (uint256 start, bool foundStart) = _findValueStart(dataBytes, targetBytes);
        if (!foundStart) {
            return ""; // Malformed or missing message
        }

        // Walk to the closing quote, tracking escapes so an escaped quote inside the value does not
        // end it and a value ending in a literal backslash is not mistaken for one.
        uint256 end = start;
        bool escaped;
        while (end < dataBytes.length) {
            bytes1 ch = dataBytes[end];
            if (escaped) {
                escaped = false;
            } else if (ch == "\\") {
                escaped = true;
            } else if (ch == '"') {
                break;
            }
            end++;
        }

        if (end >= dataBytes.length || end == start) {
            return ""; // unterminated or empty value
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

        if (targetBytes.length == 0 || dataBytes.length < targetBytes.length) return "";

        // Key-anchored, for the same reason as `extractFieldFromContext`: a prover-controlled string
        // value could otherwise contain the escaped bytes of `"extractedParameters":{...}` and have a
        // plain substring scan return that forgery instead of the object the attestor actually signed.
        (uint256 start, bool foundStart) = _findValueStart(dataBytes, targetBytes);
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

