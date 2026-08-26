// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Claims} from "../../src/reclaim/Claims.sol";

/// @notice Test-only wrapper that exposes the internal Claims library helpers
///         to Foundry tests.
contract ClaimsHarness {
    function extractJsonObjectFromContext(string memory data, string memory target)
        external
        pure
        returns (bytes memory)
    {
        return Claims.extractJsonObjectFromContext(data, target);
    }
}
