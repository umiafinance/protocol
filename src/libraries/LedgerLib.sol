// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IUmiaMarketCore} from "../interfaces/IUmiaMarketCore.sol";

/// @title LedgerLib
/// @notice Minimal virtual-token ledger primitives (mint / burn / move) shared by UmiaMarketCore and
///         its market-creation and settlement libraries.
/// @dev Operates on the passed `balanceOf` / `totalSupply` storage references so every caller mutates
///      the same core storage and emits an identical `VirtualTransfer`. There is no approval or
///      operator mechanism; callers enforce their own authorization.
library LedgerLib {
    /// @dev Credits `amount` of token `id` to `to` and increases its total supply.
    function mint(
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply,
        address to,
        uint256 id,
        uint256 amount
    ) internal {
        balanceOf[to][id] += amount;
        totalSupply[id] += amount;
        emit IUmiaMarketCore.VirtualTransfer(address(0), to, id, amount);
    }

    /// @dev Debits `amount` of token `id` from `from` and decreases its total supply.
    function burn(
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply,
        address from,
        uint256 id,
        uint256 amount
    ) internal {
        uint256 bal = balanceOf[from][id];
        if (bal < amount) revert IUmiaMarketCore.InsufficientVirtualTokens();
        unchecked {
            balanceOf[from][id] = bal - amount;
            totalSupply[id] -= amount;
        }
        emit IUmiaMarketCore.VirtualTransfer(from, address(0), id, amount);
    }

    /// @dev Transfers `amount` of token `id` from `from` to `to`; total supply is unchanged.
    function move(
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        address from,
        address to,
        uint256 id,
        uint256 amount
    ) internal {
        uint256 bal = balanceOf[from][id];
        if (bal < amount) revert IUmiaMarketCore.InsufficientVirtualTokens();
        unchecked {
            balanceOf[from][id] = bal - amount;
        }
        balanceOf[to][id] += amount;
        emit IUmiaMarketCore.VirtualTransfer(from, to, id, amount);
    }
}
