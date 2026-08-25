// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {MetaVesTTestBase} from "../vesting/MetaVesTTestBase.t.sol";
import {UmiaTwapMilestoneCondition, IMetaVesTAllocation} from "../../src/periphery/UmiaTwapMilestoneCondition.sol";
import {IUmiaTwapMilestoneCondition} from "../../src/interfaces/IUmiaTwapMilestoneCondition.sol";
import {IVentureVestingAuthority} from "../../src/interfaces/IVentureVestingAuthority.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";

/// @dev Makes `allocation.getMetavestDetails().tokenContract` return `token`, the token accessor the
///      condition reads for the TWAP. Shared by the suites below.
function _mockAllocationToken(Vm vm, address allocation, address token) {
    IMetaVesTAllocation.Allocation memory a;
    a.tokenContract = token;
    vm.mockCall(allocation, abi.encodeWithSelector(IMetaVesTAllocation.getMetavestDetails.selector), abi.encode(a));
}

/// @dev Makes the condition resolve `allocation -> controller -> authority -> effectiveThreshold(idx)`
///      to `threshold`. The condition reads the price ladder from the allocation's adapter; here that
///      whole chain is mocked so the suite can focus on the TWAP comparison. The milestone's cliff
///      defaults to 0 (price-only); override with `_mockCliff`.
function _mockThreshold(Vm vm, address allocation, uint256 idx, uint160 threshold) {
    address ctrl = address(0xC04401);
    address auth = address(0xADA97E5);
    vm.mockCall(allocation, abi.encodeWithSignature("controller()"), abi.encode(ctrl));
    vm.mockCall(ctrl, abi.encodeWithSignature("authority()"), abi.encode(auth));
    vm.mockCall(
        auth,
        abi.encodeWithSelector(IVentureVestingAuthority.effectiveThreshold.selector, allocation, idx),
        abi.encode(threshold)
    );
    _mockCliff(vm, allocation, idx, 0);
}

/// @dev Makes the mocked authority resolve `effectiveCliff(allocation, idx)` to `cliff`.
function _mockCliff(Vm vm, address allocation, uint256 idx, uint48 cliff) {
    vm.mockCall(
        address(0xADA97E5),
        abi.encodeWithSelector(IVentureVestingAuthority.effectiveCliff.selector, allocation, idx),
        abi.encode(cliff)
    );
}

// ═══════════════════════════════════════════════════════════════
// Unit tests: constructor only (the slim condition has no registry)
// ═══════════════════════════════════════════════════════════════

contract UmiaTwapMilestoneConditionUnitTest is Test {
    function test_Revert_ZeroTwapWindow() public {
        vm.expectRevert(IUmiaTwapMilestoneCondition.InvalidTwapWindow.selector);
        new UmiaTwapMilestoneCondition(0);
    }

    function test_Deploy_StoresWindow() public {
        UmiaTwapMilestoneCondition c = new UmiaTwapMilestoneCondition(30 minutes);
        assertEq(c.TWAP_WINDOW(), 30 minutes);
    }
}

// ═══════════════════════════════════════════════════════════════
// Integration: real venture/pool TWAP, mocked threshold resolution
// ═══════════════════════════════════════════════════════════════

abstract contract TwapMilestoneConditionTestBase is MetaVesTTestBase {
    address payable _venture;
    address _token;

    function setUp() public virtual override {
        super.setUp();
        (, _venture) = _createVentureWithLBP(hub, alice);
        _token = IVenture(_venture).token();
        _deployCondition();
    }
}

