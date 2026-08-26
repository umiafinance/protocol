// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../interfaces/IUmiaMarketCore.sol";
import {IConditionalMarketOracle} from "../interfaces/IConditionalMarketOracle.sol";
import {IGovernanceExecutor} from "../interfaces/IGovernanceExecutor.sol";
import {IUmiaMarketStake} from "../interfaces/IUmiaMarketStake.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";
import {CPMM} from "./CPMM.sol";
import {MarketData, ProposalData, Pool, SettleAcct} from "./MarketCoreTypes.sol";
import {LedgerLib} from "./LedgerLib.sol";

/// @title MarketCreationLib
/// @notice Implements market creation for UmiaMarketCore: parameter validation, spot-liquidity
///         seeding, proposal setup, and oracle initialization.
/// @dev Executed via delegatecall from UmiaMarketCore, so it operates on the core's storage, which
///      is passed in as explicit references. The core performs the market-creation signature check,
///      nonce bump, and market/proposal ID allocation before invoking this library.
library MarketCreationLib {
    // ── Timing & proposal bounds ──
    uint256 internal constant TRADING_MAX_START_DELAY = 7 days;
    uint256 internal constant TRADING_MIN_DURATION = 1 hours;
    uint256 internal constant TRADING_MAX_DURATION = 96 hours;
    uint256 internal constant TRADING_DEFAULT_DURATION = 3 days;
    uint256 internal constant MIN_PROPOSALS = 1;
    uint256 internal constant MAX_PROPOSALS = 5;
    uint256 internal constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%
    uint256 internal constant MAX_BPS = 10_000;
    uint16 internal constant BOOTSTRAP_PULL_BPS = 5000; // 50% of vault liquidity per market

    /// @notice Create a market + its proposals for `params`. `marketId` is pre-allocated by the core
    ///         and `proposalCounterStart` is the core's current proposal counter.
    /// @dev Emits MarketCreated / LiquidityAdded (delegatecall ⇒ emitter is the core).
    /// @return proposalIds The created proposal ids ([0] == no-op).
    /// @return proposalCounterEnd The proposal counter after all proposals were created.
    function create(
        IUmiaHub hub,
        IUmiaMarketCore.CreateMarketParams calldata params,
        address creator,
        uint256 marketId,
        uint256 proposalCounterStart,
        // ── storage refs ──
        mapping(uint256 => MarketData) storage markets,
        mapping(uint256 => ProposalData) storage proposals,
        mapping(uint256 => Pool) storage pools,
        mapping(uint256 => SettleAcct) storage settle,
        mapping(uint256 => uint256) storage proposalToMarket,
        mapping(uint256 => uint256) storage activeMarketByVenture,
        // ledger refs — seed reserves are backed by virtual tokens minted to the core
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply
    ) external returns (uint256[] memory proposalIds, uint256 proposalCounterEnd) {
        IUmiaHub.VentureInfo memory ventureInfo = hub.ventureById(params.ventureId);
        if (ventureInfo.venture == address(0)) revert IUmiaMarketCore.VentureNotFound();

        if (params.proposals.length < MIN_PROPOSALS) revert IUmiaMarketCore.NotEnoughProposals();
        if (params.proposals.length > MAX_PROPOSALS) revert IUmiaMarketCore.TooManyProposals();
        if (params.startTimestamp > block.timestamp + TRADING_MAX_START_DELAY) {
            revert IUmiaMarketCore.StartTimeTooFarInFuture();
        }

        uint256 duration = params.duration == 0 ? TRADING_DEFAULT_DURATION : params.duration;
        if (duration < TRADING_MIN_DURATION || duration > TRADING_MAX_DURATION) {
            revert IUmiaMarketCore.InvalidDuration();
        }

        uint256 tradingStart = Math.max(params.startTimestamp, block.timestamp);
        uint256 tradingEnd = tradingStart + duration;

        // One active (unsettled) market per venture at a time.
        {
            uint256 activeId = activeMarketByVenture[params.ventureId];
            if (activeId != 0 && !markets[activeId].settled) revert IUmiaMarketCore.VentureMarketAlreadyActive();
        }
        activeMarketByVenture[params.ventureId] = marketId;

        // Pull 50% of the venture's spot V4 LP and escrow the amounts to seed the conditional pools.
        (uint256 ventureRemoved, uint256 moneyRemoved) = _pullSeedLiquidity(hub, ventureInfo.venture, marketId, settle);

        // Resolve + validate the governance executor before creating any proposals.
        address executor = hub.governanceExecutor(ventureInfo.venture);
        if (executor == address(0) || executor.code.length == 0) revert IUmiaMarketCore.GovernanceExecutorNotSet();

        // No-op proposal ([0]) + one proposal per params entry; seeds each pool's CPMM + baseline shares.
        (proposalIds, proposalCounterEnd) = _createProposals(
            params,
            marketId,
            ventureRemoved,
            moneyRemoved,
            executor,
            proposalCounterStart,
            proposals,
            pools,
            proposalToMarket,
            balanceOf,
            totalSupply
        );

        // Read the threshold once and reuse it for both the oracle initialization and the settlement
        // snapshot, so the oracle and the winner test can never see different values.
        uint16 winningThresholdBps = hub.winningMarketThresholdBps();
        _initOracles(hub, proposalIds, tradingStart, tradingEnd, winningThresholdBps, pools);

        markets[marketId] = MarketData({
            id: marketId,
            ventureId: params.ventureId,
            tradingStart: uint64(tradingStart),
            tradingEnd: uint64(tradingEnd),
            winningThresholdBps: uint32(winningThresholdBps), // snapshotted at creation
            executionDelay: hub.decisionMarketExecutionDelay(), // snapshotted at creation
            swapFeeBps: hub.decisionSwapFeeBps(), // snapshotted at creation
            protocolCutBps: hub.decisionProtocolFeeCutBps(), // snapshotted at creation
            settled: false,
            executed: false,
            proposalIds: proposalIds
        });

        // Lock the market-creation stake if the Hub configures one.
        address marketStake = hub.umiaMarketStake();
        if (marketStake != address(0)) {
            IUmiaMarketStake(marketStake).verifyAndLockStake(params.ventureId, creator, tradingEnd, marketId);
        }

        emit IUmiaMarketCore.MarketCreated(
            marketId, params.ventureId, params.title, block.timestamp, tradingStart, tradingEnd, proposalIds
        );

        // Emit per-proposal seed liquidity after MarketCreated so log order matches the
        // indexer's entity lifecycle (proposal then liquidity).
        for (uint256 i = 0; i < proposalIds.length; i++) {
            emit IUmiaMarketCore.LiquidityAdded(proposalIds[i], ventureRemoved, moneyRemoved);
        }
    }

    /// @notice Remove 50% of the venture's seed spot LP, escrow the amounts, and record settlement info.
    /// @return ventureRemoved Amount of venture token removed (CPMM reserve0 order).
    /// @return moneyRemoved Amount of money token removed (CPMM reserve1 order).
    function _pullSeedLiquidity(
        IUmiaHub hub,
        address venture,
        uint256 marketId,
        mapping(uint256 => SettleAcct) storage settle
    ) private returns (uint256 ventureRemoved, uint256 moneyRemoved) {
        address vault = hub.ventureLiquidityVault(venture);
        if (vault == address(0)) revert IUmiaMarketCore.LPPositionNotRegistered();

        // The vault removes BOOTSTRAP_PULL_BPS of its full-range liquidity, runs its own spot-vs-TWAP
        // sandwich guard, records the per-market deployment, and transfers the (venture, money)
        // proceeds to this contract (msg.sender = UmiaMarketCore).
        uint128 liquidityPulled;
        (ventureRemoved, moneyRemoved, liquidityPulled) =
            ISpotLiquidityVault(vault).pullForDecisionMarket(marketId, BOOTSTRAP_PULL_BPS);

        // A one-sided seed (spot price at a range edge) would seed a zero reserve, producing a
        // permanently untradeable market that still blocks the venture until it is settled.
        if (ventureRemoved == 0 || moneyRemoved == 0) revert IUmiaMarketCore.EmptySeedLiquidity();

        SettleAcct storage acct = settle[marketId];
        acct.ventureRemoved = ventureRemoved;
        acct.moneyRemoved = moneyRemoved;
        acct.liquidityRemoved = liquidityPulled;
        // Fold the seed escrow into the market's real balance so each token has a single real-backing
        // quantity. `merge` then draws against the full backing (not just split escrow), so it cannot
        // be griefed into an underflow revert, and `_checkInvariant` can assert exact conservation.
        acct.realVentureBalance = ventureRemoved;
        acct.realMoneyBalance = moneyRemoved;
    }

    /// @notice Create the no-op proposal + one proposal per param, seeding each pool and mapping it
    ///         back to the market. Validates non-empty execution payloads via the executor.
    function _createProposals(
        IUmiaMarketCore.CreateMarketParams calldata params,
        uint256 marketId,
        uint256 ventureRemoved,
        uint256 moneyRemoved,
        address executor,
        uint256 proposalCounterStart,
        mapping(uint256 => ProposalData) storage proposals,
        mapping(uint256 => Pool) storage pools,
        mapping(uint256 => uint256) storage proposalToMarket,
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply
    ) private returns (uint256[] memory proposalIds, uint256 counter) {
        counter = proposalCounterStart;
        proposalIds = new uint256[](params.proposals.length + 1);

        // No-op proposal is always [0].
        counter++;
        proposalIds[0] = counter;
        _seedProposal(
            proposals, pools, balanceOf, totalSupply, counter, "no-op", true, ventureRemoved, moneyRemoved, ""
        );
        proposalToMarket[counter] = marketId;

        for (uint256 i = 0; i < params.proposals.length; i++) {
            bytes calldata executionPayload = params.proposals[i].executionPayload;
            if (executionPayload.length > 0) {
                _validateProposalPayload(executor, executionPayload);
            }

            counter++;
            proposalIds[i + 1] = counter;
            _seedProposal(
                proposals,
                pools,
                balanceOf,
                totalSupply,
                counter,
                params.proposals[i].title,
                false,
                ventureRemoved,
                moneyRemoved,
                executionPayload
            );
            proposalToMarket[counter] = marketId;
        }
    }

    /// @notice Seed a single proposal's CPMM reserves and protocol baseline shares, mint the backing
    ///         virtual tokens to the core, and store the proposal record.
    /// @dev The seed reserves are backed by virtual tokens minted to the core (address(this) under
    ///      delegatecall). Without this backing, swaps and settlement that move tokens out of the
    ///      core's balance would revert with InsufficientVirtualTokens.
    function _seedProposal(
        mapping(uint256 => ProposalData) storage proposals,
        mapping(uint256 => Pool) storage pools,
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply,
        uint256 id,
        string memory title,
        bool isNoOp,
        uint256 ventureAmount,
        uint256 moneyAmount,
        bytes memory executionPayload
    ) private {
        uint256 vVentureId = id * 2;
        uint256 vMoneyId = id * 2 + 1;

        // Mint the seed reserves to the core (backs pools[id].cpmm).
        LedgerLib.mint(balanceOf, totalSupply, address(this), vVentureId, ventureAmount);
        LedgerLib.mint(balanceOf, totalSupply, address(this), vMoneyId, moneyAmount);

        Pool storage pool = pools[id];
        pool.cpmm = CPMM.State({reserve0: ventureAmount, reserve1: moneyAmount});
        pool.totalLiquidityShares = _initialLiquidityShares(ventureAmount, moneyAmount);

        proposals[id] = ProposalData({isNoOp: isNoOp, title: title, executionPayload: executionPayload});
    }

    /// @notice Initialize each proposal's oracle in one atomic call during market creation.
    function _initOracles(
        IUmiaHub hub,
        uint256[] memory proposalIds,
        uint256 tradingStart,
        uint256 tradingEnd,
        uint16 winningThresholdBps,
        mapping(uint256 => Pool) storage pools
    ) private {
        IConditionalMarketOracle oracle = IConditionalMarketOracle(hub.conditionalMarketOracle());
        for (uint256 i = 0; i < proposalIds.length; i++) {
            uint256 pid = proposalIds[i];
            CPMM.State storage s = pools[pid].cpmm;
            oracle.initialize(
                pid, s.reserve0, s.reserve1, uint32(tradingStart), uint32(tradingEnd), winningThresholdBps
            );
        }
    }

    /// @notice Validate a proposal execution payload against the venture's configured executor.
    /// @dev Uses a staticcall so validation cannot mutate executor state. If the executor reverts,
    ///      bubble the original revert data back to the market creator.
    function _validateProposalPayload(address executor, bytes calldata executionPayload) private view {
        (bool success, bytes memory returndata) =
            executor.staticcall(abi.encodeCall(IGovernanceExecutor.validatePayload, (executionPayload)));
        if (success) return;
        if (returndata.length == 0) revert();

        assembly ("memory-safe") {
            revert(add(returndata, 0x20), mload(returndata))
        }
    }

    /// @notice Baseline liquidity shares seeded to the protocol (sqrt of the reserve product).
    /// @dev Guards against first-depositor / share-inflation attacks.
    function _initialLiquidityShares(uint256 amount0, uint256 amount1) private pure returns (uint256) {
        if (amount0 == 0 || amount1 == 0) return 0;
        return Math.sqrt(amount0 * amount1);
    }
}
