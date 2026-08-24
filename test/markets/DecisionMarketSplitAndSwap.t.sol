// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";

/// @title DecisionMarketSplitAndSwapTest
/// @notice Tests for the atomic splitAndSwapExactIn path
contract DecisionMarketSplitAndSwapTest is DecisionMarketBase {
    function test_splitAndSwap_atomicBuyInOneCall() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);

        assertEq(mm.balanceOf(bob, prop1.virtualVentureId), 0, "No venture tokens before");
        assertEq(mm.balanceOf(bob, prop1.virtualMoneyId), 0, "No money tokens before");

        (uint256 expectedOut,) = mm.quoteSwapExactIn(proposal1Id, 1_000e6, false);

        vm.prank(bob);
        uint256 amountOut = mm.splitAndSwapExactIn(proposal1Id, 0, 1_000e6, 1_000e6, 0, 10000, false, block.timestamp);

        assertEq(amountOut, expectedOut, "Atomic output matches quote taken before split");
        assertEq(mm.balanceOf(bob, prop1.virtualVentureId), amountOut, "Bob received venture from the swap");
        assertEq(mm.balanceOf(bob, prop1.virtualMoneyId), 0, "All split money was swapped in proposal 1");

        _verifyInvariant(marketId);
    }

    function test_splitAndSwap_splitsAcrossAllProposals() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.splitAndSwapExactIn(proposal1Id, 0, 1_000e6, 1_000e6, 0, 10000, false, block.timestamp);

        // Only the traded proposal's money is consumed; every other proposal keeps the split money.
        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 proposalId = market.proposalIds[i];
            Proposal memory prop = _proposalById(proposalId);
            if (proposalId == proposal1Id) continue;
            assertEq(mm.balanceOf(bob, prop.virtualMoneyId), 1_000e6, "Untraded proposal keeps split money");
        }
    }

    function test_splitAndSwap_amountInExceedsSplitUsesExistingBalance() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);

        // Bob already holds 400 virtual money from a prior split.
        vm.prank(bob);
        mm.split(marketId, 0, 400e6);

        // Split 600 more and swap the full 1000 (400 existing + 600 fresh) atomically.
        vm.prank(bob);
        uint256 amountOut = mm.splitAndSwapExactIn(proposal1Id, 0, 600e6, 1_000e6, 0, 10000, false, block.timestamp);

        assertGt(amountOut, 0, "Swap produced output");
        assertEq(mm.balanceOf(bob, prop1.virtualMoneyId), 0, "Both existing and fresh money were swapped");
        assertEq(mm.balanceOf(bob, prop1.virtualVentureId), amountOut, "Bob received venture out");

        _verifyInvariant(marketId);
    }

    function test_splitAndSwap_zeroSplitSwapsExistingOnly() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        uint256 usdcBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        uint256 amountOut = mm.splitAndSwapExactIn(proposal1Id, 0, 0, 500e6, 0, 10000, false, block.timestamp);

        assertGt(amountOut, 0, "Swap produced output");
        assertEq(usdc.balanceOf(bob), usdcBefore, "No real tokens pulled when split amounts are zero");
        assertEq(mm.balanceOf(bob, prop1.virtualMoneyId), 500e6, "Half the existing money remains");

        _verifyInvariant(marketId);
    }

    function test_splitAndSwap_atomicSellVenture() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);

        _mintVenture(hub, venture, bob, 1_000e18);

        (uint256 expectedOut,) = mm.quoteSwapExactIn(proposal1Id, 1_000e18, true);

        vm.prank(bob);
        uint256 amountOut = mm.splitAndSwapExactIn(proposal1Id, 1_000e18, 0, 1_000e18, 0, 10000, true, block.timestamp);

        assertEq(amountOut, expectedOut, "Sell output matches quote taken before split");
        assertEq(mm.balanceOf(bob, prop1.virtualMoneyId), amountOut, "Bob received virtual money from the sell");
        assertEq(mm.balanceOf(bob, prop1.virtualVentureId), 0, "All split venture was swapped in proposal 1");

        _verifyInvariant(marketId);
    }

    function test_splitAndSwap_revertsAfterDeadline() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        vm.expectRevert(IUmiaMarketCore.DeadlineExpired.selector);
        mm.splitAndSwapExactIn(proposal1Id, 0, 1_000e6, 1_000e6, 0, 10000, false, block.timestamp - 1);
    }

    function test_splitAndSwap_revertsAndRollsBackOnSlippage() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);

        (uint256 expectedOut,) = mm.quoteSwapExactIn(proposal1Id, 1_000e6, false);
        uint256 usdcBefore = usdc.balanceOf(bob);

        // amountOutMin one wei above the exact quote forces the swap leg to revert.
        vm.prank(bob);
        vm.expectRevert();
        mm.splitAndSwapExactIn(proposal1Id, 0, 1_000e6, 1_000e6, expectedOut + 1, 10000, false, block.timestamp);

        assertEq(usdc.balanceOf(bob), usdcBefore, "USDC untouched: the split rolled back with the failed swap");
        assertEq(mm.balanceOf(bob, prop1.virtualMoneyId), 0, "No virtual money minted after atomic revert");
    }

    function test_splitAndSwap_revertsAndRollsBackWhenPending() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        // No warp: split allows PENDING but the swap leg requires OPEN, so the whole tx must roll back.
        assertEq(
            uint8(mm.getMarketStatus(marketId)),
            uint8(IUmiaMarketCore.MarketStatus.PENDING),
            "Market is pending before trading start"
        );

        uint256 usdcBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        vm.expectRevert(IUmiaMarketCore.MarketNotOpen.selector);
        mm.splitAndSwapExactIn(proposal1Id, 0, 1_000e6, 1_000e6, 0, 10000, false, block.timestamp);

        assertEq(usdc.balanceOf(bob), usdcBefore, "USDC untouched: the split rolled back with the failed swap");
        assertEq(mm.balanceOf(bob, prop1.virtualMoneyId), 0, "No virtual money minted after atomic revert");
    }

    function test_splitAndSwap_revertsOnUnknownProposal() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days + 1);

        // Proposal 999_999 maps to no market, so the split leg must not execute.
        vm.prank(bob);
        vm.expectRevert(IUmiaMarketCore.ProposalNotFound.selector);
        mm.splitAndSwapExactIn(999_999, 0, 1_000e6, 1_000e6, 0, 10000, false, block.timestamp);
    }
}
