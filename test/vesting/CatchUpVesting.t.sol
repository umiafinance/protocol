// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VestingAllocation} from "@metavest/VestingAllocation.sol";
import {BaseAllocation} from "@metavest/BaseAllocation.sol";

/// @title CatchUpVesting
/// @notice Pins the vesting shape the TGE configs encode: a 36-month stream accruing from the
///         auction end, gated by an unlock cliff at month 12 that releases the accrued third in one
///         go. The knob is `unlockingCliffCredit == tokenStreamTotal` with `unlockRate == 0`, so
///         unlocking is the binding constraint until month 12 and vesting is binding after it.
///         Guards against anyone "simplifying" the config back to a delayed vestingStartTime, which
///         pays nothing at the cliff and finishes at month 48 instead.
contract CatchUpVestingTest is Test {
    // The largest time-vest grant in the TGE configs, verbatim. Grantee is synthetic: the
    // arithmetic does not depend on the address, and a real one would map an identity to it.
    uint256 constant STREAM_TOTAL = 937_500 ether;
    uint256 constant VEST_SECONDS = 1095 days;
    uint256 constant CLIFF_SECONDS = 365 days;

    address constant GRANTEE = address(0xBEEF);
    address constant CONTROLLER = address(0xC0);
    address constant TOKEN = address(0x7070);

    VestingAllocation allocation;
    uint48 anchor;

    function setUp() public {
        // The auction end is the anchor every grant offset resolves against.
        anchor = uint48(block.timestamp);

        BaseAllocation.Allocation memory a = BaseAllocation.Allocation({
            tokenStreamTotal: STREAM_TOTAL,
            vestingCliffCredit: 0,
            // The catch-up: everything unlocks in one lump when the cliff lands.
            unlockingCliffCredit: uint128(STREAM_TOTAL),
            // Mirrors `linearRate` in services/internal-cli/src/lib/vesting-grant.ts: floor division.
            vestingRate: uint160(STREAM_TOTAL / VEST_SECONDS),
            vestingStartTime: anchor,
            unlockRate: 0,
            unlockStartTime: anchor + uint48(CLIFF_SECONDS),
            tokenContract: TOKEN
        });

        allocation = new VestingAllocation(GRANTEE, CONTROLLER, a, new BaseAllocation.Milestone[](0));
    }

    function test_nothingWithdrawableBeforeTheCliff() public {
        for (uint256 month = 0; month < 12; month++) {
            vm.warp(anchor + (month * 365 days) / 12);
            assertEq(allocation.getAmountWithdrawable(), 0, "withdrawable before the cliff");
            assertEq(allocation.getUnlockedTokenAmount(), 0, "unlocked before the cliff");
        }
    }

    /// The whole point of "catch-up": vesting has been accruing all along, so the cliff pays out a
    /// third rather than starting the clock.
    function test_cliffPaysTheAccruedThird() public {
        vm.warp(anchor + CLIFF_SECONDS);

        assertEq(allocation.getUnlockedTokenAmount(), STREAM_TOTAL, "fully unlocked at the cliff");

        uint256 withdrawable = allocation.getAmountWithdrawable();
        // A third of the stream, less the sub-token dust from flooring vestingRate.
        assertApproxEqAbs(withdrawable, STREAM_TOTAL / 3, 1 ether, "catch-up is a third");
        assertLt(withdrawable, STREAM_TOTAL / 3, "floor division never over-pays");
    }

    function test_vestingIsBindingAfterTheCliff() public {
        vm.warp(anchor + CLIFF_SECONDS);
        uint256 atCliff = allocation.getAmountWithdrawable();

        // One month on, the grant releases another 1/36 and nothing more.
        vm.warp(anchor + CLIFF_SECONDS + 30 days);
        uint256 aMonthLater = allocation.getAmountWithdrawable();

        assertGt(aMonthLater, atCliff, "keeps accruing past the cliff");
        assertApproxEqAbs(aMonthLater - atCliff, (STREAM_TOTAL * 30 days) / VEST_SECONDS, 1 ether, "monthly accrual");
    }

    /// `vestingRate` is floored, so linear accrual lands a hair under the total at the exact nominal
    /// end (26,736,000 wei here, 2.7e-11 tokens) and the cap closes it on the next second.
    function test_fullyVestedAtMonth36() public {
        vm.warp(anchor + VEST_SECONDS);
        uint256 atNominalEnd = allocation.getVestedTokenAmount();
        assertApproxEqAbs(atNominalEnd, STREAM_TOTAL, 1 gwei, "within dust of the total");
        assertLt(atNominalEnd, STREAM_TOTAL, "floor division never over-pays");

        vm.warp(anchor + VEST_SECONDS + 1);
        assertEq(allocation.getVestedTokenAmount(), STREAM_TOTAL, "capped one second later");
        assertEq(allocation.getAmountWithdrawable(), STREAM_TOTAL, "fully withdrawable");

        // And never more than the total, however long anyone waits.
        vm.warp(anchor + 10 * 365 days);
        assertEq(allocation.getAmountWithdrawable(), STREAM_TOTAL, "no overshoot");
    }

    /// The shape we deliberately moved away from, kept as a contrast so the difference is explicit:
    /// a delayed vestingStartTime pays nothing at month 12 and only finishes at month 48.
    function test_delayedStartWouldPayNothingAtTheCliff() public {
        BaseAllocation.Allocation memory delayed = BaseAllocation.Allocation({
            tokenStreamTotal: STREAM_TOTAL,
            vestingCliffCredit: 0,
            unlockingCliffCredit: 0,
            vestingRate: uint160(STREAM_TOTAL / VEST_SECONDS),
            vestingStartTime: anchor + uint48(CLIFF_SECONDS),
            unlockRate: uint160(STREAM_TOTAL / VEST_SECONDS),
            unlockStartTime: anchor + uint48(CLIFF_SECONDS),
            tokenContract: TOKEN
        });
        VestingAllocation other = new VestingAllocation(GRANTEE, CONTROLLER, delayed, new BaseAllocation.Milestone[](0));

        vm.warp(anchor + CLIFF_SECONDS);
        assertEq(other.getAmountWithdrawable(), 0, "delayed start pays nothing at the cliff");

        vm.warp(anchor + CLIFF_SECONDS + VEST_SECONDS + 1);
        assertEq(other.getAmountWithdrawable(), STREAM_TOTAL, "and only finishes at month 48");
    }

    /// A milestone-only grant is impossible, which is why the performance ladders carry a 1-token
    /// nominal stream and shave a token off their last rung.
    function test_zeroStreamReverts() public {
        BaseAllocation.Allocation memory zero = BaseAllocation.Allocation({
            tokenStreamTotal: 0,
            vestingCliffCredit: 0,
            unlockingCliffCredit: 0,
            vestingRate: 0,
            vestingStartTime: anchor,
            unlockRate: 0,
            unlockStartTime: anchor,
            tokenContract: TOKEN
        });
        vm.expectRevert(BaseAllocation.MetaVesT_ZeroAmount.selector);
        new VestingAllocation(GRANTEE, CONTROLLER, zero, new BaseAllocation.Milestone[](0));
    }
}
