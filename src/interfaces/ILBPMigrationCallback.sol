// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILBPMigrationCallback
/// @notice Callback interface for LBP post-migration notification
/// @dev Implement this on contracts that need to be notified when an LBP migration completes
interface ILBPMigrationCallback {
    /// @notice Called by the LBP after migration completes. The canonical spot liquidity is held
    ///         by the venture's SpotLiquidityVault, so no LP NFT is passed.
    function onLBPMigrated() external;
}
