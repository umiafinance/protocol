// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IVentureToken} from "../interfaces/IVentureToken.sol";

/// @title VentureToken
/// @notice The token contract for Umia ventures
contract VentureToken is ERC20Pausable, Ownable, ERC165, IVentureToken {
    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Constructor
    /// @param _name The name of the token
    /// @param _symbol The symbol of the token
    /// @param _owner The address of the owner
    constructor(string memory _name, string memory _symbol, address _owner) ERC20(_name, _symbol) Ownable(_owner) {}

    // ─────────────────────────────────────────────────────────
    // Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Mint tokens to an address
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burn tokens from an address
    /// @param from The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /// @notice Pause the token
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the token
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Keep transfers paused while still allowing owner-controlled mint and burn.
    ///      This lets liquidation burns proceed even if trading is paused after LBP migration.
    function _update(address from, address to, uint256 amount) internal override(ERC20Pausable) {
        if (paused() && from != address(0) && to != address(0)) revert EnforcedPause();
        ERC20._update(from, to, amount);
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IVentureToken).interfaceId || super.supportsInterface(interfaceId);
    }
}
