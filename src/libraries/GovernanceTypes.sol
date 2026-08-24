// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GovernanceTypes
/// @notice Shared structs and enums for governance execution payloads.
library GovernanceTypes {
    /// @notice Supported action types for governance execution plans.
    /// @dev New action types MUST be appended at the end. Existing ordinals are part
    ///      of the ABI of every encoded ExecutionPlanV1 — reordering or inserting
    ///      values would silently re-target previously-generated proposal payloads.
    enum ActionType {
        MINT_TOKENS,
        BURN_TOKENS,
        TRANSFER_TREASURY_ASSETS,
        UPDATE_MONTHLY_ALLOWANCE,
        UPDATE_TEAM_MEMBER,
        UPDATE_PARAMS,
        UPLOAD_DOCUMENT,
        LIQUIDATE_TREASURY,
        CALL,
        UPGRADE_IMPLEMENTATION,
        SET_ALLOWANCE
    }

    /// @notice Asset classes for treasury transfers and liquidation snapshots.
    enum AssetType {
        NATIVE,
        ERC20,
        ERC721,
        ERC1155
    }

    /// @notice A single governance action with typed payload data.
    struct ActionV1 {
        ActionType actionType;
        uint16 actionVersion;
        bytes data;
    }

    /// @notice Execution plan container with versioning.
    struct ExecutionPlanV1 {
        uint16 version;
        ActionV1[] actions;
    }

    /// @notice Parameters for minting venture tokens.
    struct MintTokens {
        address to;
        uint256 amount;
    }

    /// @notice Parameters for burning venture tokens from the treasury.
    struct BurnTokens {
        uint256 amount;
    }

    /// @notice Parameters for transferring treasury assets.
    struct TransferTreasuryAssets {
        AssetType assetType;
        address token;
        address to;
        uint256 amount;
        uint256 tokenId;
        bytes data;
    }

    /// @notice Parameters for updating the monthly allowance of a token.
    struct UpdateMonthlyAllowance {
        address token;
        uint256 amount;
    }

    /// @notice Parameters for updating a team member.
    struct UpdateTeamMember {
        address member;
        bool approved;
    }

    /// @notice Parameters for uploading a governance document reference.
    struct UploadDocument {
        string name;
        string uri;
    }

    /// @notice Parameters for an opaque treasury call.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice Asset definition for liquidation snapshots.
    struct LiquidationAsset {
        AssetType assetType;
        address token;
        uint256 tokenId;
    }

    /// @notice Liquidation plan describing assets and the liquidation contract.
    struct LiquidationPlan {
        address liquidator;
        LiquidationAsset[] assets;
    }

    /// @notice Parameters for upgrading the Venture implementation.
    struct UpgradeImplementation {
        address newImplementation;
        bytes data;
    }

    /// @notice Parameters for setting an ERC20 allowance from the treasury to a spender.
    /// @dev Used for programmatic pull access (e.g. TWAP buyback bots, keepers).
    ///      Distinct from the monthly team allowance system.
    struct SetAllowance {
        address token;
        address spender;
        uint256 amount;
    }
}
