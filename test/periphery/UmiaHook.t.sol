// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {UmiaHook} from "../../src/periphery/UmiaHook.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {SpotMarketOracle} from "../../src/libraries/SpotMarketOracle.sol";

// Permission flags: 1<<13 | 1<<12 | 1<<11 | 1<<9 | 1<<7 = 0x3A80.
// beforeInitialize, afterInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap.
uint160 constant HOOK_FLAGS = 0x3A80;

contract UmiaHookInitializeTest is Test {
    UmiaHook public hook;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant POOL_MANAGER = address(0xBEEF);

    function setUp() public {
        // INITIAL_OWNER is immutable, baked into runtime bytecode, so vm.etch preserves it.
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);
    }

    function test_Initialize_OnlyOwner() public {
        vm.expectRevert(IUmiaHook.NotInitialOwner.selector);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));
    }

    function test_Initialize_HappyPath() public {
        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));
        assertEq(hook.factory(), FACTORY);
        assertEq(address(hook.poolManager()), POOL_MANAGER);
    }

    function test_Initialize_OneShot() public {
        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));
        vm.prank(OWNER);
        vm.expectRevert(IUmiaHook.FactoryAlreadySet.selector);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));
    }

    /// @notice Regression test: a zero factory must revert so the one-shot guard cannot be
    ///         bypassed by leaving factory unwritten.
    function test_Initialize_RevertsOnZeroFactory() public {
        vm.prank(OWNER);
        vm.expectRevert(IUmiaHook.InvalidFactory.selector);
        hook.initialize(address(0), IPoolManager(POOL_MANAGER));
    }

    function test_Initialize_RevertsOnZeroPoolManager() public {
        vm.prank(OWNER);
        vm.expectRevert(IUmiaHook.InvalidPoolManager.selector);
        hook.initialize(FACTORY, IPoolManager(address(0)));
    }

    /// @notice Zero `_initialOwner` must revert in the constructor, otherwise the deployed
    ///         hook at the mined CreateX address is permanently bricked (no caller can ever
    ///         satisfy `msg.sender == address(0)` to call `initialize`).
    function test_Constructor_RevertsOnZeroInitialOwner() public {
        vm.expectRevert(IUmiaHook.InvalidInitialOwner.selector);
        new UmiaHook(address(0));
    }
}

contract UmiaHookPermissionsTest is Test {
    UmiaHook public hook;
    address constant OWNER = address(0xABCD);

    function setUp() public {
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);
    }

    /// @notice The hook is oracle-only + operator-gated: it hooks the init, liquidity, and
    ///         pre-swap callbacks but takes no swap-time delta.
    function test_GetHookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertTrue(perms.afterInitialize);
        assertTrue(perms.beforeAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertTrue(perms.beforeSwap);

        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertFalse(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }
}

interface IFactoryMock {
    function isLBP(address) external view returns (bool);
}

