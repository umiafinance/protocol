// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVentureToken
/// @notice Interface for VentureToken — used for ERC-165 introspection.
interface IVentureToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function pause() external;
    function unpause() external;
}
