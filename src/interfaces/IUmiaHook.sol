// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title IUmiaHook
/// @notice Public interface for the singleton `UmiaHook` Uniswap V4 hook.
/// @dev See `smart-contracts/src/periphery/UmiaHook.sol` for the implementation.
///
///      The hook is oracle-only: it records TWAP observations and enforces that the
///      pool's liquidity is managed exclusively by the registered `operator`
///      (the venture's `SpotLiquidityVault`). It takes NO swap-time fee delta, so the
///      pool presents a vanilla swap surface to external routers.
interface IUmiaHook {
    // ─────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────

    /// @notice Per-pool configuration written once at `registerPool` and immutable thereafter.
    /// @dev `launcher` is overwritten with `msg.sender` inside `registerPool`; callers cannot
    ///      spoof it via the calldata struct. `venture` is recorded for onchain transparency /
    ///      indexer reads. `operator` is the sole address allowed to add or remove liquidity on
    ///      the pool — the venture's `SpotLiquidityVault`.
    struct PoolConfig {
        address launcher;
        address venture;
        address operator;
    }

    /// @notice Spot-market oracle ring-buffer cursor for a given pool.
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    /// @notice `registerPool` caller is not a factory-deployed UmiaLBP.
    error NotFactoryDeployedLBP(address caller);
    /// @notice `registerPool` called twice for the same PoolId.
    error PoolAlreadyRegistered(PoolId id);
    /// @notice `beforeInitialize` sender does not match the registered launcher for the pool.
    error UnauthorizedLauncher(address caller, address expected);
    /// @notice `beforeAddLiquidity`/`beforeRemoveLiquidity` sender is not the registered operator.
    error UnauthorizedLiquidityOperator(address caller, address expected);
    /// @notice Callback received from an address other than the configured PoolManager.
    error OnlyPoolManager();
    /// @notice `beforeAddLiquidity` received non-full-range ticks; only full-range is allowed.
    error OnlyFullRangePositions();
    /// @notice `initialize` called more than once.
    error FactoryAlreadySet();
    /// @notice `initialize` caller is not `INITIAL_OWNER`.
    error NotInitialOwner();
    /// @notice `registerPool` config has zero venture address.
    error InvalidVentureAddress();
    /// @notice `registerPool` config has zero operator address.
    error InvalidOperator();
    /// @notice `initialize` received zero factory address.
    error InvalidFactory();
    /// @notice `initialize` received zero poolManager address.
    error InvalidPoolManager();
    /// @notice Constructor received zero initial owner address.
    error InvalidInitialOwner();
    /// @notice `registerPool` received a PoolKey whose `hooks` field is not this hook.
    error InvalidHooksAddress(address provided, address expected);

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    /// @notice Emitted once when the hook is wired to its factory and PoolManager.
    event Initialized(address factory, address poolManager);
    /// @notice Emitted when a new pool is registered with the hook.
    event PoolRegistered(PoolId indexed id, address indexed operator, PoolConfig config);

    // ─────────────────────────────────────────────────────────
    // External Functions
    // ─────────────────────────────────────────────────────────

    /// @notice One-shot initialization. Wires the canonical factory and per-chain PoolManager.
    function initialize(address factory, IPoolManager poolManager) external;

    /// @notice Register a new pool with the hook. Caller must be a factory-deployed UmiaLBP.
    function registerPool(PoolKey calldata key, PoolConfig calldata cfg) external;

    /// @notice Grow the oracle ring buffer's effective capacity. Permissionless.
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);

    // ─────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Per-pool configuration. Zero `launcher` means unregistered.
    function pools(PoolId id) external view returns (address launcher, address venture, address operator);

    /// @notice Per-pool oracle ring-buffer cursor.
    function oracleStates(PoolId id) external view returns (uint16 index, uint16 cardinality, uint16 cardinalityNext);

    /// @notice Read TWAP-style observations from the pool's oracle for the given lookbacks.
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Direct read of a single observation slot in the ring buffer.
    function getObservation(PoolId id, uint16 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int48 tickCumulative,
            uint144 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}
