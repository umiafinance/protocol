// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IValidationHookIntrospection
} from "@continuous-clearing-auction/periphery/validationHooks/ValidationHookIntrospection.sol";

/// @title IGatedValidationHook
/// @notice The gating half of Uniswap's `IGatedERC1155ValidationHook`, which their auction UI
///         reads to learn that early bidding is restricted and when the restriction lifts.
/// @dev Declared here rather than imported because theirs extends `IBaseERC1155ValidationHook`,
///      whose `erc1155()`/`tokenId()` we do not implement. The ID is identical either way, since
///      Solidity excludes inherited selectors from `type().interfaceId`.
interface IGatedValidationHook is IValidationHookIntrospection {
    /// @notice The block number until which the validation check is enforced
    function expirationBlock() external view returns (uint256);
}
