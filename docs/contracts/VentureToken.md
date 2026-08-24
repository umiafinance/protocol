# VentureToken

Source: `src/tokens/VentureToken.sol`

## Purpose

ERC20 token for an individual venture.

## Behavior

- OZ `ERC20Pausable`.
- `mint(to, amount)` and `burn(from, amount)` are `onlyOwner`.
- `pause()` and `unpause()` are `onlyOwner`.
- During venture creation, token ownership is transferred to the venture treasury contract.

## Notes

- Treasury/governance actions that mint or burn route through `Venture` into this contract.
