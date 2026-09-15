// SPDX-License-Identifier: BUSL-1.1
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
import {SimpleLiquidator} from "../../src/liquidation/SimpleLiquidator.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockRebasingERC20} from "../mocks/MockRebasingERC20.sol";
import {MockCallTarget} from "../mocks/MockCallTarget.sol";

contract VentureAllowanceSourcesTest is Test {
    address internal admin = makeAddr("admin");
    address internal marketCore = makeAddr("marketCore");
    address internal team1 = makeAddr("team1");
    address internal team2 = makeAddr("team2");
    address internal ops = makeAddr("ops");
    address internal bob = makeAddr("bob");

    UmiaHub internal hub;
    GovernanceExecutor internal executor;
    Venture internal venture;
    VentureToken internal qToken;

    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockERC20 internal usdt;
    MockRebasingERC20 internal aUsdc;
    MockERC4626 internal vault;

    uint16 internal constant PLAN_VERSION = 1;
    uint16 internal constant ACTION_VERSION = 1;
    uint256 internal constant CAP = 120_000e6;

    function setUp() public {
        UmiaHub hubImpl = new UmiaHub();
        hub = UmiaHub(address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(UmiaHub.initialize, (admin)))));
        vm.prank(admin);
        hub.setUmiaMarketCore(marketCore);

        executor = new GovernanceExecutor(address(hub));
        vm.prank(admin);
        hub.setDefaultGovernanceExecutor(address(executor));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        usdt = new MockERC20("Tether", "USDT", 6);
        aUsdc = new MockRebasingERC20("Aave USDC", "aUSDC", 6);
        vault = new MockERC4626(IERC20(address(usdc)), 12);

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
                moneyToken: address(usdc),
                lbp: address(0xBEEF),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: CAP
            })
        );

        usdc.mint(address(venture), 1_000_000e6);
        aUsdc.mint(address(venture), 2_000_000e6);
        dai.mint(address(venture), 500_000e18);

        usdc.mint(address(this), 1_500_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_500_000e6, address(venture));
    }

    // ─────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────

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

    function _single(GovernanceTypes.ActionType actionType, bytes memory data) internal pure returns (bytes memory) {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(actionType, data);
        return _plan(actions);
    }

    function _execute(bytes memory payload) internal {
        vm.prank(marketCore);
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    function _executeExpectRevert(bytes memory payload, bytes4 selector) internal {
        vm.prank(marketCore);
        vm.expectRevert(selector);
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    function _sourcePayload(address source, address underlying, IVenture.AllowanceSourceKind kind)
        internal
        pure
        returns (bytes memory)
    {
        return _single(
            GovernanceTypes.ActionType.SET_ALLOWANCE_SOURCE,
            abi.encode(
                GovernanceTypes.SetAllowanceSource({source: source, underlying: underlying, sourceKind: uint8(kind)})
            )
        );
    }

    function _register(address source, address underlying, IVenture.AllowanceSourceKind kind) internal {
        _execute(_sourcePayload(source, underlying, kind));
    }

    function _setCap(address token, uint256 amount) internal {
        _execute(
            _single(
                GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE,
                abi.encode(GovernanceTypes.UpdateMonthlyAllowance({token: token, amount: amount}))
            )
        );
    }

    function _spend(address source, uint256 assets) internal {
        vm.prank(team1);
        venture.withdrawMonthlyAllowanceFrom(source, ops, assets);
    }

    function _spendLiquid(uint256 amount) internal {
        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(usdc), ops, amount);
    }

    function _spent(address underlying) internal view returns (uint256 spent) {
        (, spent,) = venture.monthlyAllowance(underlying);
    }

    function _registerAll() internal {
        _register(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
        _register(address(dai), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
        _register(address(vault), address(usdc), IVenture.AllowanceSourceKind.ERC4626);
    }

    // ─────────────────────────────────────────────────────────
    // Registration
    // ─────────────────────────────────────────────────────────

    function test_setAllowanceSource_pegged_storesDecimals() public {
        vm.expectEmit(true, true, false, true);
        emit IVenture.AllowanceSourceSet(address(usdc), address(aUsdc), 1);
        _register(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED);

        (address underlying, IVenture.AllowanceSourceKind kind, uint8 sourceDecimals, uint8 underlyingDecimals) =
            venture.allowanceSources(address(aUsdc));
        assertEq(underlying, address(usdc));
        assertEq(uint8(kind), uint8(IVenture.AllowanceSourceKind.PEGGED));
        assertEq(sourceDecimals, 6);
        assertEq(underlyingDecimals, 6);
    }

    function test_setAllowanceSource_pegged_storesMismatchedDecimals() public {
        _register(address(dai), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
        (,, uint8 sourceDecimals, uint8 underlyingDecimals) = venture.allowanceSources(address(dai));
        assertEq(sourceDecimals, 18);
        assertEq(underlyingDecimals, 6);
    }

    function test_setAllowanceSource_erc4626_requiresAssetMatch() public {
        MockERC4626 daiVault = new MockERC4626(IERC20(address(dai)), 0);
        _executeExpectRevert(
            _sourcePayload(address(daiVault), address(usdc), IVenture.AllowanceSourceKind.ERC4626),
            IVenture.InvalidAllowanceSource.selector
        );
        _register(address(daiVault), address(dai), IVenture.AllowanceSourceKind.ERC4626);
        (address underlying, IVenture.AllowanceSourceKind kind,,) = venture.allowanceSources(address(daiVault));
        assertEq(underlying, address(dai));
        assertEq(uint8(kind), uint8(IVenture.AllowanceSourceKind.ERC4626));
    }

    function test_setAllowanceSource_revertsForZeroSource() public {
        _executeExpectRevert(
            _sourcePayload(address(0), address(usdc), IVenture.AllowanceSourceKind.PEGGED),
            GovernanceActions.InvalidParams.selector
        );
    }

    function test_setAllowanceSource_revertsForNoCode() public {
        _executeExpectRevert(
            _sourcePayload(bob, address(usdc), IVenture.AllowanceSourceKind.PEGGED),
            IVenture.InvalidAllowanceSource.selector
        );
    }

    function test_setAllowanceSource_revertsWhenSourceIsUnderlying() public {
        _executeExpectRevert(
            _sourcePayload(address(usdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED),
            GovernanceActions.InvalidParams.selector
        );
    }

    function test_setAllowanceSource_revertsWhenSourceIsVentureToken() public {
        _executeExpectRevert(
            _sourcePayload(address(qToken), address(usdc), IVenture.AllowanceSourceKind.PEGGED),
            IVenture.InvalidAllowanceSource.selector
        );
    }

    function test_setAllowanceSource_revertsWhenUnderlyingIsASource() public {
        _register(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
        _executeExpectRevert(
            _sourcePayload(address(dai), address(aUsdc), IVenture.AllowanceSourceKind.PEGGED),
            IVenture.InvalidAllowanceSource.selector
        );
    }

    function test_setAllowanceSource_revertsWhenSourceHasOwnCap() public {
        _setCap(address(dai), 1e18);
        _executeExpectRevert(
            _sourcePayload(address(dai), address(usdc), IVenture.AllowanceSourceKind.PEGGED),
            IVenture.InvalidAllowanceSource.selector
        );
        _setCap(address(dai), 0);
        _register(address(dai), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
    }

    function test_setAllowanceSource_revertsWhenDecimalsMissing() public {
        MockCallTarget noDecimals = new MockCallTarget();
        vm.prank(marketCore);
        vm.expectRevert();
        executor.executeProposal(
            address(venture),
            1,
            1,
            _sourcePayload(address(noDecimals), address(usdc), IVenture.AllowanceSourceKind.PEGGED)
        );
    }

    function test_setAllowanceSource_none_removesAndEmitsPreviousUnderlying() public {
        _register(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED);

        vm.expectEmit(true, true, false, true);
        emit IVenture.AllowanceSourceSet(address(usdc), address(aUsdc), 0);
        _register(address(aUsdc), address(0), IVenture.AllowanceSourceKind.NONE);

        (address underlying, IVenture.AllowanceSourceKind kind,,) = venture.allowanceSources(address(aUsdc));
        assertEq(underlying, address(0));
        assertEq(uint8(kind), uint8(IVenture.AllowanceSourceKind.NONE));
    }

    function test_setAllowanceSource_overwrite_changesKind() public {
        _register(address(vault), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
        _register(address(vault), address(usdc), IVenture.AllowanceSourceKind.ERC4626);
        (, IVenture.AllowanceSourceKind kind,,) = venture.allowanceSources(address(vault));
        assertEq(uint8(kind), uint8(IVenture.AllowanceSourceKind.ERC4626));
    }

    function test_setAllowanceSource_revertsForNonExecutor() public {
        vm.prank(bob);
        vm.expectRevert(IVenture.CallerNotAuthorized.selector);
        venture.setAllowanceSource(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
    }

    function test_updateMonthlyAllowance_revertsForRegisteredSource() public {
        _register(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
        _executeExpectRevert(
            _single(
                GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE,
                abi.encode(GovernanceTypes.UpdateMonthlyAllowance({token: address(aUsdc), amount: 1}))
            ),
            IVenture.InvalidAllowanceSource.selector
        );
    }

    function test_setAllowanceSource_revertsWhenSourceIsMoneyToken() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        _executeExpectRevert(
            _sourcePayload(address(usdc), address(other), IVenture.AllowanceSourceKind.PEGGED),
            IVenture.InvalidAllowanceSource.selector
        );
    }

    function test_setAllowanceSource_revertsWhenSourceIsAlreadyAnUnderlying() public {
        _setCap(address(dai), 1_000e18);
        _register(address(usdt), address(dai), IVenture.AllowanceSourceKind.PEGGED);
        assertEq(venture.allowanceSourceCount(address(dai)), 1);

        _setCap(address(dai), 0);
        _executeExpectRevert(
            _sourcePayload(address(dai), address(usdc), IVenture.AllowanceSourceKind.PEGGED),
            IVenture.InvalidAllowanceSource.selector
        );

        _setCap(address(dai), 1_000e18);
        usdt.mint(address(venture), 1_000e6);
        _spend(address(usdt), 100e18);
        assertEq(usdt.balanceOf(ops), 100e6);
    }

    function test_setAllowanceSource_countTracksRegistrationAndRemoval() public {
        assertEq(venture.allowanceSourceCount(address(usdc)), 0);
        _registerAll();
        assertEq(venture.allowanceSourceCount(address(usdc)), 3);

        _register(address(dai), address(0), IVenture.AllowanceSourceKind.NONE);
        assertEq(venture.allowanceSourceCount(address(usdc)), 2);

        _register(address(vault), address(usdc), IVenture.AllowanceSourceKind.PEGGED);
        assertEq(venture.allowanceSourceCount(address(usdc)), 2, "re-registering must not double count");
    }

    function test_setAllowanceSource_removingAnUnregisteredSourceIsANoOp() public {
        _register(address(aUsdc), address(0), IVenture.AllowanceSourceKind.NONE);
        assertEq(venture.allowanceSourceCount(address(usdc)), 0);
        (, IVenture.AllowanceSourceKind kind,,) = venture.allowanceSources(address(aUsdc));
        assertEq(uint8(kind), 0);
    }

    // ─────────────────────────────────────────────────────────
    // Budget group
    // ─────────────────────────────────────────────────────────

    function test_group_sharedCapAcrossFourSources() public {
        _registerAll();

        _spendLiquid(50_000e6);
        _spend(address(aUsdc), 30_000e6);
        _spend(address(dai), 10_000e6);
        _spend(address(vault), 30_000e6);

        assertEq(_spent(address(usdc)), CAP);
        assertEq(venture.allowanceRemaining(address(usdc)), 0);
        assertEq(usdc.balanceOf(ops), 50_000e6 + 30_000e6);
        assertApproxEqAbs(aUsdc.balanceOf(ops), 30_000e6, 1);
        assertEq(dai.balanceOf(ops), 10_000e18);

        vm.prank(team1);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowance(address(usdc), ops, 1);
        vm.prank(team1);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowanceFrom(address(aUsdc), ops, 1);
        vm.prank(team1);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowanceFrom(address(dai), ops, 1);
        vm.prank(team1);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowanceFrom(address(vault), ops, 1);
    }

    function test_group_legacyPathRevertsForRegisteredSource() public {
        _setCap(address(aUsdc), 1_000e6);
        vm.prank(team1);
        venture.withdrawMonthlyAllowance(address(aUsdc), ops, 100e6);

        _setCap(address(aUsdc), 0);
        _register(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED);

        vm.prank(team1);
        vm.expectRevert(IVenture.InvalidAllowanceSource.selector);
        venture.withdrawMonthlyAllowance(address(aUsdc), ops, 100e6);
    }

    function test_group_monthRolloverResetsSourceSpend() public {
        _registerAll();
        _spend(address(vault), CAP);
        assertEq(venture.allowanceRemaining(address(usdc)), 0);

        vm.warp(vm.getBlockTimestamp() + 32 days);
        assertEq(venture.allowanceRemaining(address(usdc)), CAP);

        _spend(address(aUsdc), 1_000e6);
        assertEq(_spent(address(usdc)), 1_000e6);
    }

    function test_group_removedSourceNoLongerSpendable() public {
        _registerAll();
        _register(address(aUsdc), address(0), IVenture.AllowanceSourceKind.NONE);

        vm.prank(team1);
        vm.expectRevert(IVenture.UnknownAllowanceSource.selector);
        venture.withdrawMonthlyAllowanceFrom(address(aUsdc), ops, 1e6);

        vm.prank(team1);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowance(address(aUsdc), ops, 1e6);
    }

    // ─────────────────────────────────────────────────────────
    // Pegged scaling
    // ─────────────────────────────────────────────────────────

    function test_pegged_scaleUp_6to18_exact() public {
        _register(address(dai), address(usdc), IVenture.AllowanceSourceKind.PEGGED);

        vm.expectEmit(true, true, true, true);
        emit IVenture.MonthlyAllowanceWithdrawnFrom(address(usdc), address(dai), ops, 1_234_567, 1_234_567e12);
        _spend(address(dai), 1_234_567);

        assertEq(dai.balanceOf(ops), 1_234_567e12);
        assertEq(_spent(address(usdc)), 1_234_567);
    }

    function test_pegged_scaleDown_18to6_floorsAndDebitsFloored() public {
        _setCap(address(dai), 1_000_000e18);
        usdt.mint(address(venture), 1_000_000e6);
        _register(address(usdt), address(dai), IVenture.AllowanceSourceKind.PEGGED);

        _spend(address(usdt), 1e12 + 5);

        assertEq(usdt.balanceOf(ops), 1);
        assertEq(_spent(address(dai)), 1e12);
    }

    function test_pegged_scaleDown_subUnitReverts() public {
        _setCap(address(dai), 1_000_000e18);
        usdt.mint(address(venture), 1_000_000e6);
        _register(address(usdt), address(dai), IVenture.AllowanceSourceKind.PEGGED);

        vm.prank(team1);
        vm.expectRevert(IVenture.InvalidParams.selector);
        venture.withdrawMonthlyAllowanceFrom(address(usdt), ops, 5);
    }

    function test_pegged_rebasingShortfallStillDebitsRequested() public {
        aUsdc.setIndex(1_000000001e18);
        _register(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED);

        _spend(address(aUsdc), 30_000e6);

        uint256 delivered = aUsdc.balanceOf(ops);
        assertLe(delivered, 30_000e6);
        assertGe(delivered, 30_000e6 - 1);
        assertEq(_spent(address(usdc)), 30_000e6);
    }

    // ─────────────────────────────────────────────────────────
    // ERC-4626 sources
    // ─────────────────────────────────────────────────────────

    function test_erc4626_withdrawBurnsSharesAndDeliversAssets() public {
        _register(address(vault), address(usdc), IVenture.AllowanceSourceKind.ERC4626);
        uint256 sharesBefore = vault.balanceOf(address(venture));
        uint256 expectedShares = vault.previewWithdraw(40_000e6);

        _spend(address(vault), 40_000e6);

        assertEq(sharesBefore - vault.balanceOf(address(venture)), expectedShares);
        assertEq(usdc.balanceOf(ops), 40_000e6);
        assertEq(_spent(address(usdc)), 40_000e6);
    }

    function test_erc4626_illiquidVaultRevertsWithoutDebit() public {
        _register(address(vault), address(usdc), IVenture.AllowanceSourceKind.ERC4626);
        vault.setLiquid(false);

        vm.prank(team1);
        vm.expectRevert(MockERC4626.VaultIlliquid.selector);
        venture.withdrawMonthlyAllowanceFrom(address(vault), ops, 1_000e6);

        assertEq(_spent(address(usdc)), 0);
    }

    function test_erc4626_sharePriceGrowthDoesNotChangeDebit() public {
        _register(address(vault), address(usdc), IVenture.AllowanceSourceKind.ERC4626);
        uint256 sharesAtPar = vault.previewWithdraw(1_000e6);

        usdc.mint(address(this), 150_000e6);
        vault.donate(150_000e6);

        uint256 sharesBefore = vault.balanceOf(address(venture));
        _spend(address(vault), 1_000e6);

        uint256 burned = sharesBefore - vault.balanceOf(address(venture));
        assertLt(burned, sharesAtPar);
        assertEq(_spent(address(usdc)), 1_000e6);
        assertEq(usdc.balanceOf(ops), 1_000e6);
    }

    // ─────────────────────────────────────────────────────────
    // Access and lifecycle
    // ─────────────────────────────────────────────────────────

    function test_withdrawFrom_revertsForNonTeamMember() public {
        _registerAll();
        vm.prank(bob);
        vm.expectRevert(IVenture.NotTeamMember.selector);
        venture.withdrawMonthlyAllowanceFrom(address(aUsdc), ops, 1e6);
    }

    function test_withdrawFrom_revertsForZeroRecipient() public {
        _registerAll();
        vm.prank(team1);
        vm.expectRevert(IVenture.InvalidParams.selector);
        venture.withdrawMonthlyAllowanceFrom(address(aUsdc), address(0), 1e6);
    }

    function test_withdrawFrom_revertsForZeroAssets() public {
        _registerAll();
        vm.prank(team1);
        vm.expectRevert(IVenture.InvalidParams.selector);
        venture.withdrawMonthlyAllowanceFrom(address(aUsdc), ops, 0);
    }

    function test_withdrawFrom_revertsForUnknownSource() public {
        vm.prank(team1);
        vm.expectRevert(IVenture.UnknownAllowanceSource.selector);
        venture.withdrawMonthlyAllowanceFrom(address(aUsdc), ops, 1e6);
    }

    function test_withdrawFrom_revertsWhenLiquidating() public {
        _registerAll();

        vm.prank(address(executor));
        venture.mint(team1, 1e18);

        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(usdc), tokenId: 0
        });
        _execute(
            _single(
                GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
                abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
            )
        );

        vm.prank(team1);
        vm.expectRevert(IVenture.LiquidationActive.selector);
        venture.withdrawMonthlyAllowanceFrom(address(aUsdc), ops, 1e6);
    }

    function test_allowanceRemaining_freshAndStaleMonth() public {
        _registerAll();
        _spend(address(aUsdc), 20_000e6);
        assertEq(venture.allowanceRemaining(address(usdc)), CAP - 20_000e6);

        vm.warp(vm.getBlockTimestamp() + 32 days);
        assertEq(venture.allowanceRemaining(address(usdc)), CAP);

        assertEq(venture.allowanceRemaining(address(dai)), 0);
    }

    // ─────────────────────────────────────────────────────────
    // Payload validation and end to end
    // ─────────────────────────────────────────────────────────

    function test_validatePayload_setAllowanceSource_acceptsAndRejects() public view {
        for (uint8 kind = 0; kind <= 2; kind++) {
            executor.validatePayload(_sourcePayload(address(aUsdc), address(usdc), IVenture.AllowanceSourceKind(kind)));
        }
        executor.validatePayload(_sourcePayload(address(aUsdc), address(0), IVenture.AllowanceSourceKind.NONE));

        bytes memory badKind = _single(
            GovernanceTypes.ActionType.SET_ALLOWANCE_SOURCE,
            abi.encode(
                GovernanceTypes.SetAllowanceSource({source: address(aUsdc), underlying: address(usdc), sourceKind: 3})
            )
        );
        (bool ok,) = address(executor).staticcall(abi.encodeCall(IGovernanceExecutor.validatePayload, (badKind)));
        assertFalse(ok);

        (ok,) = address(executor)
            .staticcall(
                abi.encodeCall(
                    IGovernanceExecutor.validatePayload,
                    (_sourcePayload(address(0), address(usdc), IVenture.AllowanceSourceKind.PEGGED))
                )
            );
        assertFalse(ok);

        (ok,) = address(executor)
            .staticcall(
                abi.encodeCall(
                    IGovernanceExecutor.validatePayload,
                    (_sourcePayload(address(aUsdc), address(0), IVenture.AllowanceSourceKind.PEGGED))
                )
            );
        assertFalse(ok);

        // A self-referential source is the one execution-time rule a pure validator can enforce,
        // so it must fail at market creation rather than winning and reverting forever.
        (ok,) = address(executor)
            .staticcall(
                abi.encodeCall(
                    IGovernanceExecutor.validatePayload,
                    (_sourcePayload(address(usdc), address(usdc), IVenture.AllowanceSourceKind.PEGGED))
                )
            );
        assertFalse(ok);
    }

    function test_execute_parkingPlanEndToEnd() public {
        MockERC4626 fresh = new MockERC4626(IERC20(address(usdc)), 12);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](4);
        actions[0] = _action(
            GovernanceTypes.ActionType.SET_ALLOWANCE,
            abi.encode(GovernanceTypes.SetAllowance({token: address(usdc), spender: address(fresh), amount: 800_000e6}))
        );
        actions[1] = _action(
            GovernanceTypes.ActionType.CALL,
            abi.encode(
                GovernanceTypes.Call({
                    target: address(fresh),
                    value: 0,
                    data: abi.encodeCall(IERC4626.deposit, (800_000e6, address(venture)))
                })
            )
        );
        actions[2] = _action(
            GovernanceTypes.ActionType.SET_ALLOWANCE,
            abi.encode(GovernanceTypes.SetAllowance({token: address(usdc), spender: address(fresh), amount: 0}))
        );
        actions[3] = _action(
            GovernanceTypes.ActionType.SET_ALLOWANCE_SOURCE,
            abi.encode(
                GovernanceTypes.SetAllowanceSource({
                    source: address(fresh),
                    underlying: address(usdc),
                    sourceKind: uint8(IVenture.AllowanceSourceKind.ERC4626)
                })
            )
        );
        _execute(_plan(actions));

        assertEq(usdc.balanceOf(address(venture)), 200_000e6);
        assertEq(usdc.allowance(address(venture), address(fresh)), 0);
        assertEq(fresh.convertToAssets(fresh.balanceOf(address(venture))), 800_000e6);

        _spend(address(fresh), 25_000e6);
        assertEq(usdc.balanceOf(ops), 25_000e6);
        assertEq(venture.allowanceRemaining(address(usdc)), CAP - 25_000e6);
    }
}
