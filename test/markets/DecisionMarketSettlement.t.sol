// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";

/// @title DecisionMarketSettlementTest
/// @notice Tests for settlement, claims, and related edge cases
contract DecisionMarketSettlementTest is DecisionMarketBase {
    function test_claim_doubleClaimReverts() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        Market memory market = _marketById(marketId);
        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        vm.prank(bob);
        mm.claimSettlement(marketId);

        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketCore.AlreadyClaimed.selector));
        vm.prank(bob);
        mm.claimSettlement(marketId);
    }

    function test_claim_onlyWinningProposalMatters() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 noopId = market.proposalIds[0];
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 bobMoneyInProp1 = mm.balanceOf(bob, prop1.virtualMoneyId);
        _swapExactIn(bob, proposal1Id, bobMoneyInProp1 / 2, false);

        Proposal memory noop = _proposalById(noopId);
        uint256 bobNoopMoney = mm.balanceOf(bob, noop.virtualMoneyId);
        uint256 bobNoopVenture = mm.balanceOf(bob, noop.virtualVentureId);
        uint256 bobProp1Money = mm.balanceOf(bob, prop1.virtualMoneyId);
        uint256 bobProp1Venture = mm.balanceOf(bob, prop1.virtualVentureId);

        assertGt(bobProp1Venture, 0, "Bob should have venture in proposal1");
        assertEq(bobNoopVenture, 0, "Bob should have no venture in noop (never traded there)");

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobVentureBefore = IERC20(ventureToken).balanceOf(bob);

        vm.prank(bob);
        mm.claimSettlement(marketId);

        uint256 expectedMoney;
        uint256 expectedVenture;

        if (winning.proposalId == noopId) {
            expectedMoney = bobNoopMoney;
            expectedVenture = bobNoopVenture;
        } else {
            expectedMoney = bobProp1Money;
            expectedVenture = bobProp1Venture;
        }

        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, expectedMoney, "Claim should be from winning proposal");
        assertEq(
            IERC20(ventureToken).balanceOf(bob) - bobVentureBefore,
            expectedVenture,
            "venture claim should be from winning proposal"
        );
    }

    function test_claim_noClaimableTokensReverts() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(charlie);
        mm.split(marketId, 0, 1_000e6);

        Market memory market = _marketById(marketId);
        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketCore.NoClaimableTokens.selector));
        vm.prank(bob);
        mm.claimSettlement(marketId);

        vm.prank(charlie);
        mm.claimSettlement(marketId);
    }

    function test_claim_beforeSettlementReverts() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketCore.MarketNotEnded.selector));
        vm.prank(bob);
        mm.claimSettlement(marketId);
    }

    function test_edge_settlementWithNoTrades() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        _verifyInvariant(marketId);

        Market memory market = _marketById(marketId);
        vm.warp(market.tradingEnd + 1);

        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);
        assertTrue(winning.proposalId != 0, "Market should be settled");

        Proposal memory winningProp = _proposalById(winning.proposalId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, winningProp.virtualMoneyId);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        mm.claimSettlement(marketId);

        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, bobVirtualMoney, "Bob should get money back");
    }

    function test_edge_allUsersBetSameProposal() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);
        _setupTrader(dave);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);
        vm.prank(charlie);
        mm.split(marketId, 0, 1_000e6);
        vm.prank(dave);
        mm.split(marketId, 0, 1_000e6);

        _swapExactIn(bob, proposal1Id, 100e6, false);
        _swapExactIn(charlie, proposal1Id, 100e6, false);
        _swapExactIn(dave, proposal1Id, 100e6, false);

        _verifyInvariant(marketId);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);
        Proposal memory winningProp = _proposalById(winning.proposalId);

        uint256 bobVirtualVenture = mm.balanceOf(bob, winningProp.virtualVentureId);
        uint256 bobVirtualMoney = mm.balanceOf(bob, winningProp.virtualMoneyId);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobVentureBefore = IERC20(ventureToken).balanceOf(bob);

        vm.prank(bob);
        mm.claimSettlement(marketId);
        vm.prank(charlie);
        mm.claimSettlement(marketId);
        vm.prank(dave);
        mm.claimSettlement(marketId);

        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, bobVirtualMoney, "Bob should receive USDC");
        assertEq(
            IERC20(ventureToken).balanceOf(bob) - bobVentureBefore, bobVirtualVenture, "Bob should receive venture"
        );

        assertEq(mm.balanceOf(bob, winningProp.virtualVentureId), 0, "Virtual venture should be burned");
        assertEq(mm.balanceOf(bob, winningProp.virtualMoneyId), 0, "Virtual Money should be burned");
    }

    function test_settleMarket_sendsLeftoversToVenture() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);
        _swapExactIn(bob, proposal1Id, 2_000e6, false);

        address _ventureToken = Venture(payable(venture)).token();
        address _moneyToken = Venture(payable(venture)).moneyToken();
        address vault = hub.ventureLiquidityVault(venture);
        uint128 vaultLiqBefore = ISpotLiquidityVault(vault).currentLiquidity();
        uint256 vaultVentureBefore = IERC20(_ventureToken).balanceOf(vault);
        uint256 vaultMoneyBefore = IERC20(_moneyToken).balanceOf(vault);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        // Settlement excess returns to the vault: folded into the position as liquidity when
        // two-sided, kept as idle when one-sided. Either way the vault's holdings grow.
        bool returnedToVault = ISpotLiquidityVault(vault).currentLiquidity() > vaultLiqBefore
            || IERC20(_ventureToken).balanceOf(vault) > vaultVentureBefore
            || IERC20(_moneyToken).balanceOf(vault) > vaultMoneyBefore;
        assertTrue(returnedToVault, "Settlement should return excess liquidity to the vault");
    }

    function test_settleMarket_noTokensStuckInMarketCore() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);
        vm.prank(charlie);
        mm.split(marketId, 0, 5_000e6);
        _swapExactIn(bob, proposal1Id, 3_000e6, false);

        address _ventureToken = Venture(payable(venture)).token();
        address _moneyToken = Venture(payable(venture)).moneyToken();

        uint256 mmVentureBefore = IERC20(_ventureToken).balanceOf(address(mm));
        uint256 mmMoneyBefore = IERC20(_moneyToken).balanceOf(address(mm));

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        vm.prank(bob);
        mm.claimSettlement(marketId);
        vm.prank(charlie);
        mm.claimSettlement(marketId);

        uint256 mmVentureAfter = IERC20(_ventureToken).balanceOf(address(mm));
        uint256 mmMoneyAfter = IERC20(_moneyToken).balanceOf(address(mm));

        uint256 ventureRemaining = mmVentureAfter > mmVentureBefore ? mmVentureAfter - mmVentureBefore : 0;
        uint256 moneyRemaining = mmMoneyAfter > mmMoneyBefore ? mmMoneyAfter - mmMoneyBefore : 0;

        assertLe(ventureRemaining, 2, "No more than dust venture should remain in MarketCore");
        assertLe(moneyRemaining, 2, "No more than dust money should remain in MarketCore");
    }

    function test_settleMarket_heavilyImbalancedRatio() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        // Heavy one-sided trading to create extreme ratio imbalance
        _swapExactIn(bob, proposal1Id, 4_000e6, false);
        _swapExactIn(bob, proposal1Id, 1_000e6, true);
        _swapExactIn(bob, proposal1Id, 2_000e6, false);

        address _ventureToken = Venture(payable(venture)).token();
        address _moneyToken = Venture(payable(venture)).moneyToken();
        address vault = hub.ventureLiquidityVault(venture);
        uint128 vaultLiqBefore = ISpotLiquidityVault(vault).currentLiquidity();
        uint256 vaultVentureBefore = IERC20(_ventureToken).balanceOf(vault);
        uint256 vaultMoneyBefore = IERC20(_moneyToken).balanceOf(vault);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        bool returnedToVault = ISpotLiquidityVault(vault).currentLiquidity() > vaultLiqBefore
            || IERC20(_ventureToken).balanceOf(vault) > vaultVentureBefore
            || IERC20(_moneyToken).balanceOf(vault) > vaultMoneyBefore;
        assertTrue(returnedToVault, "Settlement should return excess to the vault even with extreme imbalance");
    }

    function test_settleMarket_minimalSplitStillSettles() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);

        vm.warp(block.timestamp + 1 days + 1);

        // Tiny split — near-zero amounts going to reAddLiquidity
        vm.prank(bob);
        mm.split(marketId, 0, 1e6);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        vm.prank(bob);
        mm.claimSettlement(marketId);
    }
}
