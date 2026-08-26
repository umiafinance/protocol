// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {Venture} from "../../src/core/Venture.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {IGovernanceExecutor} from "../../src/interfaces/IGovernanceExecutor.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {GovernanceActions} from "../../src/libraries/GovernanceActions.sol";
import {GovernancePayloadValidator} from "../../src/libraries/GovernancePayloadValidator.sol";
import {SimpleLiquidator} from "../../src/liquidation/SimpleLiquidator.sol";
import {ILiquidator} from "../../src/interfaces/ILiquidator.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockCallTarget} from "../mocks/MockCallTarget.sol";

contract GovernanceActionsHarness {
    function executeAction(IVenture venture, GovernanceTypes.ActionV1 memory action) external {
        GovernanceActions.executeActionV1(venture, action);
    }
}

contract GovernanceExecutorTest is Test {
    address internal admin = makeAddr("admin");
    address internal marketCore = makeAddr("marketCore");
    address internal team1 = makeAddr("team1");
    address internal team2 = makeAddr("team2");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    UmiaHub internal hub;
    GovernanceExecutor internal executor;
    Venture internal venture;
    VentureToken internal qToken;

    MockERC20 internal moneyToken;
    MockERC20 internal otherToken;
    MockERC721 internal nft;
    MockERC1155 internal erc1155;
    MockCallTarget internal callTarget;
    GovernanceActionsHarness internal actionsHarness;

    uint16 internal constant PLAN_VERSION = 1;
    uint16 internal constant ACTION_VERSION = 1;

    function setUp() public {
        UmiaHub hubImpl = new UmiaHub();
        hub = UmiaHub(address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(UmiaHub.initialize, (admin)))));
        vm.prank(admin);
        hub.setUmiaMarketCore(marketCore);

        executor = new GovernanceExecutor(address(hub));
        vm.prank(admin);
        hub.setDefaultGovernanceExecutor(address(executor));

        moneyToken = new MockERC20("USD Coin", "USDC", 6);
        otherToken = new MockERC20("Other", "OT", 18);
        nft = new MockERC721("Mock NFT", "MNFT");
        erc1155 = new MockERC1155();
        callTarget = new MockCallTarget();
        actionsHarness = new GovernanceActionsHarness();

        Venture ventureImpl = new Venture();
        venture = Venture(
            payable(address(
                    new ERC1967Proxy(address(ventureImpl), abi.encodeCall(Venture.initializeProxy, (address(hub))))
                ))
        );
        qToken = new VentureToken("qToken", "QTK", address(venture));

        address[] memory teamMembers = new address[](2);
        teamMembers[0] = team1;
        teamMembers[1] = team2;

        vm.prank(address(hub));
        venture.initialize(
            IVenture.InitializeVentureParams({
                token: address(qToken),
                moneyToken: address(moneyToken),
                lbp: address(0xBEEF),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function _action(GovernanceTypes.ActionType actionType, bytes memory data)
        internal
        pure
        returns (GovernanceTypes.ActionV1 memory)
    {
        return GovernanceTypes.ActionV1({actionType: actionType, actionVersion: ACTION_VERSION, data: data});
    }

    function _plan(GovernanceTypes.ActionV1[] memory actions) internal pure returns (bytes memory) {
        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: PLAN_VERSION, actions: actions}));
    }

    function _execute(bytes memory payload) internal {
        vm.prank(marketCore);
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    function test_validatePayload_acceptsValidPlan() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.MINT_TOKENS, abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 5e18}))
        );

        (bool ok,) = address(executor).call(abi.encodeWithSignature("validatePayload(bytes)", _plan(actions)));

        assertTrue(ok, "valid governance payload should validate");
    }

    function test_validatePayload_acceptsAllAssetTypes() public {
        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC721, token: address(nft), tokenId: 1
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        // Validation accepts ERC721, SimpleLiquidator rejects during execution
        executor.validatePayload(_plan(actions));
    }

    function test_validatePayload_revertsWhenLiquidationNotFinal() public {
        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](2);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );
        actions[1] = _action(
            GovernanceTypes.ActionType.MINT_TOKENS, abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        );

        vm.expectRevert(IGovernanceExecutor.LiquidationMustBeFinal.selector);
        executor.validatePayload(_plan(actions));
    }

    function test_execute_revertsWhenNotMarketCore() public {
        vm.expectRevert(IGovernanceExecutor.OnlyMarketCore.selector);
        executor.executeProposal(address(venture), 1, 1, "");
    }

    function test_execute_revertsWhenExecutorMismatch() public {
        vm.prank(admin);
        hub.setDefaultGovernanceExecutor(address(0xDEAD));

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](0);
        bytes memory payload = _plan(actions);

        vm.prank(marketCore);
        vm.expectRevert(IGovernanceExecutor.InvalidExecutor.selector);
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    function test_execute_revertsOnEmptyPayload() public {
        vm.prank(marketCore);
        vm.expectRevert(IGovernanceExecutor.InvalidPayload.selector);
        executor.executeProposal(address(venture), 1, 1, "");
    }

    function test_truncatedPayload_revertsForValidateAndExecute() public {
        bytes memory payload = hex"00010203";

        vm.expectRevert(GovernancePayloadValidator.InvalidPayloadEncoding.selector);
        executor.validatePayload(payload);

        vm.prank(marketCore);
        vm.expectRevert(GovernancePayloadValidator.InvalidPayloadEncoding.selector);
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    function test_execute_revertsOnInvalidPlanVersion() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](0);
        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 2, actions: actions}));

        vm.prank(marketCore);
        vm.expectRevert(GovernancePayloadValidator.InvalidVersion.selector);
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    function test_execute_revertsOnInvalidActionVersion() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 2,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        });

        bytes memory payload = _plan(actions);

        vm.prank(marketCore);
        vm.expectRevert(GovernanceActions.InvalidActionVersion.selector);
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    function test_execute_revertsWhenLiquidationNotFinal() public {
        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](2);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );
        actions[1] = _action(
            GovernanceTypes.ActionType.MINT_TOKENS, abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        );

        bytes memory payload = _plan(actions);

        vm.prank(marketCore);
        vm.expectRevert(IGovernanceExecutor.LiquidationMustBeFinal.selector);
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    function test_execute_revertsWhenLiquidationActive() public {
        vm.prank(address(executor));
        Venture(payable(venture)).mint(team1, 1e18);
        vm.deal(address(venture), 1 ether);

        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        // Execute liquidation via governance to properly set the liquidator
        GovernanceTypes.ActionV1[] memory liqActions = new GovernanceTypes.ActionV1[](1);
        liqActions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        vm.prank(marketCore);
        executor.executeProposal(address(venture), 1, 1, _plan(liqActions));

        // Now try to execute another governance action while liquidation is active
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        vm.prank(marketCore);
        vm.expectRevert(IGovernanceExecutor.LiquidationActive.selector);
        executor.executeProposal(address(venture), 2, 2, _plan(actions));
    }

    function test_burnFrom_revertsWhenNotLiquidating() public {
        vm.prank(bob);
        vm.expectRevert(IVenture.NotLiquidating.selector);
        venture.burnFrom(bob, 1e18);
    }

    function test_initialize_revertsOnEmptyTeamMembers() public {
        Venture newVentureImpl = new Venture();
        Venture newVenture = Venture(
            payable(address(
                    new ERC1967Proxy(address(newVentureImpl), abi.encodeCall(Venture.initializeProxy, (address(hub))))
                ))
        );
        VentureToken newToken = new VentureToken("Empty", "EMP", address(newVenture));

        address[] memory emptyTeam = new address[](0);

        vm.prank(address(hub));
        vm.expectRevert(IVenture.InvalidParams.selector);
        newVenture.initialize(
            IVenture.InitializeVentureParams({
                token: address(newToken),
                moneyToken: address(moneyToken),
                lbp: address(0xBEEF),
                teamMembers: emptyTeam,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_action_mintTokens() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.MINT_TOKENS, abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 5e18}))
        );

        _execute(_plan(actions));

        assertEq(qToken.balanceOf(bob), 5e18);
    }

    function test_action_mintTokens_invalidParams() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.MINT_TOKENS,
            abi.encode(GovernanceTypes.MintTokens({to: address(0), amount: 1e18}))
        );

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_burnTokens() public {
        vm.prank(address(executor));
        venture.mint(address(venture), 10e18);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] =
            _action(GovernanceTypes.ActionType.BURN_TOKENS, abi.encode(GovernanceTypes.BurnTokens({amount: 4e18})));

        _execute(_plan(actions));

        assertEq(qToken.balanceOf(address(venture)), 6e18);
    }

    function test_action_burnTokens_invalidParams() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] =
            _action(GovernanceTypes.ActionType.BURN_TOKENS, abi.encode(GovernanceTypes.BurnTokens({amount: 0})));

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_transferTreasuryAssets_erc20() public {
        otherToken.mint(address(venture), 1_000e18);

        GovernanceTypes.TransferTreasuryAssets memory params = GovernanceTypes.TransferTreasuryAssets({
            assetType: GovernanceTypes.AssetType.ERC20,
            token: address(otherToken),
            to: bob,
            amount: 250e18,
            tokenId: 0,
            data: ""
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS, abi.encode(params));

        _execute(_plan(actions));

        assertEq(otherToken.balanceOf(bob), 250e18);
    }

    function test_action_transferTreasuryAssets_native() public {
        vm.deal(address(venture), 5 ether);

        GovernanceTypes.TransferTreasuryAssets memory params = GovernanceTypes.TransferTreasuryAssets({
            assetType: GovernanceTypes.AssetType.NATIVE,
            token: address(0),
            to: bob,
            amount: 1 ether,
            tokenId: 0,
            data: ""
        });

        uint256 bobBalanceBefore = bob.balance;

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS, abi.encode(params));

        _execute(_plan(actions));

        assertEq(bob.balance - bobBalanceBefore, 1 ether);
    }

    function test_action_transferTreasuryAssets_erc721() public {
        uint256 tokenId = nft.mint(address(venture));

        GovernanceTypes.TransferTreasuryAssets memory params = GovernanceTypes.TransferTreasuryAssets({
            assetType: GovernanceTypes.AssetType.ERC721,
            token: address(nft),
            to: bob,
            amount: 0,
            tokenId: tokenId,
            data: ""
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS, abi.encode(params));

        _execute(_plan(actions));

        assertEq(nft.ownerOf(tokenId), bob);
    }

    function test_action_transferTreasuryAssets_erc1155() public {
        erc1155.mint(address(venture), 7, 100);

        GovernanceTypes.TransferTreasuryAssets memory params = GovernanceTypes.TransferTreasuryAssets({
            assetType: GovernanceTypes.AssetType.ERC1155,
            token: address(erc1155),
            to: bob,
            amount: 40,
            tokenId: 7,
            data: ""
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS, abi.encode(params));

        _execute(_plan(actions));

        assertEq(erc1155.balanceOf(bob, 7), 40);
    }

    function test_action_transferTreasuryAssets_invalidParams() public {
        GovernanceTypes.TransferTreasuryAssets memory params = GovernanceTypes.TransferTreasuryAssets({
            assetType: GovernanceTypes.AssetType.NATIVE,
            token: address(0xBEEF),
            to: bob,
            amount: 1,
            tokenId: 0,
            data: ""
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS, abi.encode(params));

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_transferTreasuryAssets_erc20TokenZeroReverts() public {
        GovernanceTypes.TransferTreasuryAssets memory params = GovernanceTypes.TransferTreasuryAssets({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(0), to: bob, amount: 1e18, tokenId: 0, data: ""
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS, abi.encode(params));

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_transferTreasuryAssets_amountZeroReverts() public {
        GovernanceTypes.TransferTreasuryAssets memory params = GovernanceTypes.TransferTreasuryAssets({
            assetType: GovernanceTypes.AssetType.ERC20,
            token: address(otherToken),
            to: bob,
            amount: 0,
            tokenId: 0,
            data: ""
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS, abi.encode(params));

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_transferTreasuryAssets_toZeroReverts() public {
        GovernanceTypes.TransferTreasuryAssets memory params = GovernanceTypes.TransferTreasuryAssets({
            assetType: GovernanceTypes.AssetType.ERC20,
            token: address(otherToken),
            to: address(0),
            amount: 1e18,
            tokenId: 0,
            data: ""
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS, abi.encode(params));

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_updateMonthlyAllowance_andWithdraw() public {
        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 1_000e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));

        _execute(_plan(actions));

        (uint256 amount,,) = venture.monthlyAllowance(address(otherToken));
        assertEq(amount, 1_000e18);

        otherToken.mint(address(venture), 1_000e18);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 250e18);

        assertEq(otherToken.balanceOf(team1), 250e18);
    }

    function test_updateMonthlyAllowance_revertsForNonExecutor() public {
        vm.prank(bob);
        vm.expectRevert(IVenture.CallerNotAuthorized.selector);
        venture.updateMonthlyAllowance(address(otherToken), 1e18);
    }

    function test_withdrawMonthlyAllowance_revertsForNonTeamMember() public {
        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 1_000e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        vm.prank(bob);
        vm.expectRevert(IVenture.NotTeamMember.selector);
        venture.withdrawMonthlyAllowance(address(otherToken), bob, 1e18);
    }

    function test_withdrawMonthlyAllowance_invalidParams() public {
        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 1_000e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        vm.prank(team1);
        vm.expectRevert(IVenture.InvalidParams.selector);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 0);
    }

    function test_withdrawMonthlyAllowance_revertsForZeroRecipient() public {
        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 1_000e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        vm.prank(team1);
        vm.expectRevert(IVenture.InvalidParams.selector);
        venture.withdrawMonthlyAllowance(address(otherToken), address(0), 1e18);
    }

    function test_withdrawMonthlyAllowance_revertsWhenExceeded() public {
        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 1_000e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        vm.prank(team1);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 2_000e18);
    }

    function test_withdrawMonthlyAllowance_resetsAtCalendarMonth() public {
        // Warp to Feb 15, 2026 00:00 UTC
        vm.warp(1771113600);

        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 100e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        otherToken.mint(address(venture), 300e18);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 40e18);

        (,, uint256 currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202602);

        // Mar 1, 2026 00:00 UTC — new calendar month resets allowance
        vm.warp(1772323200);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 100e18);

        assertEq(otherToken.balanceOf(team1), 140e18);

        (,, currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202603);
    }

    function test_withdrawMonthlyAllowance_noResetWithinSameMonth() public {
        // Warp to Feb 1, 2026 00:00 UTC
        vm.warp(1769904000);

        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 100e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        otherToken.mint(address(venture), 200e18);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 60e18);

        // Warp to Feb 28, 2026 23:59:59 UTC — still same month
        vm.warp(1772323199);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 40e18);

        assertEq(otherToken.balanceOf(team1), 100e18);

        // Exceeds the 100e18 limit within same month
        vm.prank(team1);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 1);
    }

    function test_withdrawMonthlyAllowance_resetsAtYearBoundary() public {
        // Dec 15, 2027 00:00 UTC
        vm.warp(1828828800);

        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 50e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        otherToken.mint(address(venture), 100e18);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 50e18);

        (,, uint256 currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202712);

        // Jan 1, 2028 00:00 UTC
        vm.warp(1830297600);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 50e18);

        assertEq(otherToken.balanceOf(team1), 100e18);

        (,, currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202801);
    }

    function test_withdrawMonthlyAllowance_leapYearFeb29() public {
        // Feb 28, 2028 12:00 UTC (2028 is a leap year)
        vm.warp(1835352000);

        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 100e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        otherToken.mint(address(venture), 200e18);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 80e18);

        (,, uint256 currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202802);

        // Feb 29, 2028 23:59:59 UTC — still February
        vm.warp(1835481599);

        vm.prank(team1);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 21e18);

        // Mar 1, 2028 00:00 UTC — new month
        vm.warp(1835481600);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 100e18);

        assertEq(otherToken.balanceOf(team1), 180e18);

        (,, currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202803);
    }

    function test_withdrawMonthlyAllowance_resetsAtExactMidnightUTC() public {
        // Feb 28, 2026 23:59:59 UTC
        vm.warp(1772323199);

        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 100e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        otherToken.mint(address(venture), 200e18);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 100e18);

        (,, uint256 currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202602);

        // Exactly Mar 1, 2026 00:00:00 UTC — first second of new month
        vm.warp(1772323200);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 100e18);

        assertEq(otherToken.balanceOf(team1), 200e18);

        (,, currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202603);
    }

    function test_withdrawMonthlyAllowance_multipleMonthsSkipped() public {
        // Jan 15, 2026 00:00 UTC
        vm.warp(1768435200);

        GovernanceTypes.UpdateMonthlyAllowance memory params =
            GovernanceTypes.UpdateMonthlyAllowance({token: address(otherToken), amount: 100e18});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE, abi.encode(params));
        _execute(_plan(actions));

        otherToken.mint(address(venture), 200e18);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 50e18);

        // Skip to Jun 1, 2026 — no rollover of unused allowance
        vm.warp(1780272000);

        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(otherToken), team1, 100e18);

        assertEq(otherToken.balanceOf(team1), 150e18);

        (,, uint256 currentMonth) = venture.monthlyAllowance(address(otherToken));
        assertEq(currentMonth, 202606);
    }

    function test_action_updateTeamMember() public {
        GovernanceTypes.UpdateTeamMember memory params = GovernanceTypes.UpdateTeamMember({member: bob, approved: true});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER, abi.encode(params));

        _execute(_plan(actions));
        assertTrue(venture.isTeamMember(bob));

        GovernanceTypes.UpdateTeamMember memory removeParams =
            GovernanceTypes.UpdateTeamMember({member: bob, approved: false});
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER, abi.encode(removeParams));

        _execute(_plan(actions));
        assertFalse(venture.isTeamMember(bob));
    }

    function test_updateTeamMember_revertsForNonExecutor() public {
        vm.prank(bob);
        vm.expectRevert(IVenture.CallerNotAuthorized.selector);
        venture.updateTeamMember(bob, true);
    }

    function test_action_updateTeamMember_invalidParams() public {
        GovernanceTypes.UpdateTeamMember memory params =
            GovernanceTypes.UpdateTeamMember({member: address(0), approved: true});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER, abi.encode(params));

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_uploadDocument() public {
        GovernanceTypes.UploadDocument memory params = GovernanceTypes.UploadDocument({name: "Doc", uri: "ipfs://doc"});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPLOAD_DOCUMENT, abi.encode(params));

        _execute(_plan(actions));

        assertEq(venture.documentCount(), 1);
        (string memory name, string memory uri,) = venture.documents(1);
        assertEq(name, "Doc");
        assertEq(uri, "ipfs://doc");
    }

    function test_action_uploadDocument_invalidParams() public {
        GovernanceTypes.UploadDocument memory params = GovernanceTypes.UploadDocument({name: "", uri: ""});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPLOAD_DOCUMENT, abi.encode(params));

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_updateParams_reverts() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.UPDATE_PARAMS, abi.encode(uint256(1)));

        vm.expectRevert(GovernanceActions.UnsupportedAction.selector);
        _execute(_plan(actions));
    }

    function test_governanceActions_executeAction_revertsOnInvalidActionVersion() public {
        GovernanceTypes.ActionV1 memory action = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 2,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        });

        vm.expectRevert(GovernanceActions.InvalidActionVersion.selector);
        actionsHarness.executeAction(venture, action);
    }

    function test_governanceActions_executeAction_revertsOnUpdateParams() public {
        GovernanceTypes.ActionV1 memory action =
            _action(GovernanceTypes.ActionType.UPDATE_PARAMS, abi.encode(uint256(1)));

        vm.expectRevert(GovernanceActions.UnsupportedAction.selector);
        actionsHarness.executeAction(venture, action);
    }

    function test_governanceActions_executeTransfer_matchesExecutorParity() public {
        otherToken.mint(address(venture), 10e18);

        vm.prank(admin);
        hub.setDefaultGovernanceExecutor(address(actionsHarness));

        GovernanceTypes.ActionV1 memory action = _action(
            GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS,
            abi.encode(
                GovernanceTypes.TransferTreasuryAssets({
                    assetType: GovernanceTypes.AssetType.ERC20,
                    token: address(otherToken),
                    to: bob,
                    amount: 1e18,
                    tokenId: 0,
                    data: ""
                })
            )
        );

        actionsHarness.executeAction(venture, action);

        assertEq(otherToken.balanceOf(bob), 1e18);
    }

    function test_action_liquidateTreasury_andClaimProRata() public {
        vm.prank(address(executor));
        venture.mint(team1, 100e18);
        vm.prank(address(executor));
        venture.mint(bob, 100e18);

        otherToken.mint(address(venture), 1_000e18);
        vm.deal(address(venture), 10 ether);

        // Deploy the liquidator
        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](2);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });
        assets[1] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(otherToken), tokenId: 0
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        _execute(_plan(actions));
        assertTrue(venture.liquidationActive());
        assertEq(venture.authorizedLiquidator(), address(liquidator));

        // Bob claims through the liquidator
        uint256 bobEthBefore = bob.balance;

        // Bob claims through liquidator
        vm.prank(bob);
        liquidator.claim();

        // Bob had 100e18 of 200e18 total supply (50%)
        // Should get 50% of assets: 500e18 otherToken and 5 ether
        assertEq(otherToken.balanceOf(bob), 500e18);
        assertEq(bob.balance - bobEthBefore, 5 ether);

        // Bob's venture tokens should be burned (balance = 0)
        assertEq(qToken.balanceOf(bob), 0);
    }

    function test_action_liquidateTreasury_revertsForERC721() public {
        vm.prank(address(executor));
        venture.mint(team1, 1e18);

        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC721, token: address(nft), tokenId: 1
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        vm.expectRevert(ILiquidator.InvalidAssetType.selector);
        _execute(_plan(actions));
    }

    function test_action_liquidateTreasury_revertsForERC1155() public {
        vm.prank(address(executor));
        venture.mint(team1, 1e18);

        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC1155, token: address(erc1155), tokenId: 9
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        vm.expectRevert(ILiquidator.InvalidAssetType.selector);
        _execute(_plan(actions));
    }

    function test_action_liquidateTreasury_invalidParams() public {
        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](0);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_liquidation_revertsOnZeroSupply() public {
        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_call_executes() public {
        vm.deal(address(venture), 1 ether);

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        GovernanceTypes.Call memory params =
            GovernanceTypes.Call({target: address(callTarget), value: 0.25 ether, data: data});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.CALL, abi.encode(params));

        _execute(_plan(actions));

        assertEq(callTarget.value(), 42);
        assertEq(callTarget.lastValue(), 0.25 ether);
    }

    function test_action_call_invalidTarget() public {
        GovernanceTypes.Call memory params = GovernanceTypes.Call({target: address(0), value: 0, data: ""});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.CALL, abi.encode(params));

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_action_call_revertsOnFailure() public {
        bytes memory data = abi.encodeWithSignature("alwaysRevert()");
        GovernanceTypes.Call memory params = GovernanceTypes.Call({target: address(callTarget), value: 0, data: data});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.CALL, abi.encode(params));

        vm.expectRevert(IVenture.TransferFailed.selector);
        _execute(_plan(actions));
    }

    function test_atomicity_revertsAllActions() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](2);
        actions[0] = _action(
            GovernanceTypes.ActionType.MINT_TOKENS, abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        );
        actions[1] = _action(
            GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS,
            abi.encode(
                GovernanceTypes.TransferTreasuryAssets({
                    assetType: GovernanceTypes.AssetType.ERC20,
                    token: address(0),
                    to: bob,
                    amount: 1e18,
                    tokenId: 0,
                    data: ""
                })
            )
        );

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));

        assertEq(qToken.balanceOf(bob), 0);
    }

    // ─────────────────────────────────────────────────────────
    // SET_ALLOWANCE action tests
    // ─────────────────────────────────────────────────────────

    function test_action_setAllowance_executes() public {
        // Fund the treasury
        otherToken.mint(address(venture), 10_000e18);

        uint256 allowanceAmount = 2_500e18;
        GovernanceTypes.SetAllowance memory params =
            GovernanceTypes.SetAllowance({token: address(otherToken), spender: bob, amount: allowanceAmount});

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.SET_ALLOWANCE, abi.encode(params));

        _execute(_plan(actions));

        assertEq(otherToken.allowance(address(venture), bob), allowanceAmount);
    }

    function test_action_setAllowance_revoke() public {
        otherToken.mint(address(venture), 1_000e18);

        // First grant
        GovernanceTypes.SetAllowance memory grant =
            GovernanceTypes.SetAllowance({token: address(otherToken), spender: bob, amount: 500e18});
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.SET_ALLOWANCE, abi.encode(grant));
        _execute(_plan(actions));
        assertEq(otherToken.allowance(address(venture), bob), 500e18);

        // Then revoke
        GovernanceTypes.SetAllowance memory revoke =
            GovernanceTypes.SetAllowance({token: address(otherToken), spender: bob, amount: 0});
        actions[0] = _action(GovernanceTypes.ActionType.SET_ALLOWANCE, abi.encode(revoke));
        _execute(_plan(actions));
        assertEq(otherToken.allowance(address(venture), bob), 0);
    }

    function test_action_setAllowance_invalidParams() public {
        // zero token
        GovernanceTypes.SetAllowance memory bad1 =
            GovernanceTypes.SetAllowance({token: address(0), spender: bob, amount: 100});
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(GovernanceTypes.ActionType.SET_ALLOWANCE, abi.encode(bad1));
        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));

        // zero spender
        GovernanceTypes.SetAllowance memory bad2 =
            GovernanceTypes.SetAllowance({token: address(otherToken), spender: address(0), amount: 100});
        actions[0] = _action(GovernanceTypes.ActionType.SET_ALLOWANCE, abi.encode(bad2));
        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _execute(_plan(actions));
    }

    function test_setAllowance_revertsForNonExecutor() public {
        vm.prank(bob);
        vm.expectRevert(IVenture.CallerNotAuthorized.selector);
        venture.setAllowance(address(otherToken), bob, 100e18);
    }

    function test_setAllowance_revertsWhenLiquidating() public {
        vm.prank(address(executor));
        Venture(payable(venture)).mint(team1, 1e18);

        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(otherToken), tokenId: 0
        });

        GovernanceTypes.ActionV1[] memory liqActions = new GovernanceTypes.ActionV1[](1);
        liqActions[0] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );

        vm.prank(marketCore);
        executor.executeProposal(address(venture), 1, 1, _plan(liqActions));

        vm.prank(address(executor));
        vm.expectRevert(IVenture.LiquidationActive.selector);
        venture.setAllowance(address(otherToken), bob, 100e18);
    }

    /// Documents the required mitigation for the standing-allowance drain (#104038): a liquidation plan
    /// revokes every live allowance with SET_ALLOWANCE(...,0) actions ordered BEFORE LIQUIDATE_TREASURY,
    /// so no approval survives into the terminal state. See docs/GOVERNANCE_TREASURY_LAYER.md.
    function test_liquidationPlan_revokesAllowancesInline() public {
        otherToken.mint(address(venture), 1_000e18);

        // A keeper holds a standing treasury allowance.
        GovernanceTypes.ActionV1[] memory grant = new GovernanceTypes.ActionV1[](1);
        grant[0] = _action(
            GovernanceTypes.ActionType.SET_ALLOWANCE,
            abi.encode(GovernanceTypes.SetAllowance({token: address(otherToken), spender: bob, amount: 500e18}))
        );
        _execute(_plan(grant));
        assertEq(otherToken.allowance(address(venture), bob), 500e18);

        vm.prank(address(executor));
        Venture(payable(venture)).mint(team1, 1e18); // non-zero supply for the liquidation snapshot

        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(otherToken), tokenId: 0
        });

        // One plan: revoke the allowance, THEN liquidate. Actions run in order, so the revoke lands
        // while still not liquidating (setAllowance is whenNotLiquidating), before setLiquidator.
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](2);
        actions[0] = _action(
            GovernanceTypes.ActionType.SET_ALLOWANCE,
            abi.encode(GovernanceTypes.SetAllowance({token: address(otherToken), spender: bob, amount: 0}))
        );
        actions[1] = _action(
            GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        );
        _execute(_plan(actions));

        assertEq(otherToken.allowance(address(venture), bob), 0, "allowance revoked in-plan");
        assertTrue(Venture(payable(venture)).liquidationActive(), "liquidation active");

        // The keeper can no longer pull the asset that backs liquidation claims.
        vm.prank(bob);
        vm.expectRevert();
        otherToken.transferFrom(address(venture), bob, 1e18);
    }
}
