// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {VentureVestingAuthority} from "../../src/periphery/VentureVestingAuthority.sol";
import {IVentureVestingAuthority} from "../../src/interfaces/IVentureVestingAuthority.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Minimal MetaVesT controller stand-in that moves real tokens, so the clawback accounting in
///         `terminateAndReissue` is exercised for real rather than mocked away.
contract MockVestingController {
    bytes4 private constant CREATE_METAVEST_SELECTOR = bytes4(
        keccak256(
            "createMetavest(uint8,address,(uint256,uint128,uint128,uint160,uint48,uint160,uint48,address),(uint256,bool,bool,address[])[],uint256,address,uint256,uint256)"
        )
    );
    bytes4 private constant TERMINATE_VESTING_SELECTOR = bytes4(keccak256("terminateMetavestVesting(address)"));

    IERC20 public immutable token;
    uint256 public clawback;
    uint256 public pullAmount;
    address public nextAllocation;
    address public lastTerminated;

    constructor(IERC20 _token) {
        token = _token;
    }

    function setClawback(uint256 amount) external {
        clawback = amount;
    }

    function setReissue(address allocation, uint256 amount) external {
        nextAllocation = allocation;
        pullAmount = amount;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        bytes4 sel = bytes4(data[0:4]);
        if (sel == TERMINATE_VESTING_SELECTOR) {
            lastTerminated = abi.decode(data[4:], (address));
            if (clawback != 0) token.transfer(msg.sender, clawback);
            return "";
        }
        if (sel == CREATE_METAVEST_SELECTOR) {
            if (pullAmount != 0) token.transferFrom(msg.sender, nextAllocation, pullAmount);
            return abi.encode(nextAllocation);
        }
        revert("unexpected selector");
    }
}

