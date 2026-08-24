// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";

/// @title DecisionMarketTimingTest
/// @notice Tests for configurable market trading duration and start delay.
contract DecisionMarketTimingTest is DecisionMarketBase {
    uint256 internal constant DEFAULT_DURATION = 3 days;
    uint256 internal constant MIN_DURATION = 1 hours;
    uint256 internal constant MAX_DURATION = 96 hours;
    uint256 internal constant MAX_START_DELAY = 7 days;

    function setUp() public override {
        super.setUp();

        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();
        vm.label(ventureToken, "ALICE");

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(ventureId, MIN_MARKET_STAKE);
        _mintVenture(hub, venture, alice, MIN_MARKET_STAKE);

        vm.startPrank(alice);
        IERC20(ventureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(ventureId);
        vm.stopPrank();

        // Anchor to a realistic unix time so "past" start timestamps don't underflow, then warm the
        // spot oracle so the vault's sandwich guard passes at market creation (warm must run after the
        // anchor warp, otherwise the anchor rewinds time behind the oracle observations).
        vm.warp(1_700_000_000);
        _warmSpotOracle(venture);
    }

    function _buildTimedParams(uint256 startTimestamp, uint256 duration)
        internal
        view
        returns (IUmiaMarketCore.CreateMarketParams memory params)
    {
        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "yes", executionPayload: ""});

        params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "configurable timing market",
            startTimestamp: startTimestamp,
            duration: duration,
            proposals: proposals
        });
    }

    function _createTimedMarket(uint256 startTimestamp, uint256 duration) internal returns (uint256 id) {
        IUmiaMarketCore.CreateMarketParams memory params = _buildTimedParams(startTimestamp, duration);
        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.prank(alice);
        id = mm.createMarket(params, alice, nonce, signature);
    }

    /// @dev Signs and submits with the revert expectation attached to the createMarket call only -
    ///      the nonce read and signing happen first so expectRevert isn't consumed by them.
    function _expectCreateRevert(uint256 startTimestamp, uint256 duration, bytes4 selector) internal {
        IUmiaMarketCore.CreateMarketParams memory params = _buildTimedParams(startTimestamp, duration);
        vm.startPrank(alice);
        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);
        vm.expectRevert(selector);
        mm.createMarket(params, alice, nonce, signature);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // Duration
    // ─────────────────────────────────────────────────────────

    function test_duration_zeroUsesDefault() public {
        uint256 start = block.timestamp + 1 days;
        uint256 id = _createTimedMarket(start, 0);

        (,, uint256 tradingStart, uint256 tradingEnd) = mm.marketInfo(id);
        assertEq(tradingStart, start, "tradingStart should equal requested start");
        assertEq(tradingEnd - tradingStart, DEFAULT_DURATION, "zero duration should default to 3 days");
    }

    function test_duration_customWithinBounds() public {
        uint256 start = block.timestamp + 1 days;
        uint256 id = _createTimedMarket(start, 12 hours);

        (,,, uint256 tradingEnd) = mm.marketInfo(id);
        assertEq(tradingEnd, start + 12 hours, "tradingEnd should honor custom duration");
    }

    function test_duration_minBoundaryAllowed() public {
        uint256 start = block.timestamp + 1 days;
        uint256 id = _createTimedMarket(start, MIN_DURATION);

        (,,, uint256 tradingEnd) = mm.marketInfo(id);
        assertEq(tradingEnd, start + MIN_DURATION, "1h duration should be allowed");
    }

    function test_duration_maxBoundaryAllowed() public {
        uint256 start = block.timestamp + 1 days;
        uint256 id = _createTimedMarket(start, MAX_DURATION);

        (,,, uint256 tradingEnd) = mm.marketInfo(id);
        assertEq(tradingEnd, start + MAX_DURATION, "96h duration should be allowed");
    }

    function test_revert_durationBelowMin() public {
        _expectCreateRevert(block.timestamp + 1 days, MIN_DURATION - 1, IUmiaMarketCore.InvalidDuration.selector);
    }

    function test_revert_durationAboveMax() public {
        _expectCreateRevert(block.timestamp + 1 days, MAX_DURATION + 1, IUmiaMarketCore.InvalidDuration.selector);
    }

    // ─────────────────────────────────────────────────────────
    // Start delay
    // ─────────────────────────────────────────────────────────

    function test_startDelay_zeroOpensImmediately() public {
        uint256 id = _createTimedMarket(0, 0);

        (,, uint256 tradingStart,) = mm.marketInfo(id);
        assertEq(tradingStart, block.timestamp, "zero start should clamp to now");
        assertEq(
            uint256(mm.getMarketStatus(id)),
            uint256(IUmiaMarketCore.MarketStatus.OPEN),
            "market should be open immediately"
        );
    }

    function test_startDelay_pastTimestampClampsToNow() public {
        uint256 id = _createTimedMarket(block.timestamp - 100, 0);

        (,, uint256 tradingStart,) = mm.marketInfo(id);
        assertEq(tradingStart, block.timestamp, "stale start should clamp to now");
    }

    function test_startDelay_maxBoundaryAllowed() public {
        uint256 start = block.timestamp + MAX_START_DELAY;
        uint256 id = _createTimedMarket(start, 0);

        (,, uint256 tradingStart,) = mm.marketInfo(id);
        assertEq(tradingStart, start, "7 day delay should be allowed");
        assertEq(
            uint256(mm.getMarketStatus(id)),
            uint256(IUmiaMarketCore.MarketStatus.PENDING),
            "future market should be pending"
        );
    }

    function test_revert_startDelayTooFarInFuture() public {
        _expectCreateRevert(block.timestamp + MAX_START_DELAY + 1, 0, IUmiaMarketCore.StartTimeTooFarInFuture.selector);
    }
}
