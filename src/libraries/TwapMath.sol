// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TwapMath
/// @notice Shared time-weighted-average-tick derivation for the spot-market oracle consumers.
library TwapMath {
    /// @notice Floored time-weighted average tick over `window` seconds.
    /// @param tickCumulativeOlder Tick-cumulative at the start of the window (secondsAgo == window).
    /// @param tickCumulativeNewer Tick-cumulative at the end of the window (secondsAgo == 0).
    /// @param window Window length in seconds; must be non-zero.
    /// @dev Solidity division truncates toward zero, which would bias the average toward +∞ for
    ///      negative deltas; the correction floors toward -∞ so the deviation budget stays symmetric.
    function averageTick(int48 tickCumulativeOlder, int48 tickCumulativeNewer, uint32 window)
        internal
        pure
        returns (int24 tick)
    {
        int48 tickDelta = tickCumulativeNewer - tickCumulativeOlder;
        int48 windowInt = int48(uint48(window));
        tick = int24(tickDelta / windowInt);
        if (tickDelta < 0 && tickDelta % windowInt != 0) tick--;
    }
}