contract UmiaHookRegisterPoolTest is Test {
    using PoolIdLibrary for PoolKey;

    UmiaHook public hook;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant LBP = address(0xDEAD);
    address constant VENTURE = address(0x1234);
    address constant OPERATOR = address(0x5678);

    PoolKey internal key;

    function setUp() public {
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);

        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));

        key = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _cfg(address launcher) internal pure returns (IUmiaHook.PoolConfig memory) {
        return IUmiaHook.PoolConfig({launcher: launcher, venture: VENTURE, operator: OPERATOR});
    }

    function test_RegisterPool_RejectsNonLBPCaller() public {
        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(false));
        vm.prank(LBP);
        vm.expectRevert(abi.encodeWithSelector(IUmiaHook.NotFactoryDeployedLBP.selector, LBP));
        hook.registerPool(key, _cfg(LBP));
    }

    function test_RegisterPool_HappyPath() public {
        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));

        vm.expectEmit(true, true, false, true);
        emit IUmiaHook.PoolRegistered(
            key.toId(), OPERATOR, IUmiaHook.PoolConfig({launcher: LBP, venture: VENTURE, operator: OPERATOR})
        );

        vm.prank(LBP);
        hook.registerPool(key, _cfg(LBP));

        (address launcher, address venture, address operator) = hook.pools(key.toId());
        assertEq(launcher, LBP);
        assertEq(venture, VENTURE);
        assertEq(operator, OPERATOR);
    }

    /// @notice `launcher` is forced to `msg.sender`; a spoofed calldata launcher is ignored.
    function test_RegisterPool_ForcesLauncherToSender() public {
        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        hook.registerPool(key, _cfg(address(0xBAD)));

        (address launcher,,) = hook.pools(key.toId());
        assertEq(launcher, LBP);
    }

    function test_RegisterPool_RejectsDoubleRegistration() public {
        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        hook.registerPool(key, _cfg(LBP));
        vm.prank(LBP);
        vm.expectRevert(abi.encodeWithSelector(IUmiaHook.PoolAlreadyRegistered.selector, key.toId()));
        hook.registerPool(key, _cfg(LBP));
    }

    function test_RegisterPool_RejectsInvalidVenture() public {
        IUmiaHook.PoolConfig memory cfg = _cfg(LBP);
        cfg.venture = address(0);
        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        vm.expectRevert(IUmiaHook.InvalidVentureAddress.selector);
        hook.registerPool(key, cfg);
    }

    function test_RegisterPool_RejectsInvalidOperator() public {
        IUmiaHook.PoolConfig memory cfg = _cfg(LBP);
        cfg.operator = address(0);
        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        vm.expectRevert(IUmiaHook.InvalidOperator.selector);
        hook.registerPool(key, cfg);
    }

    /// @notice Regression: rejects a PoolKey whose `hooks` field points anywhere other than the
    ///         singleton itself. V4 hashes `hooks` into the PoolId, so an entry with the wrong
    ///         hooks field would be orphaned in storage.
    function test_RegisterPool_RejectsWrongHooksAddress() public {
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0xBAD))
        });
        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        vm.expectRevert(abi.encodeWithSelector(IUmiaHook.InvalidHooksAddress.selector, address(0xBAD), address(hook)));
        hook.registerPool(badKey, _cfg(LBP));
    }
}

