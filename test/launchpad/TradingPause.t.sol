// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {Venture} from "../../src/core/Venture.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";

contract TradingPauseTest is DecisionMarketBase {
    function setUp() public override {
        super.setUp();
    }

    // ─────────────────────────────────────────────────────────
    // No pause (default behavior)
    // ─────────────────────────────────────────────────────────

    function test_noPause_tokenTransfersWorkAfterMigration() public {
        (, address payable ventureAddr) = _createVentureWithLBP(hub, alice);
        address token = Venture(payable(ventureAddr)).token();

        _mintVenture(hub, ventureAddr, alice, 1000e18);

        vm.prank(alice);
        IERC20(token).transfer(bob, 100e18);

        assertEq(IERC20(token).balanceOf(bob), 100e18);
    }

    function test_noPause_tradingPauseDeadlineIsZero() public {
        (, address payable ventureAddr) = _createVentureWithLBP(hub, alice);

        assertEq(Venture(payable(ventureAddr)).tradingPauseDeadline(), 0);
        assertEq(Venture(payable(ventureAddr)).tradingPauseDuration(), 0);
    }

    // ─────────────────────────────────────────────────────────
    // With pause
    // ─────────────────────────────────────────────────────────

    function test_pause_tokenPausedAfterMigration() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 30 days);
        address token = Venture(payable(ventureAddr)).token();

        assertTrue(VentureToken(token).paused());
        assertGt(Venture(payable(ventureAddr)).tradingPauseDeadline(), 0);
    }

    function test_pause_transfersBlocked() public {
        (, address payable ventureAddr) = _createVentureWithPauseAndMint(alice, 30 days, alice, 1000e18);
        address token = Venture(payable(ventureAddr)).token();

        vm.prank(alice);
        vm.expectRevert();
        IERC20(token).transfer(bob, 100e18);

        assertTrue(VentureToken(token).paused());
    }

    function test_pause_teamMemberCanUnpauseEarly() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 30 days);
        address token = Venture(payable(ventureAddr)).token();

        vm.prank(alice);
        Venture(payable(ventureAddr)).startTrading();

        assertFalse(VentureToken(token).paused());
        assertEq(Venture(payable(ventureAddr)).tradingPauseDeadline(), 0);
    }

    function test_pause_nonTeamMemberCannotUnpauseEarly() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 30 days);

        vm.prank(bob);
        vm.expectRevert(IVenture.TradingPauseNotExpired.selector);
        Venture(payable(ventureAddr)).startTrading();
    }

    function test_pause_anyoneCanUnpauseAfterDeadline() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 30 days);
        address token = Venture(payable(ventureAddr)).token();

        vm.warp(block.timestamp + 30 days);

        vm.prank(bob);
        Venture(payable(ventureAddr)).startTrading();

        assertFalse(VentureToken(token).paused());
    }

    function test_pause_cannotUnpauseTwice() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 30 days);

        vm.prank(alice);
        Venture(payable(ventureAddr)).startTrading();

        vm.prank(alice);
        vm.expectRevert(IVenture.TradingNotPaused.selector);
        Venture(payable(ventureAddr)).startTrading();
    }

    function test_pause_transfersWorkAfterUnpause() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 30 days);
        address token = Venture(payable(ventureAddr)).token();

        vm.prank(alice);
        Venture(payable(ventureAddr)).startTrading();

        _mintVenture(hub, ventureAddr, alice, 1000e18);

        vm.prank(alice);
        IERC20(token).transfer(bob, 100e18);

        assertEq(IERC20(token).balanceOf(bob), 100e18);
    }

    function test_pause_emitsEvent() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 30 days);

        vm.expectEmit(true, false, false, false);
        emit IVenture.TradingStarted(alice);

        vm.prank(alice);
        Venture(payable(ventureAddr)).startTrading();
    }

    function test_pause_deadlineSetCorrectly() public {
        (, address payable ventureAddr) = _createVentureWithPause(alice, 30 days);

        assertEq(Venture(payable(ventureAddr)).tradingPauseDuration(), 30 days);
        // Deadline should be roughly block.timestamp + 30 days (set during onLBPMigrated)
        assertGt(Venture(payable(ventureAddr)).tradingPauseDeadline(), block.timestamp);
    }

    // ─────────────────────────────────────────────────────────
    // Validation
    // ─────────────────────────────────────────────────────────

    function test_pause_revertIfDurationTooLong() public {
        LBPBlockConfig memory blocks = _defaultBlockConfig();

        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(umiaAdmin);
        vm.expectRevert(IVenture.TradingPauseDurationTooLong.selector);
        hub.createVenture(
            IUmiaHub.CreateVentureParams({
                name: "testVenture",
                symbol: "TEST",
                initialSupply: 1_000_000e18,
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 61 days,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_pause_unpauseNotPossibleWithoutPause() public {
        (, address payable ventureAddr) = _createVentureWithLBP(hub, alice);

        vm.prank(alice);
        vm.expectRevert(IVenture.TradingNotPaused.selector);
        Venture(payable(ventureAddr)).startTrading();
    }

    // ─────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────

    function _createVentureWithPause(address creator, uint256 pauseDuration)
        internal
        returns (uint256 id, address payable ventureAddr)
    {
        LBPBlockConfig memory blocks = _defaultBlockConfig();

        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = creator;

        vm.prank(hub.owner());
        (id, ventureAddr) = hub.createVenture(
            IUmiaHub.CreateVentureParams({
                name: "pauseVenture",
                symbol: "PAUSE",
                initialSupply: 1_000_000e18,
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: pauseDuration,
                startingMonthlyAllowance: 0
            })
        );

        _runAuctionAndMigrate(Venture(payable(ventureAddr)).lbp(), blocks);
    }

    function _createVentureWithPauseAndMint(address creator, uint256 pauseDuration, address mintTo, uint256 mintAmount)
        internal
        returns (uint256 id, address payable ventureAddr)
    {
        LBPBlockConfig memory blocks = _defaultBlockConfig();

        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = creator;

        vm.prank(hub.owner());
        (id, ventureAddr) = hub.createVenture(
            IUmiaHub.CreateVentureParams({
                name: "pauseVenture",
                symbol: "PAUSE",
                initialSupply: 1_000_000e18,
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: pauseDuration,
                startingMonthlyAllowance: 0
            })
        );

        // Mint tokens before migration (before pause starts)
        _mintVenture(hub, ventureAddr, mintTo, mintAmount);

        _runAuctionAndMigrate(Venture(payable(ventureAddr)).lbp(), blocks);
    }
}
