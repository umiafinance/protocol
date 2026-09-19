// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Utilities for string manipulation & conversion
 */
library StringUtils {
    function address2str(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(x)) / (2 ** (8 * (19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2 * i] = getChar(hi);
            s[2 * i + 1] = getChar(lo);
        }
        return string(abi.encodePacked("0x", s));
    }

    function bytes2str(bytes memory buffer) internal pure returns (string memory) {
        // Fixed buffer size for hexadecimal convertion
        bytes memory converted = new bytes(buffer.length * 2);
        bytes memory _base = "0123456789abcdef";

        for (uint256 i = 0; i < buffer.length; i++) {
            converted[i * 2] = _base[uint8(buffer[i]) / _base.length];
            converted[i * 2 + 1] = _base[uint8(buffer[i]) % _base.length];
        }

        return string(abi.encodePacked("0x", converted));
    }

    function getChar(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }

    function bool2str(bool _b) internal pure returns (string memory _uintAsString) {
        if (_b) {
            return "true";
        } else {
            return "false";
        }
    }

    function uint2str(uint256 _i) internal pure returns (string memory _uintAsString) {
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

    function areEqual(string calldata _a, string storage _b) internal pure returns (bool) {
        return keccak256(abi.encodePacked((_a))) == keccak256(abi.encodePacked((_b)));
    }

    function areEqual(string memory _a, string memory _b) internal pure returns (bool) {
        return keccak256(abi.encodePacked((_a))) == keccak256(abi.encodePacked((_b)));
    }

    function toLower(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bLower = new bytes(bStr.length);
        for (uint256 i = 0; i < bStr.length; i++) {
            // Uppercase character...
            if ((uint8(bStr[i]) >= 65) && (uint8(bStr[i]) <= 90)) {
                // So we add 32 to make it lowercase
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        return string(bLower);
    }

    function substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    /// @dev Parses a hex digit, reverting on any byte that is not `[0-9a-fA-F]`.
    ///      The previous implementation let a non-hex byte fall through every branch and added its raw
    ///      ASCII value, so a malformed field produced a wrong-but-deterministic, attacker-predictable
    ///      result instead of failing. Anything derived from an attested context must fail loudly.
    function _hexDigit(uint8 char) private pure returns (uint8) {
        if (char >= 97 && char <= 102) return char - 87; // a-f
        if (char >= 65 && char <= 70) return char - 55; // A-F
        if (char >= 48 && char <= 57) return char - 48; // 0-9
        revert("StringUtils: non-hex character");
    }

    /// @dev Strips an optional `0x` / `0X` prefix and returns the offset of the first hex digit.
    function _hexOffset(bytes memory tmp) private pure returns (uint256) {
        if (tmp.length >= 2 && tmp[0] == "0" && (tmp[1] == "x" || tmp[1] == "X")) return 2;
        return 0;
    }

    /// @notice Parses a hex string into an address.
    /// @dev Requires exactly 40 hex digits after the optional prefix. A short or over-long field used to
    ///      be accepted and shifted into a different address entirely; callers bind that address as a
    ///      proof owner, so a silent mis-parse is a correctness bug, not a formatting nicety.
    function str2address(string memory _a) internal pure returns (address) {
        bytes memory tmp = bytes(_a);
        uint256 offset = _hexOffset(tmp);
        require(tmp.length - offset == 40, "StringUtils: bad address length");

        uint160 iaddr = 0;
        for (uint256 i = offset; i < tmp.length; i++) {
            iaddr = iaddr * 16 + _hexDigit(uint8(tmp[i]));
        }
        return address(iaddr);
    }

    /// @notice Parses a hex string into a bytes32.
    /// @dev Requires at most 64 hex digits after the optional prefix. The previous implementation
    ///      silently truncated at 64, so two distinct values sharing a 64-digit prefix collapsed onto the
    ///      same `bytes32` — for provider hashes that means two different providers comparing equal.
    function str2bytes32(string memory _a) internal pure returns (bytes32) {
        bytes memory tmp = bytes(_a);
        uint256 offset = _hexOffset(tmp);
        uint256 len = tmp.length - offset;
        require(len <= 64, "StringUtils: bytes32 overflow");

        uint256 result;
        for (uint256 i = 0; i < len; i++) {
            result = result * 16 + _hexDigit(uint8(tmp[i + offset]));
        }
        return bytes32(result);
    }
}