contract UmiaHookBeforeInitializeTest is Test {
    using PoolIdLibrary for PoolKey;

    UmiaHook public hook;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant LBP = address(0xDEAD);
    address constant VENTURE = address(0x1234);
    address constant OPERATOR = address(0x5678);

    PoolKey internal key;

    function setUp() public {
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);

        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));

        key = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        hook.registerPool(key, IUmiaHook.PoolConfig({launcher: LBP, venture: VENTURE, operator: OPERATOR}));
    }

    function test_BeforeInitialize_AcceptsRegisteredLauncher() public {
        vm.prank(POOL_MANAGER);
        bytes4 sel = hook.beforeInitialize(LBP, key, uint160(1 << 96));
        assertEq(sel, IHooks.beforeInitialize.selector);
    }

    function test_BeforeInitialize_RejectsOtherSender() public {
        address rando = address(0xCAFE);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IUmiaHook.UnauthorizedLauncher.selector, rando, LBP));
        hook.beforeInitialize(rando, key, uint160(1 << 96));
    }

    function test_BeforeInitialize_RevertsIfNotPoolManager() public {
        vm.expectRevert(IUmiaHook.OnlyPoolManager.selector);
        hook.beforeInitialize(LBP, key, uint160(1 << 96));
    }

    function test_BeforeInitialize_RevertsForUnregisteredPool() public {
        PoolKey memory unregisteredKey = PoolKey({
            currency0: Currency.wrap(address(0x99)),
            currency1: Currency.wrap(address(0xAA)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IUmiaHook.UnauthorizedLauncher.selector, LBP, address(0)));
        hook.beforeInitialize(LBP, unregisteredKey, uint160(1 << 96));
    }
}

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract UmiaHookOracleTest is Test {
    using PoolIdLibrary for PoolKey;

    UmiaHook public hook;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant LBP = address(0xDEAD);
    address constant VENTURE = address(0x1234);
    address constant OPERATOR = address(0x5678);
    PoolKey internal key;

    function setUp() public {
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);

        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));

        key = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        hook.registerPool(key, IUmiaHook.PoolConfig({launcher: LBP, venture: VENTURE, operator: OPERATOR}));
    }

    function test_AfterInitialize_SeedsOracle() public {
        vm.prank(POOL_MANAGER);
        hook.afterInitialize(LBP, key, uint160(1 << 96), int24(0));
        (, uint16 cardinality, uint16 cardinalityNext) = hook.oracleStates(key.toId());
        assertEq(cardinality, 1);
        assertEq(cardinalityNext, 1);
    }

    function test_AfterInitialize_RevertsIfNotPoolManager() public {
        vm.expectRevert(IUmiaHook.OnlyPoolManager.selector);
        hook.afterInitialize(LBP, key, uint160(1 << 96), int24(0));
    }

    function test_IncreaseCardinalityNext_GrowsBuffer() public {
        vm.prank(POOL_MANAGER);
        hook.afterInitialize(LBP, key, uint160(1 << 96), int24(0));
        (uint16 oldVal, uint16 newVal) = hook.increaseCardinalityNext(key, 100);
        assertEq(oldVal, 1);
        assertEq(newVal, 100);
        (,, uint16 cardinalityNext) = hook.oracleStates(key.toId());
        assertEq(cardinalityNext, 100);
    }

    function test_Observe_ReturnsSeededObservation() public {
        vm.prank(POOL_MANAGER);
        hook.afterInitialize(LBP, key, uint160(1 << 96), int24(0));

        // StateLibrary reads via extsload; one packed slot covers getSlot0 and getLiquidity.
        vm.mockCall(
            POOL_MANAGER, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)"))), abi.encode(uint256(1 << 96))
        );

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) =
            hook.observe(key, secondsAgos);
        assertEq(tickCumulatives.length, 1);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 1);
    }

    function test_ObserveLong_RevertsBeforeOracleInitialization() public {
        uint32[] memory secondsAgos = new uint32[](1);
        vm.expectRevert(SpotMarketOracle.OracleCardinalityCannotBeZero.selector);
        hook.observeLong(key, secondsAgos);
    }
}

contract UmiaHookBeforeAddLiquidityTest is Test {
    using PoolIdLibrary for PoolKey;

    UmiaHook public hook;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant LBP = address(0xDEAD);
    address constant VENTURE = address(0x1234);
    address constant OPERATOR = address(0x5678);
    PoolKey internal key;

    function setUp() public {
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);

        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));

        key = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        hook.registerPool(key, IUmiaHook.PoolConfig({launcher: LBP, venture: VENTURE, operator: OPERATOR}));

        vm.prank(POOL_MANAGER);
        hook.afterInitialize(LBP, key, uint160(1 << 96), int24(0));

        // StateLibrary reads via extsload; mock returns a packed slot value where
        // bottom 160 bits = sqrtPriceX96 = 1<<96, tick/protocolFee/lpFee = 0.
        // The same mock satisfies the liquidity slot read (low 128 bits = 0).
        vm.mockCall(
            POOL_MANAGER, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)"))), abi.encode(uint256(1 << 96))
        );
    }

    function _fullRangeParams() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1,
            salt: bytes32(0)
        });
    }

    function test_BeforeAddLiquidity_AcceptsOperatorFullRange() public {
        vm.warp(block.timestamp + 1);
        vm.prank(POOL_MANAGER);
        bytes4 sel = hook.beforeAddLiquidity(OPERATOR, key, _fullRangeParams(), "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    function test_BeforeAddLiquidity_RejectsNonOperator() public {
        address rando = address(0xCAFE);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IUmiaHook.UnauthorizedLiquidityOperator.selector, rando, OPERATOR));
        hook.beforeAddLiquidity(rando, key, _fullRangeParams(), "");
    }

    function test_BeforeAddLiquidity_RejectsConcentrated() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: int24(-60), tickUpper: int24(60), liquidityDelta: 1, salt: bytes32(0)});
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IUmiaHook.OnlyFullRangePositions.selector);
        hook.beforeAddLiquidity(OPERATOR, key, params, "");
    }

    function test_BeforeAddLiquidity_RevertsIfNotPoolManager() public {
        vm.expectRevert(IUmiaHook.OnlyPoolManager.selector);
        hook.beforeAddLiquidity(OPERATOR, key, _fullRangeParams(), "");
    }
}

