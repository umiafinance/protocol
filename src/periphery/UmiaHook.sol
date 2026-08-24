// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IUmiaHook} from "../interfaces/IUmiaHook.sol";
import {SpotMarketOracle} from "../libraries/SpotMarketOracle.sol";

/// @notice Minimal view-only interface for the UmiaLBPFactory's `isLBP` mapping.
/// @dev The hook does not import `IUmiaLBPFactory` to avoid a circular dependency.
interface IUmiaLBPFactoryView {
    function isLBP(address account) external view returns (bool);
}

/// @title UmiaHook
/// @notice Singleton Uniswap V4 hook serving every Umia LBP pool on a given chain.
/// @dev One canonical address per chain. Mined via CreateX.
///
///      The hook is oracle-only: it maintains a spot-market TWAP oracle and enforces that
///      liquidity is added/removed exclusively by the pool's registered `operator` (the
///      venture's `SpotLiquidityVault`). It takes NO swap-time fee delta — swap fees accrue
///      V4-natively inside the operator's position — so the pool presents a vanilla swap
///      surface to external routers.
///
///      Per-pool configuration (venture, operator, oracle observations) lives in mappings
///      keyed by `PoolId`. Registration is one-shot per pool and gated to addresses produced
///      by the canonical `UmiaLBPFactory` via its `isLBP` map.
///
///      The hook deliberately does NOT inherit `BaseHook` from `v4-periphery`. `BaseHook`
///      takes `IPoolManager` in its constructor, which would bake a chain-specific address
///      into the deployed init code and prevent the cross-chain canonical-address goal. The
///      small `BaseHook` surface (onlyPoolManager modifier, hook callback shape) is
///      reimplemented inline.
///
///      Deployment and `initialize` are separate transactions by construction.
contract UmiaHook is IHooks, IUmiaHook {
    using PoolIdLibrary for PoolKey;
    using SpotMarketOracle for SpotMarketOracle.Observation[65535];
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────

    /// @notice The EOA authorized to call `initialize`. Set at construction; identical across
    ///         every chain in the singleton-canonical-address setup so the same init code
    ///         hash hits the mined CreateX address everywhere.
    address public immutable INITIAL_OWNER;

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    /// @notice The Uniswap V4 PoolManager this hook is wired to. Set once via `initialize`.
    /// @dev Storage, not immutable, because the address may differ per chain.
    IPoolManager public poolManager;

    /// @notice The canonical UmiaLBPFactory whose deployments are eligible to call
    ///         `registerPool`. Set once via `initialize`.
    address public factory;

    /// @notice Per-pool configuration written exactly once at `registerPool`. Immutable after.
    mapping(PoolId => PoolConfig) public pools;

    /// @notice Ring-buffer index, cardinality, and cardinality-next for the spot-market oracle
    ///         attached to each pool.
    mapping(PoolId => ObservationState) public oracleStates;

    /// @notice Backing storage for `SpotMarketOracle`'s 65535-slot observation ring buffer.
    mapping(PoolId => SpotMarketOracle.Observation[65535]) internal observations;

    // ─────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────

    /// @dev Restrict to V4 PoolManager-routed callbacks.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @param _initialOwner The EOA that will later call `initialize`.
    constructor(address _initialOwner) {
        if (_initialOwner == address(0)) revert InvalidInitialOwner();
        INITIAL_OWNER = _initialOwner;
    }

    // ─────────────────────────────────────────────────────────
    // Initialization
    // ─────────────────────────────────────────────────────────

    /// @notice One-shot wiring of the factory and pool manager. Callable only by
    ///         `INITIAL_OWNER`. Both addresses are non-zero and immutable thereafter.
    /// @param _factory     Canonical UmiaLBPFactory for this chain.
    /// @param _poolManager Uniswap V4 PoolManager for this chain.
    function initialize(address _factory, IPoolManager _poolManager) external {
        if (msg.sender != INITIAL_OWNER) revert NotInitialOwner();
        if (factory != address(0)) revert FactoryAlreadySet();
        if (_factory == address(0)) revert InvalidFactory();
        if (address(_poolManager) == address(0)) revert InvalidPoolManager();
        factory = _factory;
        poolManager = _poolManager;
        emit Initialized(_factory, address(_poolManager));
    }

    // ─────────────────────────────────────────────────────────
    // Pool Registration
    // ─────────────────────────────────────────────────────────

    /// @notice Register a new pool with the hook before its `poolManager.initialize` call.
    /// @dev Caller must be a factory-deployed UmiaLBP (`factory.isLBP(msg.sender) == true`).
    ///      Reverts on double-registration of the same PoolId or invalid config. The
    ///      `launcher` field of the stored config is forced to `msg.sender` so callers
    ///      cannot impersonate one another regardless of what they put in `cfg`.
    /// @param key The PoolKey of the to-be-initialized pool. Its `hooks` slot must be this contract.
    /// @param cfg Per-pool config: venture recipient + liquidity operator. `launcher` is ignored.
    function registerPool(PoolKey calldata key, PoolConfig calldata cfg) external {
        if (!IUmiaLBPFactoryView(factory).isLBP(msg.sender)) {
            revert NotFactoryDeployedLBP(msg.sender);
        }
        // V4 hashes `hooks` into the PoolId, so a key pointing at a different hook would
        // produce a PoolId that never routes back here. Reject up-front to avoid orphaned
        // registry entries that confuse indexers.
        if (address(key.hooks) != address(this)) {
            revert InvalidHooksAddress(address(key.hooks), address(this));
        }
        PoolId id = key.toId();
        if (pools[id].launcher != address(0)) revert PoolAlreadyRegistered(id);
        if (cfg.venture == address(0)) revert InvalidVentureAddress();
        if (cfg.operator == address(0)) revert InvalidOperator();

        pools[id] = PoolConfig({launcher: msg.sender, venture: cfg.venture, operator: cfg.operator});
        emit PoolRegistered(id, cfg.operator, pools[id]);
    }

    // ─────────────────────────────────────────────────────────
    // V4 Hook Permissions
    // ─────────────────────────────────────────────────────────

    /// @notice Permission set encoded in the lower 14 bits of the hook's CREATE2 address.
    /// @dev Active: beforeInitialize, afterInitialize, beforeAddLiquidity, beforeRemoveLiquidity,
    ///      beforeSwap. No swap-time return delta (the pool takes no hook fee). Permission mask
    ///      is 0x3A80; mining is done off-chain via `script/MineUmiaHookSalt.s.sol`.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────
    // V4 Hook Callbacks: Initialization
    // ─────────────────────────────────────────────────────────

    /// @notice Gate pool initialization to the LBP that registered the pool.
    /// @dev Mirrors `SelfInitializerHook` semantics but sources the authorized address from
    ///      the per-pool `pools[id].launcher` registry instead of `address(this)`.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        address launcher = pools[id].launcher;
        if (sender != launcher) revert UnauthorizedLauncher(sender, launcher);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Seed the spot-market oracle on first initialization.
    /// @dev Idempotent: a second initialize with the same PoolId is a no-op because
    ///      `oracleStates[id].cardinality` only equals zero before the first seed.
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        if (oracleStates[id].cardinality == 0) {
            (oracleStates[id].cardinality, oracleStates[id].cardinalityNext) =
                observations[id].initialize(uint32(block.timestamp), tick);
        }
        return IHooks.afterInitialize.selector;
    }

    // ─────────────────────────────────────────────────────────
    // V4 Hook Callbacks: Liquidity
    // ─────────────────────────────────────────────────────────

    /// @notice Enforce operator-only, full-range positions and record a pre-event observation.
    /// @dev Only the registered `operator` (the venture's SpotLiquidityVault) may add liquidity,
    ///      so the protocol controls 100% of canonical liquidity. Concentrated liquidity would
    ///      leave tick ranges with zero liquidity that an attacker could move cheaply,
    ///      undermining the TWAP oracle, so only full-range is allowed.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        address operator = pools[id].operator;
        if (sender != operator) revert UnauthorizedLiquidityOperator(sender, operator);
        if (
            params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
        ) {
            revert OnlyFullRangePositions();
        }
        _writeObservation(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice No-op. Declared because the IHooks interface requires it; permission flag is off.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Enforce operator-only removals and record a pre-event observation.
    /// @dev Only the registered `operator` may remove liquidity. Records an observation before
    ///      the liquidity change so the oracle reflects pre-removal pool state.
    function beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        address operator = pools[id].operator;
        if (sender != operator) revert UnauthorizedLiquidityOperator(sender, operator);
        _writeObservation(key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice No-op. Declared because the IHooks interface requires it; permission flag is off.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ─────────────────────────────────────────────────────────
    // V4 Hook Callbacks: Swap
    // ─────────────────────────────────────────────────────────

    /// @notice Record a pre-swap oracle observation. Returns a zero delta so the swap
    ///         price is determined entirely by pool state.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _writeObservation(key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice No-op. Declared because the IHooks interface requires it; permission flag is off.
    /// @dev The hook takes no swap fee: swap fees accrue V4-natively inside the operator's
    ///      position, keeping the pool a vanilla swap surface for external routers.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    // ─────────────────────────────────────────────────────────
    // V4 Hook Callbacks: Donate
    // ─────────────────────────────────────────────────────────

    /// @notice No-op. Declared because the IHooks interface requires it; permission flag is off.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /// @notice No-op. Declared because the IHooks interface requires it; permission flag is off.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ─────────────────────────────────────────────────────────
    // Oracle
    // ─────────────────────────────────────────────────────────

    /// @notice Read TWAP-style observations from the pool's oracle for the given lookbacks.
    /// @param key         The pool to read from.
    /// @param secondsAgos Lookbacks in seconds, relative to the current block timestamp.
    /// @return tickCumulatives                     Tick-time integrals at each lookback.
    /// @return secondsPerLiquidityCumulativeX128s  Seconds-per-liquidity integrals at each lookback.
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId id = key.toId();
        ObservationState memory state = oracleStates[id];
        (, int24 tick,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        return
            observations[id].observe(
                uint32(block.timestamp), secondsAgos, tick, state.index, liquidity, state.cardinality
            );
    }

    /// @notice Direct read of a single observation slot. Intended for tests, indexers, and
    ///         diagnostics that need to introspect the ring buffer.
    /// @param id    PoolId.
    /// @param index Slot in the ring buffer.
    function getObservation(PoolId id, uint16 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int48 tickCumulative,
            uint144 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        SpotMarketOracle.Observation memory obs = observations[id][index];
        return (obs.blockTimestamp, obs.tickCumulative, obs.secondsPerLiquidityCumulativeX128, obs.initialized);
    }

    /// @notice Permissionless grow of the observation ring buffer's effective capacity.
    /// @dev No-op if `cardinalityNext` is already at or above the requested value.
    /// @param key             The pool whose buffer should grow.
    /// @param cardinalityNext Requested new capacity.
    /// @return cardinalityNextOld Previous capacity.
    /// @return cardinalityNextNew Updated capacity (may equal the previous one).
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId id = key.toId();
        ObservationState storage state = oracleStates[id];
        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }

    // ─────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────

    /// @dev Write an oracle observation using the current pool state read via `StateLibrary`.
    ///      Called from `beforeAddLiquidity`, `beforeRemoveLiquidity`, and `beforeSwap`.
    function _writeObservation(PoolKey calldata key) internal {
        PoolId id = key.toId();
        ObservationState storage state = oracleStates[id];
        (, int24 tick,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        (state.index, state.cardinality) = observations[id].write(
            state.index, uint32(block.timestamp), tick, liquidity, state.cardinality, state.cardinalityNext
        );
    }
}
