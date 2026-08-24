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