contract UmiaTwapMilestoneConditionIntegrationTest is TwapMilestoneConditionTestBase {
    address constant ALLOCATION = address(0xA110);

    /// @dev Point the allocation at the real venture token and resolve milestone 0 to `threshold`.
    function _register(uint160 threshold) internal {
        _mockAllocationToken(vm, ALLOCATION, _token);
        _mockThreshold(vm, ALLOCATION, 0, threshold);
    }

    function _check(uint256 idx) internal view returns (bool) {
        return condition.checkCondition(ALLOCATION, bytes4(0), abi.encode(idx));
    }

    function test_check_trueAtThreshold() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _register(_twapPriceX96(_venture));
        assertTrue(_check(0));
    }

    function test_check_trueAboveThreshold() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _register(_twapPriceX96(_venture) - 1);
        assertTrue(_check(0));
    }

    function test_check_falseBelowThreshold() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _register(_twapPriceX96(_venture) + 1);
        assertFalse(_check(0));
    }

    // ── optional per-milestone cliff: confirms only when cliff elapsed AND TWAP >= threshold ──

    function test_check_falseBeforeCliffEvenWhenPriceMet() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _register(_twapPriceX96(_venture));
        _mockCliff(vm, ALLOCATION, 0, uint48(block.timestamp + 1));
        assertFalse(_check(0));
    }

    function test_check_falseAfterCliffWhenPriceNotMet() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _register(_twapPriceX96(_venture) + 1);
        _mockCliff(vm, ALLOCATION, 0, uint48(block.timestamp - 1));
        assertFalse(_check(0));
    }

    function test_check_trueWhenCliffElapsedAndPriceMet() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _register(_twapPriceX96(_venture));
        _mockCliff(vm, ALLOCATION, 0, uint48(block.timestamp));
        assertTrue(_check(0), "cliff == block.timestamp has elapsed");
    }

    /// @dev An unelapsed cliff short-circuits before the TWAP read, so a cliffed milestone answers
    ///      false instead of raising the fail-closed oracle revert.
    function test_check_falseBeforeCliffEvenWhenOracleNotReady() public {
        _register(1);
        _mockCliff(vm, ALLOCATION, 0, uint48(block.timestamp + 365 days));
        vm.warp(block.timestamp + 1 minutes); // shorter than TWAP_WINDOW
        assertFalse(_check(0));
    }

    function test_check_revertsNoLpToken() public {
        _register(1);
        vm.mockCall(
            address(hub), abi.encodeWithSignature("ventureLiquidityVault(address)", _venture), abi.encode(address(0))
        );
        vm.expectRevert(IUmiaTwapMilestoneCondition.NoLpToken.selector);
        _check(0);
    }

    function test_check_revertsOracleNotReady() public {
        _register(1);
        vm.warp(block.timestamp + 1 minutes); // shorter than TWAP_WINDOW
        vm.expectRevert(IUmiaTwapMilestoneCondition.OracleNotReady.selector);
        _check(0);
    }

    /// @notice Regression: a 30-day condition stays evaluable via the coarse ring after sustained
    ///         trading has wrapped the per-block ring.
    function test_check_thirtyDayWindowServableAfterFineRingWraps() public {
        UmiaTwapMilestoneCondition longCondition = new UmiaTwapMilestoneCondition(30 days);

        IUmiaHook hook = IUmiaLBP(IVenture(_venture).lbp()).umiaHook();
        PoolKey memory key = ISpotLiquidityVault(hub.ventureLiquidityVault(_venture)).getPoolKey();

        hook.increaseCoarseCardinalityNext(key, 768);
        vm.warp(block.timestamp + 30 days);
        for (uint256 i = 0; i < 110; i++) {
            vm.warp(block.timestamp + 1 hours);
            _swapSpot(_venture, 0.01e18, i % 2 == 0);
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 30 days;
        secondsAgos[1] = 0;
        vm.expectRevert();
        hook.observe(key, secondsAgos);

        _register(1);
        assertTrue(longCondition.checkCondition(ALLOCATION, bytes4(0), abi.encode(0)));

        _mockThreshold(vm, ALLOCATION, 1, type(uint160).max);
        assertFalse(longCondition.checkCondition(ALLOCATION, bytes4(0), abi.encode(1)));
    }

    function test_check_capsOverflowingPriceAtUint160Max() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _register(type(uint160).max);

        IUmiaHook hook = IUmiaLBP(IVenture(_venture).lbp()).umiaHook();
        PoolKey memory key = ISpotLiquidityVault(hub.ventureLiquidityVault(_venture)).getPoolKey();
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == _token;

        // A sqrtPrice extreme enough that the Q96 price overflows uint160 in whichever
        // branch this pool's token ordering takes (direct square, or its inverse).
        uint160 sqrtP = tokenIsCurrency0 ? uint160(1 << 140) : uint160(1 << 56);
        int48 windowInt = int48(uint48(TWAP_WINDOW));
        int48[] memory tickCumulatives = new int48[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int48(TickMath.getTickAtSqrtPrice(sqrtP)) * windowInt;
        vm.mockCall(
            address(hook),
            abi.encodeWithSelector(IUmiaHook.observe.selector),
            abi.encode(tickCumulatives, new uint144[](2))
        );

        // Capped to uint160 max the price clears the max threshold; a silent truncation would not.
        assertTrue(_check(0));
    }

    function test_check_capsInvertedPriceWhenNonInvertedRoundsToZero() public {
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        _register(type(uint160).max);

        IUmiaHook hook = IUmiaLBP(IVenture(_venture).lbp()).umiaHook();

        // Force the inverted branch (venture token as currency1) regardless of fixture ordering.
        PoolKey memory key;
        key.currency0 = Currency.wrap(makeAddr("money"));
        key.currency1 = Currency.wrap(_token);
        vm.mockCall(
            hub.ventureLiquidityVault(_venture),
            abi.encodeWithSelector(ISpotLiquidityVault.getPoolKey.selector),
            abi.encode(key)
        );

        // sqrtP < 2^48 makes the non-inverted Q96 price floor to 0; without the guard the inversion
        // divides by zero. 2^40 is above MIN_SQRT_PRICE and below the 2^48 boundary.
        uint160 sqrtP = uint160(1 << 40);
        int48 windowInt = int48(uint48(TWAP_WINDOW));
        int48[] memory tickCumulatives = new int48[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int48(TickMath.getTickAtSqrtPrice(sqrtP)) * windowInt;
        vm.mockCall(
            address(hook),
            abi.encodeWithSelector(IUmiaHook.observe.selector),
            abi.encode(tickCumulatives, new uint144[](2))
        );

        // Guarded: the reciprocal caps at uint160 max and clears the max threshold; unguarded it reverted.
        assertTrue(_check(0));
    }
}
