// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {UmiaTwapMilestoneCondition} from "../../src/periphery/UmiaTwapMilestoneCondition.sol";

import {MetaVesTFactory} from "@metavest/MetaVesTFactory.sol";
import {metavestController} from "@metavest/MetaVesTController.sol";
import {VestingAllocationFactory} from "@metavest/VestingAllocationFactory.sol";
import {TokenOptionFactory} from "@metavest/TokenOptionFactory.sol";
import {RestrictedTokenFactory} from "@metavest/RestrictedTokenFactory.sol";

/// @title MetaVesTTestBase
/// @notice Shared scaffolding for the MetaVesT suites that run against a real venture + migrated V4
///         pool: the TWAP-milestone condition, the MetaVesT controller/allocation factory stack, the
///         canonical full-window TWAP recompute, and the canonical spot swap. Lets the condition
///         (integration + e2e) and lifecycle suites share one copy of each.
abstract contract MetaVesTTestBase is DecisionMarketBase {
    uint32 constant TWAP_WINDOW = 30 minutes;

    UmiaTwapMilestoneCondition condition;
    address vestingFactory;

    /// @dev Deploys the TWAP-milestone condition once. Idempotent so suites that pull in the full
    ///      controller stack and suites that only need the condition can both call it safely.
    function _deployCondition() internal {
        if (address(condition) == address(0)) condition = new UmiaTwapMilestoneCondition(TWAP_WINDOW);
    }

    /// @dev Deploys the MetaVesT factory + allocation factories, wires a controller with `authority`,
    ///      stores the vesting factory (for CREATE-nonce address prediction), and deploys the shared
    ///      condition. Runs under whatever prank context the caller has set.
    function _deployMetaVestStack(address authority) internal returns (metavestController controller) {
        MetaVesTFactory factory = new MetaVesTFactory();
        vestingFactory = address(new VestingAllocationFactory());
        controller = metavestController(
            factory.deployMetavestAndController(
                authority,
                address(0),
                vestingFactory,
                address(new TokenOptionFactory()),
                address(new RestrictedTokenFactory())
            )
        );
        _deployCondition();
    }

    /// @dev Independently recomputes the condition's expected full-window TWAP for `venture` so tests
    ///      can set thresholds right at the boundary. Mirrors `UmiaTwapMilestoneCondition._getTwapPriceX96`.
    function _twapPriceX96(address venture) internal view returns (uint160) {
        address token = IVenture(venture).token();
        IUmiaHook hook = IUmiaLBP(IVenture(venture).lbp()).umiaHook();
        PoolKey memory key = ISpotLiquidityVault(hub.ventureLiquidityVault(venture)).getPoolKey();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        // TWAP_WINDOW (30 min) is below 2 * COARSE_INTERVAL, so the condition reads the per-block
        // ring; this mirror must match. See UmiaTwapMilestoneCondition._getTwapPriceX96.
        (int48[] memory tickCumulatives,) = hook.observe(key, secondsAgos);
        int48 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int48 windowInt = int48(uint48(TWAP_WINDOW));
        int24 twapTick = int24(tickDelta / windowInt);
        if (tickDelta < 0 && (tickDelta % windowInt != 0)) twapTick--;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        if (!tokenIsCurrency0) {
            priceX96 = priceX96 == 0 ? type(uint160).max : FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, priceX96);
        }
        return priceX96 > type(uint160).max ? type(uint160).max : uint160(priceX96);
    }
}
