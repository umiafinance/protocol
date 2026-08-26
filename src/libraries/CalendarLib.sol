// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CalendarLib
/// @notice UTC calendar utilities for timestamp-based period tracking.
library CalendarLib {
    /// @dev Converts a Unix timestamp to a YYYYMM calendar month value.
    ///      Uses the Hinnant civil_from_days algorithm.
    function timestampToMonth(uint256 timestamp) internal pure returns (uint256) {
        uint256 z = timestamp / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
        return y * 100 + m;
    }
}