contract UmiaHookBeforeRemoveLiquidityTest is Test {
    using PoolIdLibrary for PoolKey;

    UmiaHook public hook;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant LBP = address(0xDEAD);
    address constant VENTURE = address(0x1234);
    address constant OPERATOR = address(0x5678);
    PoolKey internal key;

    function setUp() public {
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);

        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));

        key = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        hook.registerPool(key, IUmiaHook.PoolConfig({launcher: LBP, venture: VENTURE, operator: OPERATOR}));

        vm.prank(POOL_MANAGER);
        hook.afterInitialize(LBP, key, uint160(1 << 96), int24(0));

        vm.mockCall(
            POOL_MANAGER, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)"))), abi.encode(uint256(1 << 96))
        );
    }

    function _params() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: -1,
            salt: bytes32(0)
        });
    }

    function test_BeforeRemoveLiquidity_AcceptsOperator() public {
        vm.warp(block.timestamp + 1);
        vm.prank(POOL_MANAGER);
        bytes4 sel = hook.beforeRemoveLiquidity(OPERATOR, key, _params(), "");
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_BeforeRemoveLiquidity_RejectsNonOperator() public {
        address rando = address(0xCAFE);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IUmiaHook.UnauthorizedLiquidityOperator.selector, rando, OPERATOR));
        hook.beforeRemoveLiquidity(rando, key, _params(), "");
    }

    function test_BeforeRemoveLiquidity_RevertsIfNotPoolManager() public {
        vm.expectRevert(IUmiaHook.OnlyPoolManager.selector);
        hook.beforeRemoveLiquidity(OPERATOR, key, _params(), "");
    }
}

contract UmiaHookBeforeSwapTest is Test {
    using PoolIdLibrary for PoolKey;

    UmiaHook public hook;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant LBP = address(0xDEAD);
    address constant VENTURE = address(0x1234);
    address constant OPERATOR = address(0x5678);
    PoolKey internal key;

    function setUp() public {
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);

        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));

        key = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        hook.registerPool(key, IUmiaHook.PoolConfig({launcher: LBP, venture: VENTURE, operator: OPERATOR}));

        vm.prank(POOL_MANAGER);
        hook.afterInitialize(LBP, key, uint160(1 << 96), int24(0));

        // StateLibrary reads via extsload; one packed slot covers getSlot0 and getLiquidity.
        vm.mockCall(
            POOL_MANAGER, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)"))), abi.encode(uint256(1 << 96))
        );
    }

    function test_BeforeSwap_WritesObservationAndReturnsZeroDelta() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: uint160(1 << 90)});
        vm.warp(block.timestamp + 12);
        vm.prank(POOL_MANAGER);
        (bytes4 sel,, uint24 lpFee) = hook.beforeSwap(LBP, key, params, "");
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(lpFee, 0);

        (uint32 ts,,,) = hook.getObservation(key.toId(), 0);
        assertEq(ts, uint32(block.timestamp));
    }

    /// @notice `afterSwap` is a permissioned no-op: the hook takes no swap-time delta, so swap
    ///         fees accrue V4-natively inside the operator's position.
    function test_AfterSwap_IsNoop() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: uint160(1 << 90)});
        BalanceDelta delta = BalanceDelta.wrap(0);
        vm.prank(POOL_MANAGER);
        (bytes4 sel, int128 hookDelta) = hook.afterSwap(LBP, key, params, delta, "");
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
    }
}

