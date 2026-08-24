// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockBadInitializer {
    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}
