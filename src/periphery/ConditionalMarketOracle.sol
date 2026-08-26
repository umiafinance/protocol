// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IConditionalMarketOracle} from "../interfaces/IConditionalMarketOracle.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";

/// @title ConditionalMarketOracle
/// @notice Per-proposal time-weighted average of the money-per-venture price (Q112.112).
/// @dev Each observation is clamped to within 2.5x / 0.4x of the previous one per update, bounding
///      single-update manipulation impact on the TWAP accumulator. The oracle is registry-swappable:
///      the Hub can point the core at a replacement implementation of the same interface (e.g. one
///      whose clamp is calibrated to `winningThresholdBps`) without touching the core.
contract ConditionalMarketOracle is IConditionalMarketOracle {
    // ─────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────

    struct OracleState {
        uint256 price0CumulativeLast; // ∫ observation dt, scored from tradingStart
        uint256 lastPrice0X112; // last accepted observation
        uint32 tradingStart;
        uint32 tradingEnd;
        uint32 lastTimestamp; // last recorded time; anchored at tradingStart on init
        bool initialized;
    }

    // ─────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────

    uint256 internal constant Q112 = 2 ** 112;

    /// @dev Every accepted observation is saturated to this price, so `maxPrice` products stay inside
    ///      uint256 under any reserve ratio and a stored observation can never brick a later update or
    ///      settlement read. It sits far above any real money-per-venture price.
    uint256 internal constant MAX_PRICE_X112 = 1 << 208;

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    IUmiaHub public immutable HUB;

    mapping(uint256 proposalId => OracleState) public oracleStates;

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error OnlyMarketCore();
    error AlreadyInitialized();
    error ProposalNotInitialized();
    error InvalidReserves();
    error InvalidTradingWindow();
    error InvalidWinningThreshold();
    error TradingNotStarted();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event OracleInitialized(
        uint256 indexed proposalId,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint256 initialPriceX112,
        uint16 winningThresholdBps
    );

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    constructor(address _hub) {
        HUB = IUmiaHub(_hub);
    }

    // ─────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────

    modifier onlyMarketCore() {
        if (msg.sender != HUB.umiaMarketCore()) revert OnlyMarketCore();
        _;
    }

    // ─────────────────────────────────────────────────────────
    // External Functions
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IConditionalMarketOracle
    function initialize(
        uint256 proposalId,
        uint256 reserve0,
        uint256 reserve1,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint16 winningThresholdBps
    ) external onlyMarketCore {
        OracleState storage oracle = oracleStates[proposalId];
        if (oracle.initialized) revert AlreadyInitialized();
        if (reserve0 == 0 || reserve1 == 0) revert InvalidReserves();
        if (tradingEnd <= tradingStart) revert InvalidTradingWindow();
        // Unused by this implementation's fixed clamp; validated so the creation path keeps the same
        // revert surface when a threshold-calibrated oracle is swapped in.
        if (winningThresholdBps == 0 || winningThresholdBps > 10_000) revert InvalidWinningThreshold();

        uint256 seedPrice = (reserve1 * Q112) / reserve0;
        if (seedPrice > MAX_PRICE_X112) seedPrice = MAX_PRICE_X112;
        if (seedPrice == 0) seedPrice = 1; // a zero anchor would disable the ratio clamp (0 * 2.5 == 0)

        oracle.lastPrice0X112 = seedPrice;
        oracle.tradingStart = tradingStart;
        oracle.tradingEnd = tradingEnd;
        // Anchor scoring at tradingStart: the cumulative stays 0 until the first post-start update,
        // and no price-changing operation can occur before then (swaps are gated on tradingStart).
        oracle.lastTimestamp = tradingStart;
        oracle.initialized = true;

        emit OracleInitialized(proposalId, tradingStart, tradingEnd, seedPrice, winningThresholdBps);
    }

    /// @inheritdoc IConditionalMarketOracle
    function update(uint256 proposalId, uint256 reserve0, uint256 reserve1) external onlyMarketCore {
        OracleState storage oracle = oracleStates[proposalId];
        if (!oracle.initialized) return;

        uint32 effectiveTs = _effectiveTimestamp(oracle.tradingEnd);
        // Nothing to record before tradingStart, within the same second, or after the end freeze.
        if (effectiveTs <= oracle.lastTimestamp) return;

        // A degenerate pool has no price to record. Leave `lastTimestamp` untouched so the interval is
        // credited by the next well-formed update rather than silently scored as zero.
        if (reserve0 == 0 || reserve1 == 0) return;

        uint32 timeElapsed = effectiveTs - oracle.lastTimestamp;
        uint256 rawPrice0 = (reserve1 * Q112) / reserve0;
        uint256 price0 = _clampPrice(rawPrice0, oracle.lastPrice0X112);
        unchecked {
            oracle.price0CumulativeLast += price0 * timeElapsed;
        }
        oracle.lastPrice0X112 = price0;
        oracle.lastTimestamp = effectiveTs;
    }

    /// @inheritdoc IConditionalMarketOracle
    function calculateTWAP(uint256 proposalId, uint256 reserve0, uint256 reserve1)
        external
        view
        returns (uint256 twapX112)
    {
        OracleState memory oracle = oracleStates[proposalId];
        if (!oracle.initialized) revert ProposalNotInitialized();
        if (block.timestamp < oracle.tradingStart) revert TradingNotStarted();

        uint32 effectiveTs = _effectiveTimestamp(oracle.tradingEnd);
        uint256 cumulative = oracle.price0CumulativeLast;

        // effectiveTs >= lastTimestamp always: lastTimestamp was set to an effective timestamp <= its
        // block time, and block time only advances.
        uint32 timeElapsed = effectiveTs - oracle.lastTimestamp;
        if (timeElapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            uint256 rawPrice0 = (reserve1 * Q112) / reserve0;
            uint256 price0 = _clampPrice(rawPrice0, oracle.lastPrice0X112);
            unchecked {
                cumulative += price0 * timeElapsed;
            }
        }

        uint32 scored = effectiveTs - oracle.tradingStart;
        // Queried in the first second of the window there is nothing to average yet. Return the
        // anchored observation rather than raw spot, which is unclamped and same-block manipulable.
        if (scored == 0) return oracle.lastPrice0X112;
        twapX112 = cumulative / scored;
    }

    // ─────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────

    /// @dev Current time capped at the trading-end freeze.
    function _effectiveTimestamp(uint32 tradingEnd) internal view returns (uint32) {
        uint32 ts = uint32(block.timestamp);
        return ts > tradingEnd ? tradingEnd : ts;
    }

    /// @dev Clamps a price to at most 2.5x and at least 0.4x of the last observation, saturated to
    ///      `MAX_PRICE_X112`. `minPrice` rounds up so the result is never zero — a zero observation
    ///      would disable the ratio clamp. Callers pass `lastPrice >= 1` (held by `initialize`).
    function _clampPrice(uint256 rawPrice, uint256 lastPrice) internal pure returns (uint256) {
        if (rawPrice > MAX_PRICE_X112) rawPrice = MAX_PRICE_X112;
        uint256 maxPrice = (lastPrice * 5) / 2;
        uint256 minPrice = (lastPrice * 2 + 4) / 5;
        if (rawPrice > maxPrice) return maxPrice;
        if (rawPrice < minPrice) return minPrice;
        return rawPrice;
    }
}