contract UmiaHookCoarseOracleTest is Test {
    using PoolIdLibrary for PoolKey;

    UmiaHook public hook;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant POOL_MANAGER = address(0xBEEF);
    address constant LBP = address(0xDEAD);
    address constant VENTURE = address(0x1234);
    address constant OPERATOR = address(0x5678);
    // Hour-aligned so bucket arithmetic in the tests reads directly off the timestamps.
    uint256 constant T0 = 360_000 hours;
    uint32 constant INTERVAL = 1 hours;

    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        UmiaHook deployed = new UmiaHook(OWNER);
        address target = address(HOOK_FLAGS);
        vm.etch(target, address(deployed).code);
        hook = UmiaHook(target);

        vm.prank(OWNER);
        hook.initialize(FACTORY, IPoolManager(POOL_MANAGER));

        key = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        vm.mockCall(FACTORY, abi.encodeWithSelector(IFactoryMock.isLBP.selector, LBP), abi.encode(true));
        vm.prank(LBP);
        hook.registerPool(key, IUmiaHook.PoolConfig({launcher: LBP, venture: VENTURE, operator: OPERATOR}));

        vm.warp(T0);
        vm.prank(POOL_MANAGER);
        hook.afterInitialize(LBP, key, uint160(1 << 96), int24(0));

        _mockPoolTick(0);
    }

    /// @dev Packs tick (bits 160-183) and a nonzero liquidity (low 128 bits) into the extsload word.
    function _mockPoolTick(int24 tick) internal {
        vm.mockCall(
            POOL_MANAGER,
            abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)"))),
            abi.encode((uint256(uint24(tick)) << 160) | (1 << 96))
        );
    }

    function _swap() internal {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: uint160(1 << 90)});
        vm.prank(POOL_MANAGER);
        hook.beforeSwap(LBP, key, params, "");
    }

    function _coarseState() internal view returns (uint16 index, uint16 cardinality, uint16 cardinalityNext) {
        return hook.coarseOracleStates(id);
    }

    function test_AfterInitialize_SeedsCoarseRing() public view {
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = _coarseState();
        assertEq(index, 0);
        assertEq(cardinality, 1);
        assertEq(cardinalityNext, 1);

        (uint32 ts, int48 tickCumulative,, bool initialized) = hook.getCoarseObservation(id, 0);
        assertEq(ts, uint32(T0));
        assertEq(tickCumulative, 0);
        assertTrue(initialized);
    }

    function test_CoarseInterval_IsOneHour() public view {
        assertEq(hook.COARSE_INTERVAL(), 1 hours);
    }

    /// @notice The coarse write gates per interval bucket, not per elapsed interval.
    function test_CoarseWrite_OncePerIntervalBucket() public {
        hook.increaseCoarseCardinalityNext(key, 8);

        vm.warp(T0 + 12);
        _swap();
        vm.warp(T0 + 3599);
        _swap();
        (uint16 index, uint16 cardinality,) = _coarseState();
        assertEq(index, 0, "same bucket as the seed must not write");
        assertEq(cardinality, 1);

        vm.warp(T0 + 2 * INTERVAL - 1);
        _swap();
        (index, cardinality,) = _coarseState();
        assertEq(index, 1, "first event of a new bucket writes");
        assertEq(cardinality, 8, "first write past the seed bumps cardinality to cardinalityNext");

        vm.warp(T0 + 2 * INTERVAL + 1);
        _swap();
        (index,,) = _coarseState();
        assertEq(index, 2, "2s later but across a bucket boundary writes again");

        vm.warp(T0 + 2 * INTERVAL + 100);
        _swap();
        (index,,) = _coarseState();
        assertEq(index, 2, "later event in the same bucket must not write");
    }

    function test_RingCursorsAreIndependent() public {
        hook.increaseCardinalityNext(key, 4);
        hook.increaseCoarseCardinalityNext(key, 4);

        for (uint256 i = 1; i <= 3; i++) {
            vm.warp(T0 + i * 12);
            _swap();
        }
        (uint16 fineIndex, uint16 fineCardinality,) = hook.oracleStates(id);
        (uint16 coarseIndex, uint16 coarseCardinality,) = _coarseState();
        assertEq(fineIndex, 3, "per-block ring advances every block");
        assertEq(fineCardinality, 4);
        assertEq(coarseIndex, 0, "coarse ring untouched within the seed bucket");
        assertEq(coarseCardinality, 1);

        vm.warp(T0 + INTERVAL);
        _swap();
        (fineIndex,,) = hook.oracleStates(id);
        (coarseIndex,,) = _coarseState();
        assertEq(fineIndex, 0, "per-block ring wrapped at its own cardinality");
        assertEq(coarseIndex, 1, "coarse ring wrote its first post-seed observation");
    }

    function test_IncreaseCoarseCardinalityNext_GrowsAndNoOps() public {
        (uint16 oldVal, uint16 newVal) = hook.increaseCoarseCardinalityNext(key, 768);
        assertEq(oldVal, 1);
        assertEq(newVal, 768);

        (oldVal, newVal) = hook.increaseCoarseCardinalityNext(key, 100);
        assertEq(oldVal, 768);
        assertEq(newVal, 768, "smaller request is a no-op");

        (,, uint16 fineCardinalityNext) = hook.oracleStates(id);
        assertEq(fineCardinalityNext, 1, "growing the coarse ring must not touch the per-block ring");
    }

    function test_ObserveLong_ServesSeededObservation() public view {
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) =
            hook.observeLong(key, secondsAgos);
        assertEq(tickCumulatives.length, 1);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 1);
    }

    function test_ObserveLong_RevertsBeyondOldestObservation() public {
        vm.warp(T0 + 100);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 3600;
        vm.expectRevert(
            abi.encodeWithSelector(
                SpotMarketOracle.TargetPredatesOldestObservation.selector, uint32(T0), uint32(T0 + 100 - 3600)
            )
        );
        hook.observeLong(key, secondsAgos);
    }

    /// @notice At cardinality 1 a write overwrites the seed, retaining only the latest observation.
    function test_CoarseCardinalityOne_RetainsOnlyLatestObservation() public {
        vm.warp(T0 + INTERVAL + 1);
        _swap();
        (uint16 index, uint16 cardinality,) = _coarseState();
        assertEq(index, 0, "ungrown ring wraps in place");
        assertEq(cardinality, 1);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 3600;
        vm.expectRevert(
            abi.encodeWithSelector(
                SpotMarketOracle.TargetPredatesOldestObservation.selector, uint32(T0 + INTERVAL + 1), uint32(T0 + 1)
            )
        );
        hook.observeLong(key, secondsAgos);
    }

    /// @notice A coarse checkpoint copies the per-block cumulative, so it carries the true integral
    ///         of the intra-bucket price path rather than a boundary resample.
    function test_CoarseRing_SnapshotsFineCumulative() public {
        hook.increaseCardinalityNext(key, 16);
        hook.increaseCoarseCardinalityNext(key, 16);

        // Bucket 1 opens at tick 0, then a 100s excursion to tick 300, then back to 0.
        _mockPoolTick(0);
        vm.warp(T0 + INTERVAL);
        _swap();
        _mockPoolTick(300);
        vm.warp(T0 + INTERVAL + 100);
        _swap();
        _mockPoolTick(0);
        vm.warp(T0 + 2 * INTERVAL); // first event of bucket 2 -> coarse checkpoint
        _swap();

        (uint16 fineIndex,,) = hook.oracleStates(id);
        (uint16 coarseIndex,,) = _coarseState();
        (uint32 fineTs, int48 fineCum,,) = hook.getObservation(id, fineIndex);
        (uint32 coarseTs, int48 coarseCum,,) = hook.getCoarseObservation(id, coarseIndex);

        assertEq(coarseTs, fineTs, "coarse checkpoint copies the fine observation timestamp");
        assertEq(coarseCum, fineCum, "coarse cumulative is the per-block integral, not a boundary resample");
        // 300 ticks x 100s; a boundary resample (tick 0 at the bucket-2 write) would record 0.
        assertEq(coarseCum, int48(300) * int48(100), "intra-bucket excursion is integrated exactly");
    }

    /// @notice A tick spike held across an hour boundary earns only its real duration of weight,
    ///         not the whole interval a boundary resample would charge it.
    function test_CoarseWrite_BoundarySpikeNotAmplified() public {
        hook.increaseCardinalityNext(key, 16);
        hook.increaseCoarseCardinalityNext(key, 16);

        _mockPoolTick(0);
        vm.warp(T0 + INTERVAL); // bucket-1 coarse checkpoint anchors the "before" cumulative
        _swap();
        (uint16 idxBefore,,) = _coarseState();
        (, int48 coarseBefore,,) = hook.getCoarseObservation(id, idxBefore);

        vm.warp(T0 + INTERVAL + 3580); // honest tick-0 write right before the spike bounds its span
        _swap();
        _mockPoolTick(9000);
        vm.warp(T0 + 2 * INTERVAL - 10); // spike: 9000 booked over ~10s
        _swap();
        vm.warp(T0 + 2 * INTERVAL); // bucket-2 checkpoint, tick still 9000
        _swap();

        (uint16 idxAfter,,) = _coarseState();
        (, int48 coarseAfter,,) = hook.getCoarseObservation(id, idxAfter);
        uint256 coarseDelta = uint256(int256(coarseAfter - coarseBefore));

        // A boundary resample would have booked 9000 for the whole interval.
        assertLt(coarseDelta, uint256(9000) * INTERVAL / 50, "transient spike must not earn a full interval");
    }

    /// @notice Two manipulated observations must not leave the accepted tick elevated throughout
    ///         the following quiet hour. The elapsed-time slew recovers to the honest tick in four
    ///         seconds and integrates only the two ramps plus the four-second recovery tail.
    function test_ObserveLong_MultiBlockBurstDoesNotLeakIntoQuietHour() public {
        hook.increaseCardinalityNext(key, 16);
        hook.increaseCoarseCardinalityNext(key, 16);

        vm.warp(T0 + INTERVAL);
        _swap(); // honest coarse checkpoint at the beginning of the measured hour

        vm.warp(T0 + INTERVAL + 2);
        _swap(); // honest pre-attack observation

        _mockPoolTick(30_000);
        vm.warp(T0 + INTERVAL + 4);
        _swap(); // accepted tick ramps 0 -> 9,116 over two seconds
        vm.warp(T0 + INTERVAL + 6);
        _swap(); // accepted tick ramps 9,116 -> 18,232 over two seconds

        _mockPoolTick(0); // the second swap restores the real pool tick
        vm.warp(T0 + 2 * INTERVAL); // no writes during the remaining 3,594 quiet seconds

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = INTERVAL;
        secondsAgos[1] = 0;
        (int48[] memory projected,) = hook.observeLong(key, secondsAgos);

        // Areas: 9,116 (first ramp) + 27,348 (second ramp) + 36,464 (four-second recovery).
        int48 expectedBurstArea = 72_928;
        assertEq(projected[1] - projected[0], expectedBurstArea, "quiet time must not inherit the burst tick");
        assertEq(
            (projected[1] - projected[0]) / int48(uint48(INTERVAL)),
            int48(20),
            "the one-hour average is about 20 ticks, not the old 9,116-tick clamp lag"
        );

        _swap(); // persisting the projection must produce the same cumulative and checkpoint it
        (uint16 coarseIndex,,) = _coarseState();
        (, int48 checkpointed,,) = hook.getCoarseObservation(id, coarseIndex);
        assertEq(checkpointed - projected[0], expectedBurstArea, "view and write paths must integrate identically");
    }

    function test_ObserveLong_NegativeMultiBlockBurstDoesNotLeakIntoQuietHour() public {
        hook.increaseCardinalityNext(key, 16);
        hook.increaseCoarseCardinalityNext(key, 16);

        vm.warp(T0 + INTERVAL);
        _swap();
        vm.warp(T0 + INTERVAL + 2);
        _swap();

        _mockPoolTick(-30_000);
        vm.warp(T0 + INTERVAL + 4);
        _swap();
        vm.warp(T0 + INTERVAL + 6);
        _swap();

        _mockPoolTick(0);
        vm.warp(T0 + 2 * INTERVAL);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = INTERVAL;
        secondsAgos[1] = 0;
        (int48[] memory projected,) = hook.observeLong(key, secondsAgos);
        assertEq(projected[1] - projected[0], int48(-72_928), "negative bursts must recover symmetrically");
    }

    /// @notice Coarse cardinality catches up to cardinalityNext as the ring fills, then wraps.
    function test_CoarseRing_GrowsCardinalityAsItFills() public {
        hook.increaseCoarseCardinalityNext(key, 4);
        for (uint256 i = 1; i <= 5; i++) {
            vm.warp(T0 + i * INTERVAL);
            _swap();
        }
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = _coarseState();
        assertEq(cardinalityNext, 4);
        assertEq(cardinality, 4, "cardinality reaches cardinalityNext once the ring fills");
        assertEq(index, 1, "ring wrapped after 5 writes into 4 slots");
    }

    /// @notice `observeLong`'s now-endpoint reads the per-block ring, so a live-tick move within an
    ///         already-checkpointed bucket cannot inflate it: the swap wrote the honest pre-swap tick
    ///         at `now`, giving zero extrapolation delta.
    function test_ObserveLong_NowEndpointNotManipulableWithinBucket() public {
        hook.increaseCardinalityNext(key, 16);
        hook.increaseCoarseCardinalityNext(key, 16);

        _mockPoolTick(0);
        vm.warp(T0 + INTERVAL); // coarse checkpoint at the bucket start
        _swap();

        vm.warp(T0 + 2 * INTERVAL - 10); // late in the same bucket: per-block write, no coarse write
        _swap();

        _mockPoolTick(9000); // attacker moves the live tick, then reads in the same block
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int48[] memory cum,) = hook.observeLong(key, secondsAgos);

        (uint16 fineIndex,,) = hook.oracleStates(id);
        (, int48 fineCum,,) = hook.getObservation(id, fineIndex);
        assertEq(
            cum[0], fineCum, "now-endpoint is the honest per-block cumulative, not a coarse live-tick extrapolation"
        );
        assertEq(cum[0], int48(0), "honest ticks were 0; the 9000 live spike contributes nothing");
    }

    /// @notice The exact newest coarse checkpoint remains readable after the fine ring has
    ///         overwritten its copy of that timestamp.
    function test_ObserveLong_ExactNewestCheckpointUsesCoarseRing() public {
        hook.increaseCardinalityNext(key, 2);
        hook.increaseCoarseCardinalityNext(key, 4);

        vm.warp(T0 + INTERVAL);
        _swap(); // writes the checkpoint into both rings
        for (uint256 i = 1; i <= 3; i++) {
            vm.warp(T0 + INTERVAL + i);
            _swap(); // wraps the two-slot fine ring without advancing the coarse ring
        }

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 3;
        (int48[] memory cum,) = hook.observeLong(key, secondsAgos);

        (uint16 coarseIndex,,) = _coarseState();
        (, int48 coarseCum,,) = hook.getCoarseObservation(id, coarseIndex);
        assertEq(cum[0], coarseCum, "exact checkpoint must come from the retained coarse observation");
    }

    /// @notice The cron grows the coarse ring one 300-slot chunk per tick; one chunk's cold SSTOREs
    ///         must fit under Base's 2^24 per-transaction gas cap.
    function test_Gas_CoarseGrowChunkFitsBaseTxCap() public {
        uint256 gasBefore = gasleft();
        hook.increaseCoarseCardinalityNext(key, 300);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 16_777_216, "one grow chunk must fit under Base's 2^24 per-tx cap");
    }
}
