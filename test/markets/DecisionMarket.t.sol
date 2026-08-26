// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {IUmiaMarketStake} from "../../src/interfaces/IUmiaMarketStake.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {Venture} from "../../src/core/Venture.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title DecisionMarketTest
/// @notice Basic flow and market stake tests for decision markets
contract DecisionMarketTest is DecisionMarketBase {
    function test_basicFlow() public {
        uint256 initialSupply = 1_000_000e18;

        (uint256 _ventureId, address payable _venture) =
            _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", initialSupply);

        address _ventureToken = Venture(_venture).token();
        vm.label(_ventureToken, "ALICE");

        _warmSpotOracle(_venture);

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(_ventureId, MIN_MARKET_STAKE);

        _mintVenture(hub, _venture, alice, MIN_MARKET_STAKE);

        vm.startPrank(alice);

        IERC20(_ventureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(_ventureId);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] =
            IUmiaMarketCore.CreateProposalParams({title: "yes, cut yearly emissions by 10%", executionPayload: ""});
        proposals[1] =
            IUmiaMarketCore.CreateProposalParams({title: "yes, cut yearly emissions by 15%", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "should we cut yearly emissions?",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        uint256 _marketId = mm.createMarket(params, alice, nonce, signature);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);

        mm.split(_marketId, 0, 1_000e6);

        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 1_000e6);

        Market memory market = _marketById(_marketId);

        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory proposal1 = _proposalById(proposal1Id);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal1.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 10;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposal1Id, buyAmount, false);

        uint256 maxPriceImpactBps = 1000;
        if (priceImpact > maxPriceImpactBps) {
            buyAmount = virtualMoneyBalance / 20;
            (expectedOut, priceImpact) = mm.quoteSwapExactIn(proposal1Id, buyAmount, false);
            maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        }

        uint256 amountOutMin = expectedOut * 99 / 100;

        uint256 virtualVentureReceived =
            mm.swapExactIn(proposal1Id, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);

        uint256 sellAmount = virtualVentureReceived / 4;

        (uint256 expectedMoneyOut, uint256 sellPriceImpact) = mm.quoteSwapExactIn(proposal1Id, sellAmount, true);
        uint256 moneyOutMin = expectedMoneyOut * 99 / 100;

        uint256 sellMaxPriceImpactBps = sellPriceImpact > 1000 ? sellPriceImpact + 100 : 1000;

        mm.swapExactIn(proposal1Id, sellAmount, moneyOutMin, sellMaxPriceImpactBps, true, block.timestamp);

        vm.stopPrank();

        Market memory marketAfterTrading = _marketById(_marketId);
        vm.warp(marketAfterTrading.tradingEnd + 1);

        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertTrue(winning.proposalId != 0, "Market should be settled");

        vm.startPrank(bob);

        Proposal memory winningProposal = _proposalById(winning.proposalId);
        uint256 virtualVentureBalanceBefore = mm.balanceOf(bob, winningProposal.virtualVentureId);
        uint256 virtualMoneyBalanceBefore = mm.balanceOf(bob, winningProposal.virtualMoneyId);

        uint256 ventureTokenBalanceBefore = IERC20(_ventureToken).balanceOf(bob);
        uint256 usdcBalanceBefore = usdc.balanceOf(bob);

        mm.claimSettlement(_marketId);

        uint256 ventureTokenBalanceAfter = IERC20(_ventureToken).balanceOf(bob);
        uint256 usdcBalanceAfter = usdc.balanceOf(bob);

        assertEq(
            ventureTokenBalanceAfter - ventureTokenBalanceBefore,
            virtualVentureBalanceBefore,
            "Bob should receive venture tokens equal to his virtual UMO balance"
        );
        assertEq(
            usdcBalanceAfter - usdcBalanceBefore,
            virtualMoneyBalanceBefore,
            "Bob should receive USDC equal to his virtual Money balance"
        );

        assertEq(mm.balanceOf(bob, winningProposal.virtualVentureId), 0, "Virtual venture should be burned");
        assertEq(mm.balanceOf(bob, winningProposal.virtualMoneyId), 0, "Virtual Money should be burned");

        vm.stopPrank();
    }

    function test_marketStakeRequiredForCreate() public {
        uint256 initialSupply = 1_000_000e18;

        (uint256 _ventureId, address payable _venture) =
            _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", initialSupply);

        _warmSpotOracle(_venture);

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(_ventureId, MIN_MARKET_STAKE);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] =
            IUmiaMarketCore.CreateProposalParams({title: "yes, cut yearly emissions by 10%", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "should we cut yearly emissions?",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketStake.MarketStakeRequired.selector));
        mm.createMarket(params, alice, nonce, signature);
    }

    function test_revert_startTimeTooFarInFuture() public {
        uint256 initialSupply = 1_000_000e18;

        (uint256 _ventureId, address payable _venture) =
            _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", initialSupply);
        address _ventureToken = Venture(_venture).token();

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(_ventureId, MIN_MARKET_STAKE);

        _mintVenture(hub, _venture, alice, MIN_MARKET_STAKE);

        vm.startPrank(alice);

        IERC20(_ventureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(_ventureId);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] =
            IUmiaMarketCore.CreateProposalParams({title: "yes, cut yearly emissions by 10%", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "should we cut yearly emissions?",
            startTimestamp: block.timestamp + 8 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketCore.StartTimeTooFarInFuture.selector));
        mm.createMarket(params, alice, nonce, signature);

        vm.stopPrank();
    }

    function test_marketStakeWithdrawAfterEnd() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketStake.MarketStakeStillLocked.selector));
        marketStake.withdrawMarketStake(ventureId);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);

        vm.prank(alice);
        marketStake.withdrawMarketStake(ventureId);
    }

    function test_swapExactIn_revertsWhenDeadlineExpired() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketCore.DeadlineExpired.selector));
        mm.swapExactIn(proposal1Id, 100e6, 0, 10000, false, block.timestamp - 1);
    }

    function test_swapExactOut_revertsWhenDeadlineExpired() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUmiaMarketCore.DeadlineExpired.selector));
        mm.swapExactOut(proposal1Id, 50e6, 200e6, 10000, false, block.timestamp - 1);
    }
}
