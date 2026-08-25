// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VestingAllocation} from "@metavest/VestingAllocation.sol";
import {BaseAllocation} from "@metavest/BaseAllocation.sol";

/// @dev Stands in for UmiaTwapMilestoneCondition: flips true once the sustained TWAP target is met.
contract StubPriceCondition {
    bool public met;

    function setMet(bool _met) external {
        met = _met;
    }

    function checkCondition(address, bytes4, bytes memory) external view returns (bool) {
        return met;
    }
}

/// @title PerformanceMilestoneWithdrawal
/// @notice The performance ladders must be gated on price ALONE: once the 30-day TWAP target holds
///         and the milestone is confirmed, the award is withdrawable immediately. This pins that,
///         and pins the trap it replaces — a non-zero `startOffsetDays` makes both
///         `getVestedTokenAmount` and `getUnlockedTokenAmount` return 0 before the start time, which
///         silently adds a time cliff on top of the price gate.
contract PerformanceMilestoneWithdrawalTest is Test {
    uint256 constant NOMINAL = 1 ether; // VestingAllocation rejects a zero stream
    uint256 constant AWARD = 900_000 ether; // the larger ladder's 2x rung

    address constant GRANTEE = address(0xBEEF); // synthetic; the address is immaterial here
    address constant CONTROLLER = address(0xC0);
    address constant TOKEN = address(0x7070);

    StubPriceCondition condition;
    uint48 anchor;

    function setUp() public {
        anchor = uint48(block.timestamp);
        condition = new StubPriceCondition();
    }

    /// Mirrors the shipped config: `cliffAmount == streamTotal` with `durationDays: 0`, so the
    /// nominal is credited outright instead of streaming and both rates are 0. Nothing about these
    /// grants is time-based.
    function _build(uint48 startOffsetSeconds) internal returns (VestingAllocation) {
        BaseAllocation.Allocation memory a = BaseAllocation.Allocation({
            tokenStreamTotal: NOMINAL,
            vestingCliffCredit: uint128(NOMINAL),
            unlockingCliffCredit: uint128(NOMINAL),
            vestingRate: 0,
            vestingStartTime: anchor + startOffsetSeconds,
            unlockRate: 0,
            unlockStartTime: anchor + startOffsetSeconds,
            tokenContract: TOKEN
        });

        address[] memory conditions = new address[](1);
        conditions[0] = address(condition);
        BaseAllocation.Milestone[] memory milestones = new BaseAllocation.Milestone[](1);
        milestones[0] = BaseAllocation.Milestone({
            milestoneAward: AWARD, unlockOnCompletion: true, complete: false, conditionContracts: conditions
        });

        return new VestingAllocation(GRANTEE, CONTROLLER, a, milestones);
    }

    /// The 1-token nominal exists only because a zero stream reverts. It must not introduce a wait
    /// of its own: credited outright, it is withdrawable from the anchor with no time to serve.
    function test_nominalIsUnlockedImmediately() public {
        VestingAllocation allocation = _build(0);

        assertEq(allocation.getVestedTokenAmount(), NOMINAL, "nominal vested at the anchor");
        assertEq(allocation.getUnlockedTokenAmount(), NOMINAL, "and unlocked at the anchor");
        assertEq(allocation.getAmountWithdrawable(), NOMINAL, "so withdrawable immediately");
    }

    /// What the configs must do: price target met -> confirm -> withdrawable, no waiting.
    function test_uncliffedAwardIsWithdrawableAsSoonAsThePriceHolds() public {
        VestingAllocation allocation = _build(0);

        // Before the TWAP target holds, the milestone cannot even be confirmed.
        vm.expectRevert(BaseAllocation.MetaVesT_ConditionNotSatisfied.selector);
        allocation.confirmMilestone(0);
        assertEq(allocation.getAmountWithdrawable(), NOMINAL, "only the nominal before the target");

        condition.setMet(true);
        allocation.confirmMilestone(0);

        assertEq(allocation.milestoneAwardTotal(), AWARD, "award counted as vested");
        assertEq(allocation.milestoneUnlockedTotal(), AWARD, "award counted as unlocked");
        assertEq(allocation.getAmountWithdrawable(), AWARD + NOMINAL, "award withdrawable immediately");
    }

    /// The trap: the same grant with a 12-month offset withholds a met-and-confirmed award for a
    /// year, because the early return in both getters fires before milestoneAwardTotal is added.
    function test_offsetStartTimeWithholdsAConfirmedAward() public {
        VestingAllocation allocation = _build(365 days);

        condition.setMet(true);
        allocation.confirmMilestone(0);

        assertEq(allocation.milestoneAwardTotal(), AWARD, "milestone is confirmed");
        assertEq(allocation.getVestedTokenAmount(), 0, "but vested reads 0 before the start time");
        assertEq(allocation.getUnlockedTokenAmount(), 0, "and unlocked reads 0 too");
        assertEq(allocation.getAmountWithdrawable(), 0, "so the award is stuck for a year");

        vm.warp(anchor + 365 days);
        assertGe(allocation.getAmountWithdrawable(), AWARD, "only released at the cliff");
    }
}
