// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";

/// @title DecisionMarketLiquidityTest
/// @notice Tests for liquidity provision in decision markets
contract DecisionMarketLiquidityTest is DecisionMarketBase {
    function test_liquidity_addLiquidityIncreasesReserves() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        _swapExactIn(bob, proposal1Id, 10_000e6, false);

        (uint256 reserve0Before, uint256 reserve1Before) = mm.cpmmStates(proposal1Id);

        uint256 priceX96 = mm.getPriceX96(proposal1Id, true);

        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 bobVirtualVenture = mm.balanceOf(bob, prop1.virtualVentureId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, prop1.virtualMoneyId);

        uint256 addAmount0 = bobVirtualVenture / 4;
        uint256 addAmount1 = bobVirtualMoney / 4;

        vm.prank(bob);
        mm.addLiquidity(proposal1Id, addAmount0, addAmount1, priceX96, 1000);

        (uint256 reserve0After, uint256 reserve1After) = mm.cpmmStates(proposal1Id);

        assertGt(reserve0After, reserve0Before, "Reserve0 should increase");
        assertGt(reserve1After, reserve1Before, "Reserve1 should increase");

        _verifyInvariant(marketId);
    }

    function test_liquidity_addLiquidityDecreasesUserSupply() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        _swapExactIn(bob, proposal1Id, 10_000e6, false);

        uint256 userVentureSupplyBefore = mm.userVirtualVentureSupply(proposal1Id);
        uint256 userMoneySupplyBefore = mm.userVirtualMoneySupply(proposal1Id);

        uint256 priceX96 = mm.getPriceX96(proposal1Id, true);
        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 bobVirtualVenture = mm.balanceOf(bob, prop1.virtualVentureId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, prop1.virtualMoneyId);

        vm.prank(bob);
        mm.addLiquidity(proposal1Id, bobVirtualVenture / 4, bobVirtualMoney / 4, priceX96, 1000);

        uint256 userVentureSupplyAfter = mm.userVirtualVentureSupply(proposal1Id);
        uint256 userMoneySupplyAfter = mm.userVirtualMoneySupply(proposal1Id);

        assertLt(userVentureSupplyAfter, userVentureSupplyBefore, "User venture supply should decrease");
        assertLt(userMoneySupplyAfter, userMoneySupplyBefore, "User Money supply should decrease");

        _verifyInvariant(marketId);
    }

    function test_liquidity_addLiquidityThenTrade() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);
        vm.prank(charlie);
        mm.split(marketId, 0, 10_000e6);

        _swapExactIn(bob, proposal1Id, 10_000e6, false);

        (uint256 totalVentureBefore, uint256 totalMoneyBefore) = _getTotalVirtualSupply(proposal1Id);

        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 bobVirtualVenture = mm.balanceOf(bob, prop1.virtualVentureId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, prop1.virtualMoneyId);

        uint256 priceX96 = mm.getPriceX96(proposal1Id, true);
        vm.prank(bob);
        mm.addLiquidity(proposal1Id, bobVirtualVenture / 4, bobVirtualMoney / 4, priceX96, 1000);

        (uint256 totalVentureAfterLP, uint256 totalMoneyAfterLP) = _getTotalVirtualSupply(proposal1Id);
        assertEq(totalVentureAfterLP, totalVentureBefore, "Total venture supply unchanged after LP");
        assertEq(totalMoneyAfterLP, totalMoneyBefore, "Total Money supply unchanged after LP");

        _swapExactIn(charlie, proposal1Id, 500e6, false);

        (uint256 totalVentureAfterTrade, uint256 totalMoneyAfterTrade) = _getTotalVirtualSupply(proposal1Id);
        assertEq(totalVentureAfterTrade, totalVentureBefore, "Total venture supply unchanged after trade");
        assertEq(totalMoneyAfterTrade, totalMoneyBefore, "Total Money supply unchanged after trade");

        _verifyInvariant(marketId);
    }

    function test_liquidity_lpAndTradersBothClaim() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        vm.prank(charlie);
        mm.split(marketId, 0, 10_000e6);

        _swapExactIn(bob, proposal1Id, 10_000e6, false);

        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 bobVirtualVenture = mm.balanceOf(bob, prop1.virtualVentureId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, prop1.virtualMoneyId);

        uint256 priceX96 = mm.getPriceX96(proposal1Id, true);
        vm.prank(bob);
        mm.addLiquidity(proposal1Id, bobVirtualVenture / 2, bobVirtualMoney / 2, priceX96, 1000);

        _swapExactIn(charlie, proposal1Id, 1_000e6, false);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);
        Proposal memory winningProp = _proposalById(winning.proposalId);
        assertEq(winning.proposalId, proposal1Id, "LP regression assumes proposal 1 wins");

        uint256 bobVirtualVentureWinning = mm.balanceOf(bob, winningProp.virtualVentureId);
        uint256 bobVirtualMoneyWinning = mm.balanceOf(bob, winningProp.virtualMoneyId);
        uint256 charlieVirtualVentureWinning = mm.balanceOf(charlie, winningProp.virtualVentureId);
        uint256 charlieVirtualMoneyWinning = mm.balanceOf(charlie, winningProp.virtualMoneyId);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobVentureBefore = IERC20(ventureToken).balanceOf(bob);
        uint256 charlieUsdcBefore = usdc.balanceOf(charlie);
        uint256 charlieVentureBefore = IERC20(ventureToken).balanceOf(charlie);

        vm.prank(bob);
        mm.claimSettlement(marketId);
        vm.prank(charlie);
        mm.claimSettlement(marketId);

        assertGt(
            usdc.balanceOf(bob) - bobUsdcBefore,
            bobVirtualMoneyWinning,
            "Bob (LP) USDC claim should exceed wallet balance-only claim"
        );
        assertGt(
            IERC20(ventureToken).balanceOf(bob) - bobVentureBefore,
            bobVirtualVentureWinning,
            "Bob (LP) venture claim should exceed wallet balance-only claim"
        );
        assertEq(usdc.balanceOf(charlie) - charlieUsdcBefore, charlieVirtualMoneyWinning, "Charlie (trader) USDC claim");
        assertEq(
            IERC20(ventureToken).balanceOf(charlie) - charlieVentureBefore,
            charlieVirtualVentureWinning,
            "Charlie (trader) UMO claim"
        );
    }

    function test_liquidity_lpReducesUserClaimableInWinningProposal() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        uint256 noopId = market.proposalIds[0];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        _swapExactIn(bob, proposal1Id, 10_000e6, false);

        Proposal memory prop1 = _proposalById(proposal1Id);
        Proposal memory noop = _proposalById(noopId);

        uint256 bobProp1VentureBefore = mm.balanceOf(bob, prop1.virtualVentureId);
        uint256 bobProp1MoneyBefore = mm.balanceOf(bob, prop1.virtualMoneyId);
        uint256 bobNoopVentureBefore = mm.balanceOf(bob, noop.virtualVentureId);
        uint256 bobNoopMoneyBefore = mm.balanceOf(bob, noop.virtualMoneyId);

        uint256 priceX96 = mm.getPriceX96(proposal1Id, true);
        vm.prank(bob);
        mm.addLiquidity(proposal1Id, bobProp1VentureBefore / 4, bobProp1MoneyBefore / 4, priceX96, 1000);

        uint256 bobProp1VentureAfter = mm.balanceOf(bob, prop1.virtualVentureId);
        uint256 bobProp1MoneyAfter = mm.balanceOf(bob, prop1.virtualMoneyId);
        assertLt(bobProp1VentureAfter, bobProp1VentureBefore, "Prop1 venture should decrease");
        assertLt(bobProp1MoneyAfter, bobProp1MoneyBefore, "Prop1 Money should decrease");

        uint256 bobNoopVentureAfter = mm.balanceOf(bob, noop.virtualVentureId);
        uint256 bobNoopMoneyAfter = mm.balanceOf(bob, noop.virtualMoneyId);
        assertEq(bobNoopVentureAfter, bobNoopVentureBefore, "Noop venture should be unchanged");
        assertEq(bobNoopMoneyAfter, bobNoopMoneyBefore, "Noop Money should be unchanged");

        _verifyInvariant(marketId);
    }

    function test_liquidity_multipleUsersAddLiquidity() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);
        vm.prank(charlie);
        mm.split(marketId, 0, 50_000e6);

        _swapExactIn(bob, proposal1Id, 10_000e6, false);
        _swapExactIn(charlie, proposal1Id, 10_000e6, false);

        (uint256 totalVentureBefore, uint256 totalMoneyBefore) = _getTotalVirtualSupply(proposal1Id);

        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 bobVirtualVenture = mm.balanceOf(bob, prop1.virtualVentureId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, prop1.virtualMoneyId);
        uint256 charlieVirtualVenture = mm.balanceOf(charlie, prop1.virtualVentureId);
        uint256 charlieVirtualMoney = mm.balanceOf(charlie, prop1.virtualMoneyId);

        uint256 priceX96 = mm.getPriceX96(proposal1Id, true);

        vm.prank(bob);
        mm.addLiquidity(proposal1Id, bobVirtualVenture / 4, bobVirtualMoney / 4, priceX96, 1000);

        vm.prank(charlie);
        mm.addLiquidity(proposal1Id, charlieVirtualVenture / 4, charlieVirtualMoney / 4, priceX96, 1000);

        (uint256 totalVentureAfter, uint256 totalMoneyAfter) = _getTotalVirtualSupply(proposal1Id);
        assertEq(totalVentureAfter, totalVentureBefore, "Total venture supply unchanged");
        assertEq(totalMoneyAfter, totalMoneyBefore, "Total Money supply unchanged");

        _verifyInvariant(marketId);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        vm.prank(bob);
        mm.claimSettlement(marketId);
        vm.prank(charlie);
        mm.claimSettlement(marketId);
    }

    function test_liquidity_addLiquidityBeforeMarketOpenReverts() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketCore.MarketNotOpen.selector));
        vm.prank(bob);
        mm.addLiquidity(proposal1Id, 100e18, 50e6, FixedPoint96.Q96 / 2, 500);
    }

    function test_liquidity_deepLiquidityReducesPriceImpact() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 100_000e6);

        vm.prank(charlie);
        mm.split(marketId, 0, 10_000e6);

        _swapExactIn(bob, proposal1Id, 30_000e6, false);

        (uint256 expectedOut1, uint256 priceImpact1) = mm.quoteSwapExactIn(proposal1Id, 1_000e6, false);

        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 bobVirtualVenture = mm.balanceOf(bob, prop1.virtualVentureId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, prop1.virtualMoneyId);

        uint256 priceX96 = mm.getPriceX96(proposal1Id, true);
        vm.prank(bob);
        mm.addLiquidity(proposal1Id, bobVirtualVenture / 2, bobVirtualMoney / 2, priceX96, 1000);

        (uint256 expectedOut2, uint256 priceImpact2) = mm.quoteSwapExactIn(proposal1Id, 1_000e6, false);

        assertLt(priceImpact2, priceImpact1, "Price impact should be lower with deeper liquidity");
        assertGt(expectedOut2, expectedOut1, "Should get more output with deeper liquidity");

        _verifyInvariant(marketId);
    }
}
