// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IValidationHookIntrospection
} from "@continuous-clearing-auction/periphery/validationHooks/ValidationHookIntrospection.sol";

/// @title IMaxBidPriceValidationHook
/// @notice Mirror of the interface in Uniswap/continuous-clearing-auction#365, which is not yet
///         merged and so not in our pinned submodule. Replace this file with the upstream import
///         once it lands; the ID is `bytes4(keccak256("maxBidPrice()"))` either way.
interface IMaxBidPriceValidationHook is IValidationHookIntrospection {
    /// @notice The maximum bid price allowed for a continuous clearing auction
    /// @dev Zero means no effective cap, per the amendment agreed on #365.
    /// @return the max bid price allowed, in Q96 form
    function maxBidPrice() external view returns (uint256);
}
