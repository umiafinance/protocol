// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GovernanceTypes} from "../libraries/GovernanceTypes.sol";

/// @title ILiquidator
/// @notice Interface for liquidation strategy contracts.
/// @dev Implementations handle the actual liquidation logic (pro-rata, auction, etc.)
///      while keeping assets in the Venture treasury.
interface ILiquidator {
    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error AlreadyInitialized();
    error NotInitialized();
    error AlreadyClaimed();
    error InvalidAssetType();
    error NothingToClaim();
    error CallerNotAuthorized();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    /// @notice Emitted when liquidation is initialized
    /// @param venture The Venture treasury address
    /// @param totalSupply The total supply snapshot at liquidation start
    /// @param assetCount The number of assets being liquidated
    event Initialized(address indexed venture, uint256 totalSupply, uint256 assetCount);

    /// @notice Emitted when a user claims their liquidation proceeds
    /// @param account The account that claimed
    /// @param tokenBalance The venture token balance burned
    event Claimed(address indexed account, uint256 tokenBalance);

    // ─────────────────────────────────────────────────────────
    // State-Changing Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Called by Venture when liquidation starts
    /// @param _venture The Venture treasury address
    /// @param _assets Array of assets to liquidate
    /// @param _totalSupply Snapshot of token total supply at liquidation start
    /// @dev Only callable once. Stores snapshot for pro-rata calculations.
    function initialize(address _venture, GovernanceTypes.LiquidationAsset[] calldata _assets, uint256 _totalSupply)
        external;

    /// @notice Claim liquidation proceeds by burning all venture tokens
    /// @dev Burns ALL caller tokens via the venture and transfers the pro-rata share of each asset.
    function claim() external;

    // ─────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Get claimable amounts for an account (pro-rata of each asset)
    /// @param _account The account to check
    /// @return amounts Array of claimable amounts per asset (in same order as liquidationAssets)
    function claimableAmount(address _account) external view returns (uint256[] memory amounts);

    /// @notice Check if account has already claimed
    /// @param _account The account to check
    /// @return True if account has claimed
    function hasClaimed(address _account) external view returns (bool);

    /// @notice Get a liquidation asset by index
    /// @param _index The asset index
    /// @return assetType The type of asset (NATIVE, ERC20, etc.)
    /// @return token The token address (address(0) for NATIVE)
    /// @return tokenId The token ID (0 for fungible assets)
    /// @return balance The total balance of this asset at liquidation start
    function liquidationAssets(uint256 _index)
        external
        view
        returns (GovernanceTypes.AssetType assetType, address token, uint256 tokenId, uint256 balance);

    /// @notice Get total number of liquidation assets
    /// @return The count of assets being liquidated
    function liquidationAssetCount() external view returns (uint256);

    /// @notice Get the venture address
    /// @return The Venture treasury address
    function venture() external view returns (address);

    /// @notice Get the total supply snapshot at liquidation start
    /// @return The total supply snapshot
    function totalSupplySnapshot() external view returns (uint256);

    /// @notice Check if liquidation has been initialized
    /// @return True if initialize() has been called
    function initialized() external view returns (bool);
}
