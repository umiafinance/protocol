// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUmiaTwapMilestoneCondition
/// @notice Shared singleton MetaVesT condition (`IConditionM`): a milestone passes only once the
///         venture's spot-pool TWAP reaches the milestone's price threshold AND the milestone's
///         optional cliff timestamp has elapsed (a cliff of 0 means price-only). Both live on the
///         venture's `VentureVestingAuthority` (written atomically with the grant); this contract
///         holds no registry and no auth — it resolves the venture TWAP and compares it to the
///         adapter's `effectiveThreshold`, gated by `effectiveCliff`. TWAP reads are fail-closed
///         (revert before the pool exists or before the oracle can serve the full window).
interface IUmiaTwapMilestoneCondition {
    error InvalidTwapWindow();
    /// @dev The venture has not migrated its LBP yet (no V4 LP position).
    error NoLpToken();
    /// @dev The oracle cannot serve the full TWAP window (insufficient history or uninitialized).
    error OracleNotReady();

    /// @notice Full TWAP window (seconds) every threshold check observes over.
    function TWAP_WINDOW() external view returns (uint32);

    /// @notice MetaVesT `IConditionM` entrypoint, invoked from `confirmMilestone`. Returns whether the
    ///         milestone's cliff (if any) has elapsed and the current full-window TWAP meets the
    ///         threshold, for the milestone index in `data` and the calling allocation. Threshold and
    ///         cliff are read from the allocation's adapter (`allocation → controller → authority`);
    ///         an unelapsed cliff returns false without reading the TWAP.
    /// @param allocation The calling MetaVesT allocation (`address(this)` at the call site).
    /// @param data Milestone index, ABI-encoded.
    /// @return Whether the milestone's cliff has elapsed and its price threshold is met.
    function checkCondition(address allocation, bytes4, bytes calldata data) external view returns (bool);
}
