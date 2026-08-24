// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILiquidator} from "../interfaces/ILiquidator.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {GovernanceTypes} from "../libraries/GovernanceTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SimpleLiquidator
/// @notice A simple pro-rata liquidation strategy for fungible assets.
/// @dev Supports NATIVE and ERC20 assets only. One-time full claim.
///      Users burn their entire venture token balance through the venture to claim their pro-rata share.
contract SimpleLiquidator is ILiquidator, ReentrancyGuard {
    /// @notice Thrown when the liquidator is deployed without a hub.
    error InvalidHub();

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    /// @notice The canonical hub this liquidator trusts to resolve a venture's governance executor.
    address public immutable HUB;

    /// @notice The Venture treasury being liquidated
    address public venture;

    /// @notice The venture token contract address
    address public ventureToken;

    /// @notice Total supply snapshot at liquidation start
    uint256 public totalSupplySnapshot;

    /// @notice Whether liquidation has been initialized
    bool public initialized;

    /// @notice Array of assets being liquidated
    LiquidationAssetSnapshot[] internal _liquidationAssets;

    /// @notice Track which accounts have claimed
    mapping(address => bool) public hasClaimed;

    /// @notice Internal struct for asset snapshots
    struct LiquidationAssetSnapshot {
        GovernanceTypes.AssetType assetType;
        address token;
        uint256 tokenId;
        uint256 balance;
    }

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Binds the liquidator to a hub; call initialize() after deployment.
    constructor(address _hub) {
        if (_hub == address(0)) revert InvalidHub();
        HUB = _hub;
    }

    // ─────────────────────────────────────────────────────────
    // ILiquidator Implementation
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc ILiquidator
    function initialize(address _venture, GovernanceTypes.LiquidationAsset[] calldata _assets, uint256 _totalSupply)
        external
        override
    {
        if (initialized) revert AlreadyInitialized();
        if (_venture == address(0)) revert InvalidAssetType();
        if (_totalSupply == 0) revert InvalidAssetType();
        if (msg.sender != IUmiaHub(HUB).governanceExecutor(_venture)) {
            revert CallerNotAuthorized();
        }
        if (IVenture(_venture).authorizedLiquidator() != address(this)) revert CallerNotAuthorized();

        venture = _venture;
        ventureToken = IVenture(_venture).token();
        totalSupplySnapshot = _totalSupply;
        initialized = true;

        // Snapshot asset balances
        uint256 assetCount = _assets.length;
        for (uint256 i = 0; i < assetCount; i++) {
            GovernanceTypes.LiquidationAsset calldata asset = _assets[i];

            // SimpleLiquidator only supports NATIVE and ERC20
            if (
                asset.assetType != GovernanceTypes.AssetType.NATIVE
                    && asset.assetType != GovernanceTypes.AssetType.ERC20
            ) {
                revert InvalidAssetType();
            }

            // The venture token is the claim-burn token, not a distributable asset. If it is listed,
            // skip it: paying it back out pro-rata would let a claimant forward the payout to fresh
            // addresses and claim again (hasClaimed is keyed per-address), drawing more than their
            // share. Skipping keeps a governance plan that mistakenly lists it fully executable.
            if (asset.assetType == GovernanceTypes.AssetType.ERC20 && asset.token == ventureToken) {
                continue;
            }

            uint256 balance = _getAssetBalance(asset);
            _liquidationAssets.push(
                LiquidationAssetSnapshot({
                    assetType: asset.assetType, token: asset.token, tokenId: asset.tokenId, balance: balance
                })
            );
        }

        emit Initialized(_venture, _totalSupply, _liquidationAssets.length);
    }

    /// @inheritdoc ILiquidator
    function claim() external override nonReentrant {
        if (!initialized) revert NotInitialized();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();

        // Get user's venture token balance - must burn ALL of it
        uint256 userBalance = IERC20(ventureToken).balanceOf(msg.sender);
        if (userBalance == 0) revert NothingToClaim();

        // Mark as claimed before external calls (CEI pattern)
        hasClaimed[msg.sender] = true;

        // Burn the tokens via Venture directly from the claimant. This avoids any
        // dependence on ERC20 transfers being available while the token is paused.
        IVenture(venture).burnFrom(msg.sender, userBalance);

        // Calculate and transfer pro-rata share of each asset
        uint256 assetCount = _liquidationAssets.length;
        for (uint256 i = 0; i < assetCount; i++) {
            LiquidationAssetSnapshot memory asset = _liquidationAssets[i];

            // Calculate pro-rata: asset.balance * userBalance / totalSupplySnapshot
            uint256 payout = FullMath.mulDiv(asset.balance, userBalance, totalSupplySnapshot);
            if (payout == 0) continue;

            // Call Venture to withdraw this user's share
            // Venture checks that caller is authorizedLiquidator
            if (asset.assetType == GovernanceTypes.AssetType.NATIVE) {
                IVenture(venture).withdraw(address(0), msg.sender, payout);
            } else {
                IVenture(venture).withdraw(asset.token, msg.sender, payout);
            }
        }

        emit Claimed(msg.sender, userBalance);
    }

    /// @inheritdoc ILiquidator
    function claimableAmount(address _account) external view override returns (uint256[] memory amounts) {
        if (!initialized) revert NotInitialized();

        uint256 userBalance = IERC20(ventureToken).balanceOf(_account);
        uint256 assetCount = _liquidationAssets.length;
        amounts = new uint256[](assetCount);

        if (hasClaimed[_account] || userBalance == 0) {
            // Already claimed or no balance - return zeros
            return amounts;
        }

        for (uint256 i = 0; i < assetCount; i++) {
            LiquidationAssetSnapshot memory asset = _liquidationAssets[i];
            amounts[i] = FullMath.mulDiv(asset.balance, userBalance, totalSupplySnapshot);
        }
    }

    /// @inheritdoc ILiquidator
    function liquidationAssets(uint256 _index)
        external
        view
        override
        returns (GovernanceTypes.AssetType assetType, address token, uint256 tokenId, uint256 balance)
    {
        if (_index >= _liquidationAssets.length) revert InvalidAssetType();
        LiquidationAssetSnapshot storage asset = _liquidationAssets[_index];
        return (asset.assetType, asset.token, asset.tokenId, asset.balance);
    }

    /// @inheritdoc ILiquidator
    function liquidationAssetCount() external view override returns (uint256) {
        return _liquidationAssets.length;
    }

    // ─────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────

    function _getAssetBalance(GovernanceTypes.LiquidationAsset calldata asset) internal view returns (uint256) {
        if (asset.assetType == GovernanceTypes.AssetType.NATIVE) {
            return address(venture).balance;
        }
        if (asset.assetType == GovernanceTypes.AssetType.ERC20) {
            return IERC20(asset.token).balanceOf(venture);
        }
        // Should never reach here due to validation in initialize()
        revert InvalidAssetType();
    }
}
