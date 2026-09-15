// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {YieldPositionGuardian, IMorphoBlue} from "../../src/periphery/YieldPositionGuardian.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {FakeAavePool, FakeAToken, FakeMorpho, FakeVenture} from "./YieldPositionGuardianMocks.sol";

contract YieldPositionGuardianTest is Test {
    MockERC20 usdc;
    FakeAToken aUsdc;
    FakeAavePool pool;
    FakeVenture venture;
    FakeMorpho morpho;
    MockERC4626 vault;
    YieldPositionGuardian exit_;
    IMorphoBlue.MarketParams marketParams;

    address operator = address(0x0F1CE);
    address rando = address(0xBAD);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        aUsdc = new FakeAToken();
        pool = new FakeAavePool(address(usdc), address(aUsdc));
        venture = new FakeVenture();
        exit_ = new YieldPositionGuardian(address(venture), operator);

        // Venture holds a $4M supplied position and has granted the wrapper its aToken allowance.
        usdc.mint(address(venture), 4_000_000e18);
        venture.supply(address(pool), address(usdc), 4_000_000e18);
        venture.approve(address(aUsdc), address(exit_), type(uint256).max);
    }

    function test_ExitAave_ReturnsUnderlyingToVenture() public {
        vm.prank(operator);
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 4_000_000e18);

        assertEq(usdc.balanceOf(address(venture)), 4_000_000e18, "underlying back in treasury");
        assertEq(aUsdc.balanceOf(address(venture)), 0, "position closed");
        assertEq(usdc.balanceOf(operator), 0, "operator got nothing");
        assertEq(aUsdc.balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
        assertEq(usdc.balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
    }

    function test_ExitAave_PartialAmount() public {
        vm.prank(operator);
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 1_500_000e18);

        assertEq(usdc.balanceOf(address(venture)), 1_500_000e18);
        assertEq(aUsdc.balanceOf(address(venture)), 2_500_000e18, "rest of position stays put");
    }

    function test_ExitAave_CapsAtVentureBalance() public {
        vm.prank(operator);
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), type(uint256).max);

        assertEq(usdc.balanceOf(address(venture)), 4_000_000e18, "pulls at most what the venture has");
    }

    function test_ExitAave_LeavesStrayATokensForSweep() public {
        // Stray aTokens are NOT touched by an exit; they remain the job of `sweep`.
        deal(address(aUsdc), address(exit_), 123e18);

        vm.prank(operator);
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 1_000_000e18);

        assertEq(aUsdc.balanceOf(address(exit_)), 123e18, "strays untouched by exit");
        exit_.sweep(address(aUsdc));
        assertEq(aUsdc.balanceOf(address(exit_)), 0, "sweep returns strays");
    }

    function test_Revert_ExitAave_NotOwner() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 1);
    }

    function test_Revert_ExitAave_WithoutAllowance() public {
        YieldPositionGuardian unwired = new YieldPositionGuardian(address(venture), operator);
        vm.prank(operator);
        vm.expectRevert();
        unwired.exitAave(address(pool), address(aUsdc), address(usdc), 1);
    }

    function test_Sweep_ReturnsStrandedFundsToVenture() public {
        // Anyone can send stranded funds home.
        deal(address(aUsdc), address(exit_), 123e18);
        vm.prank(rando);
        exit_.sweep(address(aUsdc));
        assertEq(aUsdc.balanceOf(address(venture)), 4_000_000e18 + 123e18);
    }

    function test_Revert_Constructor_ZeroAddresses() public {
        vm.expectRevert(YieldPositionGuardian.InvalidParams.selector);
        new YieldPositionGuardian(address(0), operator);
        // Zero operator is rejected by OZ Ownable before our own check runs.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new YieldPositionGuardian(address(venture), address(0));
    }

    // ── Morpho path: positive withdrawal + authorization direction ──

    function _seedMorphoPosition(uint256 amount) internal {
        morpho = new FakeMorpho(address(usdc));
        usdc.mint(address(venture), amount);
        venture.morphoSupply(address(morpho), address(usdc), amount);
    }

    function test_ExitMorphoBlue_AuthorizedWithdrawalReturnsAssetsToVenture() public {
        _seedMorphoPosition(2_000_000e18);
        // Governance CALL action: venture authorizes the wrapper on Morpho.
        venture.morphoAuthorize(address(morpho), address(exit_), true);

        vm.prank(operator);
        exit_.exitMorphoBlue(address(morpho), marketParams, 2_000_000e18, 0);

        assertEq(morpho.lastOnBehalf(), address(venture), "withdraw is on behalf of the venture");
        assertEq(morpho.lastReceiver(), address(venture), "receiver is hardcoded to the venture");
        assertEq(usdc.balanceOf(address(venture)), 2_000_000e18, "assets back in treasury");
        assertEq(morpho.supplyBalance(address(venture)), 0, "position closed");
        assertEq(usdc.balanceOf(operator), 0, "operator got nothing");
        assertEq(usdc.balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
    }

    function test_Revert_ExitMorphoBlue_WithoutAuthorization() public {
        _seedMorphoPosition(2_000_000e18);
        // No setAuthorization: Morpho itself must reject the pull.
        vm.prank(operator);
        vm.expectRevert(FakeMorpho.Unauthorized.selector);
        exit_.exitMorphoBlue(address(morpho), marketParams, 2_000_000e18, 0);
    }

    function test_Revert_ExitMorphoBlue_NotOwner() public {
        _seedMorphoPosition(2_000_000e18);
        venture.morphoAuthorize(address(morpho), address(exit_), true);

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        exit_.exitMorphoBlue(address(morpho), marketParams, 1, 0);
    }

    function test_Revert_ExitMorphoBlue_ZeroAmounts() public {
        vm.prank(operator);
        vm.expectRevert(YieldPositionGuardian.InvalidParams.selector);
        exit_.exitMorphoBlue(address(0xBEEF), marketParams, 0, 0);
    }

    // ── ERC-4626 vault path: Morpho vaults, sUSDC and any other share token ──

    function _seedVaultPosition(uint256 assets) internal {
        vault = new MockERC4626(usdc, 0);
        usdc.mint(address(venture), assets);
        venture.vaultDeposit(address(vault), assets);
        // Governance SET_ALLOWANCE on the share token, not the underlying.
        venture.approve(address(vault), address(exit_), type(uint256).max);
    }

    function test_ExitVault_FullExitReturnsUnderlyingToVenture() public {
        _seedVaultPosition(3_000_000e18);

        vm.prank(operator);
        exit_.exitVault(address(vault), type(uint256).max);

        assertEq(vault.balanceOf(address(venture)), 0, "position closed");
        assertEq(usdc.balanceOf(address(venture)), 3_000_000e18, "underlying back in treasury");
        assertEq(usdc.balanceOf(operator), 0, "operator got nothing");
        assertEq(vault.balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
        assertEq(usdc.balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
    }

    function test_ExitVault_PartialShares() public {
        _seedVaultPosition(3_000_000e18);
        uint256 shares = vault.balanceOf(address(venture));

        vm.prank(operator);
        exit_.exitVault(address(vault), shares / 3);

        assertEq(vault.balanceOf(address(venture)), shares - shares / 3, "rest of position stays put");
        assertEq(usdc.balanceOf(address(venture)), vault.convertToAssets(shares / 3), "partial exit lands in treasury");
    }

    function test_ExitVault_CapsAtVentureBalance() public {
        _seedVaultPosition(3_000_000e18);
        uint256 shares = vault.balanceOf(address(venture));

        vm.prank(operator);
        exit_.exitVault(address(vault), shares * 10);

        assertEq(vault.balanceOf(address(venture)), 0, "redeems at most what the venture has");
        assertEq(usdc.balanceOf(address(venture)), 3_000_000e18);
    }

    function test_ExitVault_ReceivesAccruedYield() public {
        _seedVaultPosition(3_000_000e18);
        usdc.mint(address(this), 300_000e18);
        usdc.approve(address(vault), 300_000e18);
        vault.donate(300_000e18);

        vm.prank(operator);
        exit_.exitVault(address(vault), type(uint256).max);

        assertApproxEqAbs(usdc.balanceOf(address(venture)), 3_300_000e18, 1, "yield comes home with the principal");
    }

    function test_Revert_ExitVault_WithoutShareAllowance() public {
        vault = new MockERC4626(usdc, 0);
        usdc.mint(address(venture), 1_000e18);
        venture.vaultDeposit(address(vault), 1_000e18);

        vm.prank(operator);
        vm.expectRevert();
        exit_.exitVault(address(vault), type(uint256).max);
    }

    function test_Revert_ExitVault_NotOwner() public {
        _seedVaultPosition(1_000e18);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        exit_.exitVault(address(vault), 1);
    }

    function test_Revert_ExitVault_ZeroShares() public {
        vm.prank(operator);
        vm.expectRevert(YieldPositionGuardian.InvalidParams.selector);
        exit_.exitVault(address(0xBEEF), 0);
    }

    function test_Revert_ExitVault_NoPosition() public {
        vault = new MockERC4626(usdc, 0);
        vm.prank(operator);
        vm.expectRevert(YieldPositionGuardian.InvalidParams.selector);
        exit_.exitVault(address(vault), type(uint256).max);
    }

    // ── Operator rotation (Ownable2Step) ──

    function test_RotateOperator_NewOperatorCanExit_OldCannot() public {
        address rotated = address(0xBEEF);

        vm.prank(operator);
        exit_.transferOwnership(rotated);
        // Not yet accepted: the old operator still holds the role.
        assertEq(exit_.owner(), operator);

        vm.prank(rotated);
        exit_.acceptOwnership();
        assertEq(exit_.owner(), rotated);

        vm.prank(rotated);
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 1_000_000e18);
        assertEq(usdc.balanceOf(address(venture)), 1_000_000e18, "new operator can exit");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 1);
    }

    function test_RotateOperator_PendingAcceptBlocksHalfwayState() public {
        address rotated = address(0xBEEF);

        vm.prank(operator);
        exit_.transferOwnership(rotated);

        // Pending owner has no power before accepting.
        vm.prank(rotated);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rotated));
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 1);

        // Old operator still works during the handover.
        vm.prank(operator);
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 1_000_000e18);
        assertEq(usdc.balanceOf(address(venture)), 1_000_000e18);
    }

    function test_Revert_RotateOperator_NotOwner() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        exit_.transferOwnership(rando);
    }

    function test_RenounceOwnership_DisablesEmergencyPath() public {
        vm.prank(operator);
        exit_.renounceOwnership();
        assertEq(exit_.owner(), address(0));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        exit_.exitAave(address(pool), address(aUsdc), address(usdc), 1);
    }
}
