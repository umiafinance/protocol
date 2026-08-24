// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ISpotLiquidityVault
/// @notice Interface for the protocol-managed spot LP vault per venture.
/// @dev The vault is the sole liquidity operator for the canonical Uniswap v4 pool: it
///      custodies a single full-range position and exposes per-market pull/return APIs to
///      UmiaMarketCore. LPs deposit venture + money tokens and receive vault shares.
interface ISpotLiquidityVault {
    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error CallerNotMarketCore();
    error CallerNotLBP();
    error CallerNotPoolManager();
    error InvalidPullBps();
    error InvalidAmount();
    error InvalidAddress();
    error InvalidRecipient();
    error VentureNotFound();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error MarketAlreadyDeployed();
    error MarketNotDeployed();
    error WithdrawalsBlockedDuringActiveMarket();
    error InsufficientSharesMinted(uint256 minted, uint256 minimum);
    error InsufficientWithdrawAmount();
    error ZeroLiquidity();
    error InsufficientLiquidityPulled();
    error SpotPriceDeviationTooHigh();
    error InsufficientOracleHistory();
    error VaultImbalanced();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    /// @notice Emitted when an LP deposits venture + money tokens.
    event Deposit(
        address indexed sender, address indexed receiver, uint256 ventureUsed, uint256 moneyUsed, uint256 sharesMinted
    );

    /// @notice Emitted when an LP redeems vault shares for venture + money tokens.
    event Withdraw(
        address indexed sender, address indexed receiver, uint256 sharesBurned, uint256 ventureOut, uint256 moneyOut
    );

    /// @notice Emitted when UmiaMarketCore pulls liquidity into a decision market.
    event LiquidityPulledForMarket(
        uint256 indexed marketId, uint256 venturePulled, uint256 moneyPulled, uint128 liquidityPulled
    );

    /// @notice Emitted when UmiaMarketCore returns liquidity after settlement.
    event LiquidityReturnedFromMarket(
        uint256 indexed marketId, uint256 ventureReturned, uint256 moneyReturned, uint128 liquidityAdded
    );

    /// @notice Emitted when the protocol's share of crystallized swap fees is swept.
    event ProtocolFeeTaken(address indexed recipient, uint256 ventureAmount, uint256 moneyAmount);

    /// @notice Emitted when the bootstrap surplus (tokens the pool could not absorb at its
    ///         initial ratio) is forwarded to the venture treasury.
    event BootstrapSurplusForwarded(address indexed venture, uint256 ventureAmount, uint256 moneyAmount);

    // ─────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────

    function HUB() external view returns (address);
    function venture() external view returns (address);
    function ventureToken() external view returns (address);
    function moneyToken() external view returns (address);
    function poolManager() external view returns (address);
    function hook() external view returns (address);
    function totalShares() external view returns (uint256);
    function shareBalance(address account) external view returns (uint256);
    function deployedVenture(uint256 marketId) external view returns (uint256);
    function deployedMoney(uint256 marketId) external view returns (uint256);
    function totalDeployedVenture() external view returns (uint256);
    function totalDeployedMoney() external view returns (uint256);
    function isPoolInitialized() external view returns (bool);
    /// @notice The canonical pool key the vault manages liquidity for.
    function getPoolKey() external view returns (PoolKey memory);
    function tickLower() external view returns (int24);
    function tickUpper() external view returns (int24);
    function currentLiquidity() external view returns (uint128);

    /// @notice Returns the total venture + money assets the vault manages: in-pool reserves owned
    ///         by the vault's position, idle balances held directly, and amounts currently
    ///         deployed to active decision markets.
    function totalAssets() external view returns (uint256 ventureAssets, uint256 moneyAssets);

    // ─────────────────────────────────────────────────────────
    // LP Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Bootstrap the vault with the LBP-raised seed liquidity.
    /// @dev Callable only by the venture's configured LBP, after the LBP has initialized the pool.
    ///      One-shot. Pulls `ventureAmount + moneyAmount` from the caller (must be pre-approved),
    ///      folds them in as full-range liquidity, and mints initial shares to `sharesReceiver`
    ///      (the venture treasury). Whatever the pool cannot absorb at its initial ratio is
    ///      forwarded to the venture treasury rather than kept as idle NAV. The bootstrap doubles
    ///      as the protocol's seeded first deposit, neutralising any subsequent first-depositor
    ///      inflation attack.
    function bootstrapFromLBP(uint256 ventureAmount, uint256 moneyAmount, address sharesReceiver)
        external
        returns (uint256 sharesMinted);

    /// @notice Deposit venture + money tokens and mint vault shares to `receiver`.
    function deposit(uint256 ventureAmount, uint256 moneyAmount, uint256 minSharesOut, address receiver)
        external
        returns (uint256 shares, uint256 ventureUsed, uint256 moneyUsed);

    /// @notice Burn vault shares and return the underlying venture + money tokens.
    /// @dev Reverts if any active decision-market deployment is outstanding.
    function withdraw(uint256 sharesIn, uint256 minVentureOut, uint256 minMoneyOut, address receiver)
        external
        returns (uint256 ventureOut, uint256 moneyOut);

    // ─────────────────────────────────────────────────────────
    // Market Manager Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Pull `pullBps` of the vault's current pool liquidity into a decision market.
    /// @dev Only callable by UmiaMarketCore. Removes liquidity from the pool and transfers
    ///      the resulting venture + money tokens to the caller. Records per-market accounting so
    ///      LP withdrawals are blocked until the corresponding `returnFromDecisionMarket`.
    function pullForDecisionMarket(uint256 marketId, uint16 pullBps)
        external
        returns (uint256 venturePulled, uint256 moneyPulled, uint128 liquidityPulled);

    /// @notice Return market liquidity to the vault after settlement.
    /// @dev Only callable by UmiaMarketCore. Caller must have approved the vault for the
    ///      provided amounts; the vault pulls them and re-deploys them as full-range liquidity.
    function returnFromDecisionMarket(uint256 marketId, uint256 ventureAmount, uint256 moneyAmount)
        external
        returns (uint128 liquidityAdded);
}