/// @notice Grant-administration path: the Hub `vestingAdmin` (default-on, per-venture revocable) and
///         the treasury may terminate, recycle a clawback into a replacement grant, or sweep idle
///         balance back to the treasury.
contract VentureVestingAuthorityGrantAdminTest is Test {
    VentureVestingAuthority adapter;
    MockERC20 token;
    MockVestingController controller;

    address constant HUB = address(0xB0);
    address constant TREASURY = address(0xA1);
    address constant UMIA_ADMIN = address(0xADA1);
    address constant STRANGER = address(0xE1);
    address constant OLD_ALLOCATION = address(0xABCD);
    address constant NEW_ALLOCATION = address(0xDCBA);
    address constant OTHER_TOKEN = address(0x7702);
    address constant GRANTEE = address(0xBEEF);
    uint256 constant VENTURE_ID = 7;

    bytes4 private constant CREATE_METAVEST_SELECTOR = bytes4(
        keccak256(
            "createMetavest(uint8,address,(uint256,uint128,uint128,uint160,uint48,uint160,uint48,address),(uint256,bool,bool,address[])[],uint256,address,uint256,uint256)"
        )
    );

    function setUp() public {
        token = new MockERC20("Venture", "VEN", 18);
        controller = new MockVestingController(IERC20(address(token)));
        adapter = new VentureVestingAuthority(HUB, address(controller));

        IUmiaHub.VentureInfo memory info =
            IUmiaHub.VentureInfo({id: VENTURE_ID, venture: TREASURY, name: "", createdAt: 0});
        vm.mockCall(HUB, abi.encodeWithSelector(IUmiaHub.ventureById.selector, VENTURE_ID), abi.encode(info));
        vm.mockCall(TREASURY, abi.encodeWithSelector(IVenture.token.selector), abi.encode(address(token)));
        _setLiquidating(false);
        _setHubVestingAdmin(UMIA_ADMIN);

        _mockAllocation(OLD_ALLOCATION, address(token));
        _mockAllocation(NEW_ALLOCATION, address(token));

        adapter.bind(VENTURE_ID);
    }

    function _setLiquidating(bool active) internal {
        vm.mockCall(TREASURY, abi.encodeWithSelector(IVenture.liquidationActive.selector), abi.encode(active));
    }

    function _setHubVestingAdmin(address admin) internal {
        vm.mockCall(HUB, abi.encodeWithSelector(IUmiaHub.vestingAdmin.selector), abi.encode(admin));
    }

    function _mockAllocation(address allocation, address tkn) internal {
        vm.mockCall(allocation, abi.encodeWithSignature("getVestingType()"), abi.encode(uint256(1)));
        vm.mockCall(allocation, abi.encodeWithSignature("grantee()"), abi.encode(GRANTEE));
        vm.mockCall(allocation, abi.encodeWithSignature("milestoneAwardTotal()"), abi.encode(uint256(0)));
        vm.mockCall(
            allocation,
            abi.encodeWithSignature("getMetavestDetails()"),
            abi.encode(uint256(100), uint128(0), uint128(0), uint160(0), uint48(0), uint160(0), uint48(0), tkn)
        );
    }

    function _createCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CREATE_METAVEST_SELECTOR);
    }

    function _noProgram() internal pure returns (IVentureVestingAuthority.PriceProgramInput memory) {
        return IVentureVestingAuthority.PriceProgramInput({
            kind: IVentureVestingAuthority.PriceProgramKind.None,
            absoluteThresholds: new uint160[](0),
            multiplesX1e6: new uint256[](0),
            cliffs: new uint48[](0)
        });
    }

    // ── auth ──

    function test_TerminateGrant_ByVestingAdmin() public {
        vm.expectEmit(true, true, false, false);
        emit IVentureVestingAuthority.GrantTerminated(OLD_ALLOCATION, UMIA_ADMIN);

        vm.prank(UMIA_ADMIN);
        adapter.terminateGrant(OLD_ALLOCATION);

        assertEq(controller.lastTerminated(), OLD_ALLOCATION, "controller saw the terminate");
    }

    function test_TerminateGrant_ByTreasury() public {
        vm.prank(TREASURY);
        adapter.terminateGrant(OLD_ALLOCATION);
        assertEq(controller.lastTerminated(), OLD_ALLOCATION);
    }

    function test_Revert_TerminateGrant_Stranger() public {
        vm.prank(STRANGER);
        vm.expectRevert(IVentureVestingAuthority.NotAuthorized.selector);
        adapter.terminateGrant(OLD_ALLOCATION);
    }

    function test_Revert_TerminateGrant_HubAdminUnset() public {
        _setHubVestingAdmin(address(0));
        vm.prank(UMIA_ADMIN);
        vm.expectRevert(IVentureVestingAuthority.NotAuthorized.selector);
        adapter.terminateGrant(OLD_ALLOCATION);
    }

    function test_VentureRevokesAdminPath_TreasuryStillWorks() public {
        vm.prank(TREASURY);
        adapter.setVestingAdminRevoked(true);
        assertEq(adapter.effectiveVestingAdmin(), address(0), "admin path reads as unavailable once revoked");

        vm.prank(UMIA_ADMIN);
        vm.expectRevert(IVentureVestingAuthority.NotAuthorized.selector);
        adapter.terminateGrant(OLD_ALLOCATION);

        vm.prank(TREASURY);
        adapter.terminateGrant(OLD_ALLOCATION);
        assertEq(controller.lastTerminated(), OLD_ALLOCATION);
    }

    /// @dev Liquidation pays out pro-rata against a supply snapshot, so grant mutation must stop
    ///      where governance stops. Neither the admin nor the treasury may move grants after that.
    function test_Revert_TerminateGrant_WhileLiquidating() public {
        _setLiquidating(true);

        vm.prank(UMIA_ADMIN);
        vm.expectRevert(IVentureVestingAuthority.LiquidationActive.selector);
        adapter.terminateGrant(OLD_ALLOCATION);

        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.LiquidationActive.selector);
        adapter.terminateGrant(OLD_ALLOCATION);
    }

    function test_Revert_TerminateAndReissue_WhileLiquidating() public {
        _setLiquidating(true);
        vm.prank(UMIA_ADMIN);
        vm.expectRevert(IVentureVestingAuthority.LiquidationActive.selector);
        adapter.terminateAndReissue(OLD_ALLOCATION, _createCalldata(), _noProgram());
    }

    /// @dev Sweeping only ever pays the treasury, so it stays open during liquidation: it returns
    ///      assets to the estate rather than moving entitlements.
    function test_Sweep_StillWorksWhileLiquidating() public {
        token.mint(address(adapter), 250);
        _setLiquidating(true);

        adapter.sweep(address(token));
        assertEq(token.balanceOf(TREASURY), 250);
    }

    function test_EffectiveVestingAdmin_ZeroWhileLiquidating() public {
        _setLiquidating(true);
        assertEq(adapter.effectiveVestingAdmin(), address(0), "admin cannot act, so it reads as none");
    }

    function test_EffectiveVestingAdmin_ZeroBeforeBind() public {
        VentureVestingAuthority fresh = new VentureVestingAuthority(HUB, address(controller));
        assertEq(fresh.effectiveVestingAdmin(), address(0), "no admin can act on an unbound adapter");
    }

    function test_Revert_TerminateAndReissue_TokenMismatch() public {
        _mockAllocation(NEW_ALLOCATION, OTHER_TOKEN);
        token.mint(address(controller), 100);
        controller.setClawback(100);
        controller.setReissue(NEW_ALLOCATION, 100);

        vm.prank(UMIA_ADMIN);
        vm.expectRevert(IVentureVestingAuthority.ReissueTokenMismatch.selector);
        adapter.terminateAndReissue(OLD_ALLOCATION, _createCalldata(), _noProgram());
    }

    function test_VestingAdminDefaultsOn() public view {
        assertFalse(adapter.vestingAdminRevoked(), "opted in by default");
        assertEq(adapter.effectiveVestingAdmin(), UMIA_ADMIN);
    }

    function test_Revert_SetVestingAdminRevoked_NotTreasury() public {
        vm.prank(UMIA_ADMIN);
        vm.expectRevert(IVentureVestingAuthority.NotTreasury.selector);
        adapter.setVestingAdminRevoked(true);
    }

    function test_Revert_TerminateGrant_NotBound() public {
        VentureVestingAuthority fresh = new VentureVestingAuthority(HUB, address(controller));
        vm.prank(UMIA_ADMIN);
        vm.expectRevert(IVentureVestingAuthority.NotBound.selector);
        fresh.terminateGrant(OLD_ALLOCATION);
    }

    // ── terminate + reissue ──

    function test_TerminateAndReissue_RecyclesClawback() public {
        token.mint(address(controller), 100);
        controller.setClawback(100);
        controller.setReissue(NEW_ALLOCATION, 100);

        vm.prank(UMIA_ADMIN);
        address created = adapter.terminateAndReissue(OLD_ALLOCATION, _createCalldata(), _noProgram());

        assertEq(created, NEW_ALLOCATION);
        assertEq(controller.lastTerminated(), OLD_ALLOCATION);
        assertEq(token.balanceOf(NEW_ALLOCATION), 100, "clawback funded the replacement");
        assertEq(token.balanceOf(address(adapter)), 0, "nothing left idle");
    }

    function test_TerminateAndReissue_PartialReturnsRemainderToTreasury() public {
        token.mint(address(controller), 100);
        controller.setClawback(100);
        controller.setReissue(NEW_ALLOCATION, 40);

        vm.prank(UMIA_ADMIN);
        adapter.terminateAndReissue(OLD_ALLOCATION, _createCalldata(), _noProgram());

        assertEq(token.balanceOf(NEW_ALLOCATION), 40);
        assertEq(token.balanceOf(TREASURY), 60, "unspent clawback goes home, not parked here");
        assertEq(token.balanceOf(address(adapter)), 0, "adapter never retains a clawback");
    }

    /// @dev The property that keeps this from being a drain: idle adapter balance (an earlier
    ///      clawback, a stray transfer) must not be reachable by a reissue. It is flushed to the
    ///      treasury before the terminate, so a replacement larger than the clawback simply runs out
    ///      of tokens. No explicit cap to keep in sync.
    function test_TerminateAndReissue_CannotReachIdleBalance() public {
        token.mint(address(adapter), 500); // idle balance from elsewhere
        token.mint(address(controller), 100);
        controller.setClawback(100);
        controller.setReissue(NEW_ALLOCATION, 200);

        vm.prank(UMIA_ADMIN);
        vm.expectRevert(); // ERC20 insufficient balance: only the 100 clawback is reachable
        adapter.terminateAndReissue(OLD_ALLOCATION, _createCalldata(), _noProgram());
    }

    function test_TerminateAndReissue_FlushesIdleBalanceToTreasury() public {
        token.mint(address(adapter), 500);
        token.mint(address(controller), 100);
        controller.setClawback(100);
        controller.setReissue(NEW_ALLOCATION, 100);

        vm.prank(UMIA_ADMIN);
        adapter.terminateAndReissue(OLD_ALLOCATION, _createCalldata(), _noProgram());

        assertEq(token.balanceOf(TREASURY), 500, "idle balance went to the treasury, not the grant");
        assertEq(token.balanceOf(NEW_ALLOCATION), 100, "replacement funded by the clawback alone");
    }

    function test_TerminateAndReissue_RegistersReplacementLadder() public {
        token.mint(address(controller), 100);
        controller.setClawback(100);
        controller.setReissue(NEW_ALLOCATION, 100);

        uint160[] memory thresholds = new uint160[](2);
        thresholds[0] = 100;
        thresholds[1] = 200;
        IVentureVestingAuthority.PriceProgramInput memory program = IVentureVestingAuthority.PriceProgramInput({
            kind: IVentureVestingAuthority.PriceProgramKind.Absolute,
            absoluteThresholds: thresholds,
            multiplesX1e6: new uint256[](0),
            cliffs: new uint48[](0)
        });

        vm.prank(UMIA_ADMIN);
        adapter.terminateAndReissue(OLD_ALLOCATION, _createCalldata(), program);

        assertTrue(adapter.priceProgramKind(NEW_ALLOCATION) == IVentureVestingAuthority.PriceProgramKind.Absolute);
        assertEq(adapter.effectiveThreshold(NEW_ALLOCATION, 1), 200, "fresh allocation gets a fresh ladder");
    }

    function test_Revert_TerminateAndReissue_NotCreateMetavest() public {
        vm.prank(UMIA_ADMIN);
        vm.expectRevert(IVentureVestingAuthority.NotCreateMetavest.selector);
        adapter.terminateAndReissue(
            OLD_ALLOCATION, abi.encodeWithSignature("updateMetavestUnlockRate(address,uint160)"), _noProgram()
        );
    }

    function test_Revert_TerminateAndReissue_Stranger() public {
        vm.prank(STRANGER);
        vm.expectRevert(IVentureVestingAuthority.NotAuthorized.selector);
        adapter.terminateAndReissue(OLD_ALLOCATION, _createCalldata(), _noProgram());
    }

    // ── sweep ──

    function test_Sweep_IsPermissionlessAndPaysTreasury() public {
        token.mint(address(adapter), 250);

        vm.expectEmit(true, false, false, true);
        emit IVentureVestingAuthority.Swept(address(token), 250);

        vm.prank(STRANGER);
        adapter.sweep(address(token));

        assertEq(token.balanceOf(TREASURY), 250, "sweep can only ever pay the treasury");
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function test_TerminateGrant_ReturnsClawbackToTreasury() public {
        token.mint(address(controller), 100);
        controller.setClawback(100);

        vm.prank(UMIA_ADMIN);
        adapter.terminateGrant(OLD_ALLOCATION);

        assertEq(token.balanceOf(TREASURY), 100, "clawback goes home in the same call");
        assertEq(token.balanceOf(address(adapter)), 0, "nothing left for a later grant to consume");
    }

    function test_Revert_ForwardTerminateMustUseTerminateGrant() public {
        bytes memory data = abi.encodeWithSignature("terminateMetavestVesting(address)", OLD_ALLOCATION);
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.UseTerminateGrant.selector);
        adapter.forward(data, _noProgram());
    }

    function test_Sweep_NoOpAtZeroBalance() public {
        adapter.sweep(address(token));
        assertEq(token.balanceOf(TREASURY), 0);
    }
}
