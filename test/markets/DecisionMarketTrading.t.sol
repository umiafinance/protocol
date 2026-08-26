// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";

/// @title DecisionMarketTradingTest
/// @notice Tests for split, merge, and multi-user trading
contract DecisionMarketTradingTest is DecisionMarketBase {
    function test_multiUserTrading_tokenAccountingPreserved() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        (, uint256 initMoneySupply) = _getTotalVirtualSupply(proposal1Id);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        vm.prank(charlie);
        mm.split(marketId, 0, 2_000e6);

        _verifyInvariant(marketId);

        (uint256 afterSplitVenture, uint256 afterSplitMoney) = _getTotalVirtualSupply(proposal1Id);
        assertEq(afterSplitMoney, initMoneySupply + 3_000e6, "Money supply should increase by split amounts");

        uint256 bobBuyAmount = 100e6;
        _swapExactIn(bob, proposal1Id, bobBuyAmount, false);

        (uint256 afterBobSwapVenture, uint256 afterBobSwapMoney) = _getTotalVirtualSupply(proposal1Id);
        assertEq(afterBobSwapVenture, afterSplitVenture, "venture supply should not change after swap");
        assertEq(afterBobSwapMoney, afterSplitMoney, "Money supply should not change after swap");

        _swapExactIn(charlie, proposal1Id, 200e6, false);

        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 charlieVenture = mm.balanceOf(charlie, prop1.virtualVentureId);
        _swapExactIn(charlie, proposal1Id, charlieVenture / 2, true);

        (uint256 finalVenture, uint256 finalMoney) = _getTotalVirtualSupply(proposal1Id);
        assertEq(finalVenture, afterSplitVenture, "venture supply should remain constant through swaps");
        assertEq(finalMoney, afterSplitMoney, "Money supply should remain constant through swaps");

        _verifyInvariant(marketId);
    }

    function test_transfer_toAnotherUserSucceeds() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        uint256 amount = mm.balanceOf(bob, prop1.virtualVentureId);
        vm.prank(bob);
        mm.transfer(charlie, prop1.virtualVentureId, amount);

        assertEq(mm.balanceOf(bob, prop1.virtualVentureId), 0, "sender balance not debited");
        assertEq(mm.balanceOf(charlie, prop1.virtualVentureId), amount, "recipient balance not credited");
    }

    function test_transfer_toCoreOrZeroReverts() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        uint256 amount = mm.balanceOf(bob, prop1.virtualVentureId);

        // Transferring virtual tokens into the core would strand the backing real tokens.
        vm.prank(bob);
        vm.expectRevert(IUmiaMarketCore.InvalidRecipient.selector);
        mm.transfer(address(mm), prop1.virtualVentureId, amount);

        vm.prank(bob);
        vm.expectRevert(IUmiaMarketCore.InvalidRecipient.selector);
        mm.transfer(address(0), prop1.virtualVentureId, amount);
    }

    function test_multiUserTrading_bothClaimSuccessfully() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);
        vm.prank(charlie);
        mm.split(marketId, 0, 2_000e6);

        _swapExactIn(bob, proposal1Id, 100e6, false);
        _swapExactIn(charlie, proposal1Id, 150e6, false);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);
        Proposal memory winningProp = _proposalById(winning.proposalId);

        uint256 bobVirtualVenture = mm.balanceOf(bob, winningProp.virtualVentureId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, winningProp.virtualMoneyId);
        uint256 charlieVirtualVenture = mm.balanceOf(charlie, winningProp.virtualVentureId);
        uint256 charlieVirtualMoney = mm.balanceOf(charlie, winningProp.virtualMoneyId);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobVentureBefore = IERC20(ventureToken).balanceOf(bob);
        uint256 charlieUsdcBefore = usdc.balanceOf(charlie);
        uint256 charlieVentureBefore = IERC20(ventureToken).balanceOf(charlie);

        vm.prank(bob);
        mm.claimSettlement(marketId);
        vm.prank(charlie);
        mm.claimSettlement(marketId);

        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, bobVirtualMoney, "Bob USDC claim incorrect");
        assertEq(
            IERC20(ventureToken).balanceOf(bob) - bobVentureBefore, bobVirtualVenture, "Bob venture claim incorrect"
        );
        assertEq(usdc.balanceOf(charlie) - charlieUsdcBefore, charlieVirtualMoney, "Charlie USDC claim incorrect");
        assertEq(
            IERC20(ventureToken).balanceOf(charlie) - charlieVentureBefore,
            charlieVirtualVenture,
            "Charlie venture claim incorrect"
        );

        assertEq(mm.balanceOf(bob, winningProp.virtualVentureId), 0, "Bob virtual venture not burned");
        assertEq(mm.balanceOf(bob, winningProp.virtualMoneyId), 0, "Bob virtual Money not burned");
        assertEq(mm.balanceOf(charlie, winningProp.virtualVentureId), 0, "Charlie virtual venture not burned");
        assertEq(mm.balanceOf(charlie, winningProp.virtualMoneyId), 0, "Charlie virtual Money not burned");
    }

    function test_edge_mergeAfterPartialTrading() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        uint256 noopId = market.proposalIds[0];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        _swapExactIn(bob, proposal1Id, 100e6, false);

        Proposal memory prop1 = _proposalById(proposal1Id);
        Proposal memory noop = _proposalById(noopId);

        uint256 bobProp1Money = mm.balanceOf(bob, prop1.virtualMoneyId);
        uint256 bobNoopMoney = mm.balanceOf(bob, noop.virtualMoneyId);

        uint256 mergeableAmount = bobProp1Money < bobNoopMoney ? bobProp1Money : bobNoopMoney;

        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        uint256 mergeAmount = mergeableAmount / 2;
        vm.prank(bob);
        mm.merge(marketId, 0, mergeAmount);

        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, mergeAmount, "Bob should receive merged USDC");

        assertEq(mm.balanceOf(bob, prop1.virtualMoneyId), bobProp1Money - mergeAmount, "Prop1 money should decrease");
        assertEq(mm.balanceOf(bob, noop.virtualMoneyId), bobNoopMoney - mergeAmount, "Noop money should decrease");

        _verifyInvariant(marketId);
    }

    function test_edge_mergeRequiresEqualAcrossProposals() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        _swapExactIn(bob, proposal1Id, 500e6, false);

        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketCore.InsufficientVirtualTokens.selector));
        vm.prank(bob);
        mm.merge(marketId, 0, 600e6);
    }

    function test_accounting_realBalancesTrackDeposits() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        vm.warp(block.timestamp + 1 days + 1);

        uint256 realMoneyBefore = _realMoneyBalance(marketId);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);
        assertEq(_realMoneyBalance(marketId), realMoneyBefore + 1_000e6, "Real balance should increase");

        vm.prank(charlie);
        mm.split(marketId, 0, 500e6);
        assertEq(_realMoneyBalance(marketId), realMoneyBefore + 1_500e6, "Real balance should track all deposits");

        vm.prank(bob);
        mm.merge(marketId, 0, 300e6);
        assertEq(_realMoneyBalance(marketId), realMoneyBefore + 1_200e6, "Real balance should decrease on merge");
    }

    function test_accounting_userSupplyTracksCorrectly() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        assertEq(mm.userVirtualMoneySupply(proposal1Id), 0, "Initial user supply should be 0");

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);
        assertEq(mm.userVirtualMoneySupply(proposal1Id), 1_000e6, "User supply should match split");

        uint256 userMoneyBefore = mm.userVirtualMoneySupply(proposal1Id);
        uint256 userVentureBefore = mm.userVirtualVentureSupply(proposal1Id);

        uint256 swapAmountIn = 100e6;
        uint256 amountOut = _swapExactIn(bob, proposal1Id, swapAmountIn, false);

        assertEq(
            mm.userVirtualMoneySupply(proposal1Id),
            userMoneyBefore - swapAmountIn,
            "User money supply should decrease by swap input"
        );
        assertEq(
            mm.userVirtualVentureSupply(proposal1Id),
            userVentureBefore + amountOut,
            "User UMO supply should increase by swap output"
        );
    }
}
