// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {IUmiaLBP} from "../interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../interfaces/IUmiaHook.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {IVentureVestingAuthority} from "../interfaces/IVentureVestingAuthority.sol";
import {TwapMath} from "../libraries/TwapMath.sol";
import {IUmiaTwapMilestoneCondition} from "../interfaces/IUmiaTwapMilestoneCondition.sol";

/// @notice Minimal read surface of a MetaVesT `BaseAllocation`, declared locally so this singleton
///         carries no AGPL-licensed import. `Allocation` mirrors the struct returned by
///         `getMetavestDetails()` at the pinned MetaVesT submodule commit (`lib/metavest`); an
///         upstream bump that reorders its fields must update this layout. `controller` is the
///         allocation's immutable MetaVesT controller.
interface IMetaVesTAllocation {
    struct Allocation {
        uint256 tokenStreamTotal;
        uint128 vestingCliffCredit;
        uint128 unlockingCliffCredit;
        uint160 vestingRate;
        uint48 vestingStartTime;
        uint160 unlockRate;
        uint48 unlockStartTime;
        address tokenContract;
    }

    function getMetavestDetails() external view returns (Allocation memory);
    function controller() external view returns (address);
}

/// @notice Minimal MetaVesT controller surface: its current `authority` is the venture's
///         `VentureVestingAuthority`, which holds the allocation's price ladder.
interface IMetaVesTController {
    function authority() external view returns (address);
}

/// @title UmiaTwapMilestoneCondition
/// @notice Shared singleton MetaVesT condition: a milestone confirms only once the venture's
///         spot-pool TWAP reaches the milestone's price threshold AND the milestone's optional cliff
///         timestamp has elapsed (a cliff of 0 means price-only). One instance is deployed per
///         chain. It holds no per-allocation state and no auth: threshold and cliff live on the
///         venture's `VentureVestingAuthority` (written atomically with the grant), and this contract
///         resolves them at check time via `allocation → controller → authority`, then compares the
///         venture's full-window TWAP. All TWAP reads are fail-closed — they revert before the
///         venture's pool exists or before the oracle can serve the full window.
contract UmiaTwapMilestoneCondition is IUmiaTwapMilestoneCondition {
    uint32 public immutable TWAP_WINDOW;

    constructor(uint32 twapWindow) {
        if (twapWindow == 0) revert InvalidTwapWindow();
        TWAP_WINDOW = twapWindow;
    }

    /// @inheritdoc IUmiaTwapMilestoneCondition
    function checkCondition(address allocation, bytes4, bytes calldata data) external view returns (bool) {
        uint256 idx = abi.decode(data, (uint256));
        // Resolve the threshold first — registry/range/clearing-price checks live on the adapter, so
        // an unregistered or not-yet-cleared milestone reverts with that error rather than the
        // fail-closed TWAP error.
        address authority = _authorityOf(allocation);
        uint160 threshold = IVentureVestingAuthority(authority).effectiveThreshold(allocation, idx);
        // An unelapsed cliff gates the milestone regardless of price, and skips the TWAP read so a
        // cliffed milestone answers false (not a fail-closed revert) even before the pool exists.
        uint48 cliff = IVentureVestingAuthority(authority).effectiveCliff(allocation, idx);
        if (cliff != 0 && block.timestamp < cliff) return false;
        return _getTwapPriceX96(_tokenOf(allocation)) >= threshold;
    }

    // ─────────────────────────────────────────────────────────
    // Internal functions
    // ─────────────────────────────────────────────────────────

    /// @dev The allocation's price-ladder registry = its controller's current authority. The adapter
    ///      claims authority once at genesis and never relinquishes it for the venture's life, so this
    ///      always resolves to the `VentureVestingAuthority` holding the allocation's ladder.
    function _authorityOf(address allocation) internal view returns (address) {
        return IMetaVesTController(IMetaVesTAllocation(allocation).controller()).authority();
    }

    function _tokenOf(address allocation) internal view returns (address) {
        return IMetaVesTAllocation(allocation).getMetavestDetails().tokenContract;
    }

    /// @notice Current normalized full-window TWAP (moneyToken per ventureToken, Q96) for the
    ///         venture owning `token`. Reverts `NoLpToken` before migration and `OracleNotReady`
    ///         when the oracle cannot serve the full window. Never degrades to a shorter window.
    function _getTwapPriceX96(address token) internal view returns (uint160) {
        address venture = Ownable(token).owner();

        address vault = IUmiaHub(IVenture(venture).HUB()).ventureLiquidityVault(venture);
        if (vault == address(0)) revert NoLpToken();

        ISpotLiquidityVault v = ISpotLiquidityVault(vault);
        IUmiaHook hook = IUmiaHook(v.hook());
        PoolKey memory key = v.getPoolKey();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        int48[] memory tickCumulatives =
            _readCumulatives(hook, key, secondsAgos, TWAP_WINDOW >= 2 * hook.COARSE_INTERVAL());

        int24 twapTick = TwapMath.averageTick(tickCumulatives[0], tickCumulatives[1], TWAP_WINDOW);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        if (!tokenIsCurrency0) {
            // A non-inverted price that floored to 0 has a reciprocal beyond every representable
            // threshold, so cap it instead of dividing by zero (mirrors the high-side cap below).
            priceX96 = priceX96 == 0 ? type(uint160).max : FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, priceX96);
        }

        // Thresholds are uint160; a price past that ceiling already clears every representable
        // threshold, so cap rather than silently truncating the high bits of the comparison.
        return priceX96 > type(uint160).max ? type(uint160).max : uint160(priceX96);
    }

    function _readCumulatives(IUmiaHook hook, PoolKey memory key, uint32[] memory secondsAgos, bool useLong)
        private
        view
        returns (int48[] memory tickCumulatives)
    {
        if (useLong) {
            try hook.observeLong(key, secondsAgos) returns (int48[] memory t, uint144[] memory) {
                return t;
            } catch {
                revert OracleNotReady();
            }
        }
        try hook.observe(key, secondsAgos) returns (int48[] memory t, uint144[] memory) {
            return t;
        } catch {
            revert OracleNotReady();
        }
    }
}
