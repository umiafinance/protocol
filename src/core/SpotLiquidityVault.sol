// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {PositionAmounts} from "../libraries/PositionAmounts.sol";
import {TwapMath} from "../libraries/TwapMath.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IUmiaHook} from "../interfaces/IUmiaHook.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";

/// @title SpotLiquidityVault
/// @notice Protocol-managed spot LP vault for a single venture.
/// @dev Holds a single full-range Uniswap v4 position for the canonical pool. Custodies LP
///      deposits, mints proportional shares, and exposes pull/return APIs to UmiaMarketCore
///      for sourcing decision-market bootstrap liquidity.
///
///      The vault calls PoolManager directly (via `unlock` -> `unlockCallback`) rather than
///      routing through the v4 PositionManager NFT system. This way UmiaHook can authorize
///      liquidity ops by checking `sender == address(vault)`. The vault's position is keyed
///      under its own address with a `bytes32(0)` salt.
///
///      Swap fees accrue V4-natively inside the position. On every liquidity-changing op the
///      vault crystallizes them into idle and skims `HUB.spotProtocolFeeCutBps()` to
///      `HUB.protocolFeeRecipient()`; the remainder stays with LP share holders.
///
///      Share accounting:
///      - Shares price against the vault's full NAV (in-pool reserves + idle), not in-pool
///        liquidity. bootstrapFromLBP mints the seed shares; later deposits mint
///        `min(ventureIn/totalV, moneyIn/totalM) * totalShares`. Crystallized fees and
///        asymmetric-return dust accrue as idle, so totalShares drifts above currentLiquidity
///        over time by design.
///      - During a deployment, deposits and withdrawals are blocked. Pull/return change the
///        in-pool liquidity (and any market P&L flows into the share-to-NAV ratio on return)
///        but do not mint or burn shares.
contract SpotLiquidityVault is ISpotLiquidityVault, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────

    uint16 internal constant MAX_BPS = 10_000;

    /// @notice TWAP window used to sandwich-guard liquidity-changing operations against
    ///         flash-loan spot manipulation.
    uint32 internal constant TWAP_WINDOW = 30 minutes;

    /// @notice Maximum allowed absolute tick deviation between current spot and TWAP. ~1000
    ///         ticks ≈ 10.5% price deviation — wide enough that organic volatility over the
    ///         30-min TWAP window does not DoS settleMarket/createMarket, tight enough that
    ///         flash-loan sandwiches must move price by >10% to bypass.
    int24 internal constant MAX_TICK_DEVIATION = 1000;

    /// @notice Oracle ring-buffer cardinality seeded at bootstrap; anyone can grow it further
    ///         via the hook's `increaseCardinalityNext`.
    uint16 internal constant INITIAL_ORACLE_CARDINALITY = 100;

    // ─────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────

    /// @notice The UmiaHub contract this vault is registered with.
    address public immutable HUB;

    /// @notice The venture this vault provides canonical liquidity for.
    address public immutable venture;

    /// @notice The venture token (one side of the pool).
    address public immutable ventureToken;

    /// @notice The money token (other side of the pool).
    address public immutable moneyToken;

    /// @notice The Uniswap v4 PoolManager.
    address public immutable poolManager;

    /// @notice The UmiaHook address bound to the canonical pool.
    address public immutable hook;

    /// @notice True iff ventureToken sorts lower than moneyToken (currency0 == ventureToken).
    bool public immutable ventureIsToken0;

    /// @notice Full-range lower tick for the position.
    int24 public immutable tickLower;

    /// @notice Full-range upper tick for the position.
    int24 public immutable tickUpper;

    /// @notice The pool's swap fee, in hundredths of a bip.
    uint24 internal immutable _poolFee;

    /// @notice The pool's tick spacing.
    int24 internal immutable _poolTickSpacing;

    /// @notice PoolId of the canonical pool. Constant per vault; cached to avoid re-hashing the key.
    PoolId internal immutable _poolId;

    /// @notice sqrtPriceX96 at the full-range lower/upper ticks. Constant per vault.
    uint160 internal immutable _sqrtLower;
    uint160 internal immutable _sqrtUpper;

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    /// @notice Total vault shares outstanding.
    uint256 public totalShares;

    /// @notice Per-account vault share balance.
    mapping(address => uint256) public shareBalance;

    /// @notice venture tokens currently deployed to a decision market (per market).
    mapping(uint256 => uint256) public deployedVenture;

    /// @notice money tokens currently deployed to a decision market (per market).
    mapping(uint256 => uint256) public deployedMoney;

    /// @notice Sum of `deployedVenture` across all active markets.
    uint256 public totalDeployedVenture;

    /// @notice Sum of `deployedMoney` across all active markets.
    uint256 public totalDeployedMoney;

    /// @notice True iff the canonical pool has been bootstrapped.
    bool public isPoolInitialized;

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Build the vault for `_venture` and bind it to `_hook` on `_poolManager`.
    /// @dev Reads the venture + money token addresses from the venture. The constructor does NOT
    ///      touch the pool: that requires the hook to know this vault is its operator, which the
    ///      LBP arranges via `UmiaHook.registerPool` at migration.
    constructor(address _hub, address _venture, address _poolManager, address _hook, uint24 _fee, int24 _tickSpacing) {
        if (_hub == address(0) || _venture == address(0) || _poolManager == address(0) || _hook == address(0)) {
            revert InvalidAddress();
        }

        HUB = _hub;
        venture = _venture;
        poolManager = _poolManager;
        hook = _hook;
        _poolFee = _fee;
        _poolTickSpacing = _tickSpacing;

        address _ventureToken = IVenture(_venture).token();
        address _moneyToken = IVenture(_venture).moneyToken();
        ventureToken = _ventureToken;
        moneyToken = _moneyToken;
        ventureIsToken0 = _ventureToken < _moneyToken;

        tickLower = TickMath.minUsableTick(_tickSpacing);
        tickUpper = TickMath.maxUsableTick(_tickSpacing);

        _sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        _sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        _poolId = _poolKey().toId();
    }

    // ─────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc ISpotLiquidityVault
    function getPoolKey() public view returns (PoolKey memory) {
        return _poolKey();
    }

    /// @inheritdoc ISpotLiquidityVault
    function currentLiquidity() public view returns (uint128 liquidity) {
        if (!isPoolInitialized) return 0;
        (liquidity,,) =
            IPoolManager(poolManager).getPositionInfo(_poolId, address(this), tickLower, tickUpper, bytes32(0));
    }

    /// @inheritdoc ISpotLiquidityVault
    function totalAssets() public view returns (uint256 ventureAssets, uint256 moneyAssets) {
        uint256 idleVenture = IERC20(ventureToken).balanceOf(address(this));
        uint256 idleMoney = IERC20(moneyToken).balanceOf(address(this));
        (uint256 poolVenture, uint256 poolMoney) = _poolAmountsForLiquidity(currentLiquidity());
        ventureAssets = idleVenture + poolVenture + totalDeployedVenture;
        moneyAssets = idleMoney + poolMoney + totalDeployedMoney;
    }

    // ─────────────────────────────────────────────────────────
    // Pool Bootstrap (LBP-only entrypoint)
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc ISpotLiquidityVault
    /// @dev Gated to the venture's LBP. The LBP initializes the pool itself (as the hook's
    ///      registered launcher) immediately before calling this, then approves this vault for
    ///      `ventureAmount` + `moneyAmount`. The bootstrap acts as the protocol's seeded first
    ///      deposit: it mints non-trivial initial shares to `sharesReceiver` (the venture
    ///      treasury), which neutralises the ERC4626 first-depositor inflation attack against any
    ///      subsequent public depositor.
    function bootstrapFromLBP(uint256 ventureAmount, uint256 moneyAmount, address sharesReceiver)
        external
        nonReentrant
        returns (uint256 sharesMinted)
    {
        if (isPoolInitialized) revert PoolAlreadyInitialized();
        if (ventureAmount == 0 || moneyAmount == 0) revert InvalidAmount();
        if (sharesReceiver == address(0)) revert InvalidRecipient();

        if (msg.sender != IVenture(venture).lbp()) revert CallerNotLBP();

        // Mark bootstrapped before any external call so re-entry can not race a second bootstrap.
        isPoolInitialized = true;

        // Pull the LBP-raised seed liquidity. Standard token transfer; LBP approves up-front.
        IERC20(ventureToken).safeTransferFrom(msg.sender, address(this), ventureAmount);
        IERC20(moneyToken).safeTransferFrom(msg.sender, address(this), moneyAmount);

        // Pre-grow the hook's oracle ring buffer so the 30-min TWAP window has slots to fill
        // promptly. Without this, cardinality stays at 1 after afterInitialize and the sandwich
        // guard's "full window" predicate stays false indefinitely — disabling protection on
        // exactly the highest-value targets (first market bootstrap).
        IUmiaHook(hook).increaseCardinalityNext(_poolKey(), INITIAL_ORACLE_CARDINALITY);

        // Snapshot for the Deposit event, which reports what the pool absorbed rather than what
        // the LBP handed over. A freshly initialized pool has no fees to take back, so the fold
        // only ever settles out of this contract and these balances can only shrink.
        uint256 ventureBalBefore = IERC20(ventureToken).balanceOf(address(this));
        uint256 moneyBalBefore = IERC20(moneyToken).balanceOf(address(this));

        // Fold the LBP's tokens into a full-range position at the pool's exact ratio.
        uint128 liquidityAdded = _addIdleAsLiquidity();
        if (liquidityAdded == 0) revert ZeroLiquidity();

        sharesMinted = uint256(liquidityAdded);
        totalShares = sharesMinted;
        shareBalance[sharesReceiver] = sharesMinted;

        // The LBP hands over the full token reserve, which is deliberately larger than the pool
        // can absorb against the raised money. The surplus belongs to the venture treasury;
        // keeping it as idle NAV would distort LP share pricing without adding pool depth.
        uint256 surplusVenture = IERC20(ventureToken).balanceOf(address(this));
        uint256 surplusMoney = IERC20(moneyToken).balanceOf(address(this));
        if (surplusVenture > 0) IERC20(ventureToken).safeTransfer(venture, surplusVenture);
        if (surplusMoney > 0) IERC20(moneyToken).safeTransfer(venture, surplusMoney);
        if (surplusVenture > 0 || surplusMoney > 0) {
            emit BootstrapSurplusForwarded(venture, surplusVenture, surplusMoney);
        }

        emit Deposit(
            msg.sender, sharesReceiver, ventureBalBefore - surplusVenture, moneyBalBefore - surplusMoney, sharesMinted
        );
    }

    // ─────────────────────────────────────────────────────────
    // LP: Deposit
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc ISpotLiquidityVault
    /// @dev Shares are computed against the vault's full NAV (in-pool reserves + idle balance),
    ///      so a new depositor pays for their pro-rata fraction of every token the vault owns —
    ///      including accrued swap fees and any dust idle from prior settlements.
    function deposit(uint256 ventureAmount, uint256 moneyAmount, uint256 minSharesOut, address receiver)
        external
        nonReentrant
        returns (uint256 shares, uint256 ventureUsed, uint256 moneyUsed)
    {
        if (receiver == address(0)) revert InvalidRecipient();
        if (ventureAmount == 0 || moneyAmount == 0) revert InvalidAmount();
        if (!isPoolInitialized) revert PoolNotInitialized();
        if (totalDeployedVenture != 0 || totalDeployedMoney != 0) revert WithdrawalsBlockedDuringActiveMarket();

        // Crystallize accrued pool fees into vault idle (and skim the protocol cut). Without this,
        // the next modifyLiquidity would return `principal + fees` as callerDelta and the
        // balance-delta math would either underflow (fees > principal) or silently transfer fees
        // to the depositor (fee skim).
        _crystallizeFees();

        // Sandwich guard: NAV uses the live sqrtPriceX96, so a flash-loan price skew between
        // user-tx submission and execution would mis-price shares. Reject if spot diverges from
        // TWAP by more than MAX_TICK_DEVIATION.
        _requireSpotWithinTwapDeviation();

        (uint256 totalV, uint256 totalM) = totalAssets();

        // If `totalShares > 0` but one side of NAV is zero, the pool/idle has been driven into a
        // degenerate state. Entering the bootstrap branch in that state would let a new depositor
        // mint shares purely from their own input and dilute existing LPs. Block until rebalanced.
        if (totalShares > 0 && (totalV == 0 || totalM == 0)) revert VaultImbalanced();

        if (totalShares == 0) {
            // True bootstrap (defensive: bootstrapFromLBP already mints non-zero shares).
            (uint256 amount0, uint256 amount1) =
                ventureIsToken0 ? (ventureAmount, moneyAmount) : (moneyAmount, ventureAmount);
            uint160 sqrtPriceX96 = _currentSqrtPrice();
            uint128 liq =
                LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, _sqrtLower, _sqrtUpper, amount0, amount1);
            if (liq == 0) revert ZeroLiquidity();
            shares = uint256(liq);
            ventureUsed = ventureAmount;
            moneyUsed = moneyAmount;
        } else {
            // ERC4626-style: shares = min(ventureIn/totalV, moneyIn/totalM) × totalShares.
            uint256 sharesFromV = Math.mulDiv(ventureAmount, totalShares, totalV);
            uint256 sharesFromM = Math.mulDiv(moneyAmount, totalShares, totalM);
            shares = sharesFromV < sharesFromM ? sharesFromV : sharesFromM;
            if (shares == 0) revert ZeroLiquidity();
            // Round-up the actual amounts used so existing LPs are never short-changed.
            ventureUsed = Math.mulDiv(shares, totalV, totalShares, Math.Rounding.Ceil);
            moneyUsed = Math.mulDiv(shares, totalM, totalShares, Math.Rounding.Ceil);
            // Cap at the LP's provided amounts (rounding-up can momentarily exceed by 1 wei).
            if (ventureUsed > ventureAmount) ventureUsed = ventureAmount;
            if (moneyUsed > moneyAmount) moneyUsed = moneyAmount;
        }

        if (shares < minSharesOut) revert InsufficientSharesMinted(shares, minSharesOut);

        if (ventureUsed > 0) IERC20(ventureToken).safeTransferFrom(msg.sender, address(this), ventureUsed);
        if (moneyUsed > 0) IERC20(moneyToken).safeTransferFrom(msg.sender, address(this), moneyUsed);

        // Fold the LP's contribution (and any pre-existing idle) into the pool position. Whatever
        // the pool can't absorb at the current ratio stays as idle and contributes to the next
        // deposit's NAV-based share pricing or the next withdraw's pro-rata distribution.
        _addIdleAsLiquidity();

        totalShares += shares;
        shareBalance[receiver] += shares;

        emit Deposit(msg.sender, receiver, ventureUsed, moneyUsed, shares);
    }

    // ─────────────────────────────────────────────────────────
    // LP: Withdraw
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc ISpotLiquidityVault
    /// @dev Withdrawer receives pro-rata of `(pool reserves + idle balance)`. The idle
    ///      distribution is essential: accrued fees and asymmetric-return dust accumulate as
    ///      idle (since they don't always fit the pool ratio), and without a redistribution path
    ///      they would be locked forever.
    function withdraw(uint256 sharesIn, uint256 minVentureOut, uint256 minMoneyOut, address receiver)
        external
        nonReentrant
        returns (uint256 ventureOut, uint256 moneyOut)
    {
        if (receiver == address(0)) revert InvalidRecipient();
        if (sharesIn == 0) revert InvalidAmount();
        if (totalDeployedVenture != 0 || totalDeployedMoney != 0) revert WithdrawalsBlockedDuringActiveMarket();

        uint256 shareBal = shareBalance[msg.sender];
        if (sharesIn > shareBal) revert InvalidAmount();

        // Crystallize fees (and skim the protocol cut) so the pool-side removal returns clean
        // principal-only delta.
        _crystallizeFees();
        // Sandwich guard — withdraw amounts derive from current pool reserves at sqrtPriceX96.
        _requireSpotWithinTwapDeviation();

        uint128 liqBefore = currentLiquidity();
        uint128 liquidityToRemove = liqBefore == 0 ? 0 : uint128(Math.mulDiv(uint256(liqBefore), sharesIn, totalShares));

        // Idle claim uses the pre-burn totalShares, so a holder's fraction is right even if others
        // leave their idle behind. No token moves between here and the pool removal, so these
        // balances double as the pre-removal baseline for measuring pool proceeds.
        uint256 _totalShares = totalShares;
        uint256 ventureBalBefore = IERC20(ventureToken).balanceOf(address(this));
        uint256 moneyBalBefore = IERC20(moneyToken).balanceOf(address(this));
        uint256 idleVentureShare = Math.mulDiv(ventureBalBefore, sharesIn, _totalShares);
        uint256 idleMoneyShare = Math.mulDiv(moneyBalBefore, sharesIn, _totalShares);

        shareBalance[msg.sender] = shareBal - sharesIn;
        totalShares = _totalShares - sharesIn;

        if (liquidityToRemove > 0) {
            _modifyLiquidity(-int256(uint256(liquidityToRemove)));
        }

        uint256 poolVentureOut = IERC20(ventureToken).balanceOf(address(this)) - ventureBalBefore;
        uint256 poolMoneyOut = IERC20(moneyToken).balanceOf(address(this)) - moneyBalBefore;

        ventureOut = poolVentureOut + idleVentureShare;
        moneyOut = poolMoneyOut + idleMoneyShare;

        if (ventureOut < minVentureOut || moneyOut < minMoneyOut) revert InsufficientWithdrawAmount();

        if (ventureOut > 0) IERC20(ventureToken).safeTransfer(receiver, ventureOut);
        if (moneyOut > 0) IERC20(moneyToken).safeTransfer(receiver, moneyOut);

        emit Withdraw(msg.sender, receiver, sharesIn, ventureOut, moneyOut);
    }

    // ─────────────────────────────────────────────────────────
    // Market Manager Hooks
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc ISpotLiquidityVault
    /// @dev Crystallizes accrued pool fees into vault idle BEFORE pulling, so MM receives only
    ///      principal from the position. Fees stay with LP share holders (minus the protocol cut).
    function pullForDecisionMarket(uint256 marketId, uint16 pullBps)
        external
        nonReentrant
        returns (uint256 venturePulled, uint256 moneyPulled, uint128 liquidityPulled)
    {
        _requireMarketCore();
        if (pullBps == 0 || pullBps > MAX_BPS) revert InvalidPullBps();
        if (deployedVenture[marketId] != 0 || deployedMoney[marketId] != 0) revert MarketAlreadyDeployed();

        _crystallizeFees();
        // Sandwich guard — pulled (venture, money) ratio is determined by current sqrtPriceX96; a
        // skewed pool would seed the decision-market CPMM at the wrong implied price.
        _requireSpotWithinTwapDeviation();

        uint128 liqBefore = currentLiquidity();
        if (liqBefore == 0) revert ZeroLiquidity();

        liquidityPulled = uint128(Math.mulDiv(uint256(liqBefore), pullBps, MAX_BPS));
        if (liquidityPulled == 0) revert InsufficientLiquidityPulled();

        uint256 ventureBalBefore = IERC20(ventureToken).balanceOf(address(this));
        uint256 moneyBalBefore = IERC20(moneyToken).balanceOf(address(this));

        _modifyLiquidity(-int256(uint256(liquidityPulled)));

        venturePulled = IERC20(ventureToken).balanceOf(address(this)) - ventureBalBefore;
        moneyPulled = IERC20(moneyToken).balanceOf(address(this)) - moneyBalBefore;

        deployedVenture[marketId] = venturePulled;
        deployedMoney[marketId] = moneyPulled;
        totalDeployedVenture += venturePulled;
        totalDeployedMoney += moneyPulled;

        if (venturePulled > 0) IERC20(ventureToken).safeTransfer(msg.sender, venturePulled);
        if (moneyPulled > 0) IERC20(moneyToken).safeTransfer(msg.sender, moneyPulled);

        emit LiquidityPulledForMarket(marketId, venturePulled, moneyPulled, liquidityPulled);
    }

    /// @inheritdoc ISpotLiquidityVault
    function returnFromDecisionMarket(uint256 marketId, uint256 ventureAmount, uint256 moneyAmount)
        external
        nonReentrant
        returns (uint128 liquidityAdded)
    {
        _requireMarketCore();
        uint256 oldDeployedVenture = deployedVenture[marketId];
        uint256 oldDeployedMoney = deployedMoney[marketId];
        if (oldDeployedVenture == 0 && oldDeployedMoney == 0) revert MarketNotDeployed();

        // Clear the per-market deployment record FIRST so the caller can use (0, 0) to clear an
        // outstanding deployment whose claims fully consumed real reserves. Without this early
        // clear, a zero-excess settlement would strand the deployment record and brick LP
        // withdraws permanently (`WithdrawalsBlockedDuringActiveMarket`).
        deployedVenture[marketId] = 0;
        deployedMoney[marketId] = 0;
        totalDeployedVenture -= oldDeployedVenture;
        totalDeployedMoney -= oldDeployedMoney;

        if (ventureAmount == 0 && moneyAmount == 0) {
            emit LiquidityReturnedFromMarket(marketId, 0, 0, 0);
            return 0;
        }

        // Crystallize fees before mixing returned tokens with idle so per-LP fee accounting
        // doesn't blur. Sandwich guard so the post-settle add-liquidity ratio isn't manipulable.
        _crystallizeFees();
        _requireSpotWithinTwapDeviation();

        // Pull the returned tokens into the vault. Skip zero-amount transferFrom to accommodate
        // ERC20s that reject zero-value transfers.
        if (ventureAmount > 0) IERC20(ventureToken).safeTransferFrom(msg.sender, address(this), ventureAmount);
        if (moneyAmount > 0) IERC20(moneyToken).safeTransferFrom(msg.sender, address(this), moneyAmount);

        // Fold returned tokens (plus any pre-existing idle) into the pool position. Single-sided
        // returns or ratio mismatch leave dust as idle, redeemable by LPs on withdraw.
        liquidityAdded = _addIdleAsLiquidity();

        emit LiquidityReturnedFromMarket(marketId, ventureAmount, moneyAmount, liquidityAdded);
    }

    // ─────────────────────────────────────────────────────────
    // PoolManager Callback
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IUnlockCallback
    /// @dev Called by PoolManager after `unlock`. Decodes the requested liquidity delta, applies
    ///      it via `modifyLiquidity`, and settles or takes both currencies based on the returned
    ///      balance delta.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert CallerNotPoolManager();
        int256 liquidityDelta = abi.decode(data, (int256));

        PoolKey memory key = _poolKey();
        (BalanceDelta delta,) = IPoolManager(poolManager)
            .modifyLiquidity(
                key,
                ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
                ""
            );

        _settleOrTake(key.currency0, delta.amount0());
        _settleOrTake(key.currency1, delta.amount1());

        return abi.encode(delta);
    }

    // ─────────────────────────────────────────────────────────
    // Internal: Liquidity
    // ─────────────────────────────────────────────────────────

    function _modifyLiquidity(int256 liquidityDelta) internal {
        IPoolManager(poolManager).unlock(abi.encode(liquidityDelta));
    }

    /// @dev Pokes the V4 position with `liquidityDelta = 0`. V4 still computes accrued fees on
    ///      a zero-delta modify and credits them via callerDelta — this drains pending fees out
    ///      of the pool's `feeGrowthInside` accumulator and into the vault's ERC20 balance. The
    ///      protocol's configured share of those fees is skimmed to `protocolFeeRecipient`; the
    ///      remainder stays as idle for LP share holders. All subsequent `_modifyLiquidity(±L)`
    ///      calls within the same tx then return clean principal-only deltas.
    function _crystallizeFees() internal {
        if (currentLiquidity() == 0) return;
        uint256 ventureBefore = IERC20(ventureToken).balanceOf(address(this));
        uint256 moneyBefore = IERC20(moneyToken).balanceOf(address(this));
        _modifyLiquidity(0);
        uint256 feeVenture = IERC20(ventureToken).balanceOf(address(this)) - ventureBefore;
        uint256 feeMoney = IERC20(moneyToken).balanceOf(address(this)) - moneyBefore;
        if (feeVenture != 0 || feeMoney != 0) _takeProtocolFee(feeVenture, feeMoney);
    }

    /// @dev Skims `spotProtocolFeeCutBps` of newly crystallized swap fees to `protocolFeeRecipient`
    ///      (a cut of fee income, not swap volume). No-op when the rate or recipient is unset.
    function _takeProtocolFee(uint256 feeVenture, uint256 feeMoney) internal {
        uint16 bps = IUmiaHub(HUB).spotProtocolFeeCutBps();
        if (bps == 0) return;
        address recipient = IUmiaHub(HUB).protocolFeeRecipient();
        if (recipient == address(0)) return;
        uint256 cutVenture = Math.mulDiv(feeVenture, bps, MAX_BPS);
        uint256 cutMoney = Math.mulDiv(feeMoney, bps, MAX_BPS);
        if (cutVenture != 0) IERC20(ventureToken).safeTransfer(recipient, cutVenture);
        if (cutMoney != 0) IERC20(moneyToken).safeTransfer(recipient, cutMoney);
        emit ProtocolFeeTaken(recipient, cutVenture, cutMoney);
    }

    /// @dev Sandwich guard: revert if the current spot tick deviates from the hook's TWAP by more
    ///      than `MAX_TICK_DEVIATION` over a `TWAP_WINDOW` lookback. Fails CLOSED
    ///      (`InsufficientOracleHistory`) when the oracle can't serve the full window — a young
    ///      pool or a wrapped buffer must not silently disable the guard. Grow the buffer via
    ///      `increaseCardinalityNext` and wait `TWAP_WINDOW` to clear it. The only skip is an empty
    ///      position (`currentLiquidity() == 0`): no reserves to sandwich, and keeping it open lets
    ///      a fully-drained vault be re-bootstrapped.
    function _requireSpotWithinTwapDeviation() internal view {
        if (currentLiquidity() == 0) return;
        if (!_oracleHasFullWindow(_poolId)) revert InsufficientOracleHistory();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;
        (int48[] memory tickCumulatives,) = IUmiaHook(hook).observe(_poolKey(), secondsAgos);
        int24 twapTick = TwapMath.averageTick(tickCumulatives[0], tickCumulatives[1], TWAP_WINDOW);

        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(_poolId);
        int24 spotTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (diff > MAX_TICK_DEVIATION) revert SpotPriceDeviationTooHigh();
    }

    /// @dev Returns true iff the hook's oracle holds at least two distinct observations and the
    ///      oldest one is at or before `block.timestamp - TWAP_WINDOW`. Cardinality must be >= 2
    ///      because `observe` on a single observation extrapolates forward and produces
    ///      `twapTick == spotTick` — i.e. the deviation check would always pass, silently
    ///      disabling the sandwich guard.
    function _oracleHasFullWindow(PoolId id) internal view returns (bool) {
        (uint16 cIndex, uint16 cardinality,) = IUmiaHook(hook).oracleStates(id);
        if (cardinality < 2) return false;

        // The slot immediately after `cIndex` (mod cardinality) holds the oldest valid observation
        // if the buffer has wrapped, otherwise slot 0 is the oldest.
        uint16 oldestIndex = (cIndex + 1) % cardinality;
        (uint32 oldestTs,,, bool oldestInit) = IUmiaHook(hook).getObservation(id, oldestIndex);
        if (!oldestInit) {
            (oldestTs,,, oldestInit) = IUmiaHook(hook).getObservation(id, 0);
            if (!oldestInit) return false;
        }

        return uint32(block.timestamp) >= oldestTs + TWAP_WINDOW;
    }

    /// @dev Adds the vault's full idle balance as new pool liquidity, best-effort. Whatever
    ///      side over-supplies the current pool ratio remains as idle and is picked up by the
    ///      next call. Returns the liquidity units actually added.
    function _addIdleAsLiquidity() internal returns (uint128 liquidityAdded) {
        address t0 = ventureIsToken0 ? ventureToken : moneyToken;
        address t1 = ventureIsToken0 ? moneyToken : ventureToken;
        uint256 idle0 = IERC20(t0).balanceOf(address(this));
        uint256 idle1 = IERC20(t1).balanceOf(address(this));
        if (idle0 == 0 || idle1 == 0) return 0;

        uint160 sqrtPriceX96 = _currentSqrtPrice();
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, _sqrtLower, _sqrtUpper, idle0, idle1);
        if (liquidityAdded > 0) _modifyLiquidity(int256(uint256(liquidityAdded)));
    }

    /// @dev If `amount` is negative, the vault owes the pool: transfer the underlying into the
    ///      PoolManager and call settle. If positive, the pool owes the vault: take the amount
    ///      out to this contract. Zero is a no-op.
    function _settleOrTake(Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(-int256(amount));
            IPoolManager(poolManager).sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(poolManager, owed);
            IPoolManager(poolManager).settle();
        } else if (amount > 0) {
            uint256 due = uint256(int256(amount));
            IPoolManager(poolManager).take(currency, address(this), due);
        }
    }

    function _poolKey() internal view returns (PoolKey memory) {
        (address c0, address c1) = ventureIsToken0 ? (ventureToken, moneyToken) : (moneyToken, ventureToken);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: _poolFee,
            tickSpacing: _poolTickSpacing,
            hooks: IHooks(hook)
        });
    }

    function _currentSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(_poolId);
    }

    function _poolAmountsForLiquidity(uint128 liquidity)
        internal
        view
        returns (uint256 ventureAmount, uint256 moneyAmount)
    {
        if (liquidity == 0 || !isPoolInitialized) return (0, 0);
        uint160 sqrtPriceX96 = _currentSqrtPrice();
        (uint256 amount0, uint256 amount1) =
            PositionAmounts.getAmountsForLiquidity(sqrtPriceX96, _sqrtLower, _sqrtUpper, liquidity);
        (ventureAmount, moneyAmount) = ventureIsToken0 ? (amount0, amount1) : (amount1, amount0);
    }

    function _requireMarketCore() internal view {
        if (msg.sender != IUmiaHub(HUB).umiaMarketCore()) revert CallerNotMarketCore();
    }
}
