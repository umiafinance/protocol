// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVentureVestingAuthority
/// @notice Per-venture adapter that holds a MetaVesT controller's `authority` role and routes it to
///         the venture treasury, so that post-launch only futarchy can create / amend / terminate
///         vesting allocations. The adapter is also the per-allocation price-milestone registry:
///         a grant's price ladder is written here in the same transaction as `createMetavest`, so
///         there is a single mutating path (and a single auth gate) for grants and their ladders.
interface IVentureVestingAuthority {
    error ZeroAddress();
    error NotDeployer();
    error AlreadyBound();
    error VentureNotFound();
    error NotTreasury();
    error GenesisClosed();
    error NotCreateMetavest();
    error InvalidControllerReturn();
    /// @dev A price program is write-once per allocation.
    error ProgramAlreadyRegistered();
    /// @dev A price program was supplied with no thresholds/multiples.
    error EmptyThresholds();
    /// @dev A threshold/multiple of 0 would unlock on any post-pool price; disallowed.
    error ZeroThreshold();
    error ThresholdsNotAscending();
    /// @dev A cliffs array was supplied but its length differs from the program's milestone count.
    error CliffsLengthMismatch();
    /// @dev A price program was attached to a non-`createMetavest` call, its kind is unknown, or a
    ///      `None` program carried non-empty arrays.
    error InvalidPriceProgram();
    /// @dev No price program for the allocation, or the milestone index is out of range.
    error NotRegistered();
    /// @dev A relative program was read before `bind`, so the venture's auction can't be resolved yet.
    error NotBound();
    /// @dev A relative program was read before its auction had a clearing price (`clearingPrice()` is 0).
    error AuctionNotCleared();
    /// @dev A forwarded call tried to move the controller's `authority` off this adapter. The TWAP
    ///      condition resolves its price-ladder registry via `controller.authority()`, so the adapter
    ///      must hold authority for the venture's life or every price milestone breaks.
    error AuthorityTransferForbidden();
    /// @dev A forwarded call tried to terminate a grant. That path leaves the clawback parked on the
    ///      adapter; use {terminateGrant}, which the treasury may also call and which sweeps.
    error UseTerminateGrant();
    /// @dev A grant mutation was attempted while the bound venture is liquidating. Liquidation pays
    ///      out pro-rata against a supply snapshot, so entitlements are frozen from that point.
    error LiquidationActive();
    /// @dev A reissue's replacement grant is denominated in a token other than {ventureToken}.
    error ReissueTokenMismatch();
    /// @dev Caller is neither the bound treasury nor the Hub's vesting admin (or the admin path is
    ///      unset platform-wide, or this venture revoked it).
    error NotAuthorized();

    /// @notice The kind of price ladder gating an allocation's milestones.
    enum PriceProgramKind {
        None, // no price milestones
        Absolute, // fixed Q96 thresholds, known at registration
        Relative // multiples of the auction clearing price, resolved at read time
    }

    /// @notice Price ladder supplied alongside a grant. `kind` selects which array applies; the other
    ///         is empty. A relative ladder needs no anchor here: the auction is resolved live from the
    ///         adapter's bound venture at read time (see {effectiveThreshold}).
    struct PriceProgramInput {
        PriceProgramKind kind;
        uint160[] absoluteThresholds; // kind == Absolute (Q96, moneyToken per ventureToken)
        uint256[] multiplesX1e6; // kind == Relative (1e6 scale: 2x == 2_000_000)
        uint48[] cliffs; // optional per-milestone cliff timestamps (unix seconds); 0 = price-only.
        // Either empty (no cliffs) or exactly one entry per milestone.
    }

    /// @notice Emitted when a grant is funded through this adapter (genesis or post-launch).
    event AllocationFunded(
        address indexed controller,
        address indexed allocation,
        address indexed beneficiary,
        address token,
        uint8 allocationType,
        uint256 streamTotal,
        uint256 milestoneAwardTotal
    );

    /// @notice Emitted when a price ladder is registered for an allocation (same tx as funding).
    /// @param programKind 1 = absolute, 2 = relative (None is never emitted).
    /// @param count Number of milestone thresholds/multiples.
    /// @param cliffs Per-milestone cliff timestamps (unix seconds); empty when the program has none.
    event PriceProgramRegistered(
        address indexed allocation, address indexed token, uint8 programKind, uint256 count, uint48[] cliffs
    );

    event Bound(uint256 indexed ventureId, address indexed treasury, address indexed token);

    /// @notice Emitted when the genesis funding window is permanently sealed.
    event GenesisSealed();

    /// @notice Emitted when a grant's vesting is terminated through this adapter.
    /// @param caller The bound treasury (futarchy) or the Hub's vesting admin.
    event GrantTerminated(address indexed allocation, address indexed caller);

    /// @notice Emitted when a terminated grant's clawback is recycled into a replacement grant.
    event GrantReissued(address indexed oldAllocation, address indexed newAllocation, address indexed caller);

    /// @notice Emitted when the venture opts in or out of the Hub vesting-admin path.
    event VestingAdminRevokedSet(bool revoked);

    /// @notice Emitted when idle adapter balance is returned to the venture treasury.
    event Swept(address indexed token, uint256 amount);

    /// @notice Accept the controller's pending-authority role (the controller's two-step handoff).
    function claim() external;

    /// @notice Resolve the venture treasury from the Hub and lock it in (write-once), then grant the
    ///         controller a standing allowance of the venture token so futarchy-funded grants pull.
    /// @param ventureId The Hub venture id this adapter serves.
    function bind(uint256 ventureId) external;

    /// @notice Permanently close the genesis funding window. After this, only `forward` can create
    ///         allocations (post-launch futarchy path).
    function closeGenesis() external;

    /// @notice Fund and create a genesis grant before launch, and register its price ladder atomically.
    /// @param token The venture token funding the grant.
    /// @param amount Tokens to pull from the deployer (stream + milestone awards).
    /// @param createMetavestCalldata ABI-encoded `controller.createMetavest(...)` call data.
    /// @param priceProgram The grant's price ladder (`kind == None` for a grant with no price milestones).
    /// @return allocation The deployed MetaVesT allocation contract.
    function fundGenesisGrant(
        address token,
        uint256 amount,
        bytes calldata createMetavestCalldata,
        PriceProgramInput calldata priceProgram
    ) external returns (address allocation);

    /// @notice Forward an authority call (createMetavest / amend / terminate) to the controller, and
    ///         register the price ladder when the call is `createMetavest`.
    /// @dev Gated to the bound treasury, so only futarchy can drive it. `priceProgram.kind` must be
    ///      `None` for non-`createMetavest` calls.
    function forward(bytes calldata data, PriceProgramInput calldata priceProgram) external returns (bytes memory);

    /// @notice Terminate a grant's vesting. The unvested remainder (stream + unconfirmed milestone
    ///         awards) is returned by MetaVesT to this adapter, from where `sweep` returns it to the
    ///         treasury or `terminateAndReissue` recycles it.
    /// @dev Callable by the bound treasury, or by the Hub's `vestingAdmin` unless this venture has
    ///      revoked that path. Rejected once the venture is liquidating, matching governance.
    ///      Irreversible: MetaVesT rejects a second terminate.
    function terminateGrant(address allocation) external;

    /// @notice Terminate a grant and fund a replacement from its clawback, atomically.
    /// @dev Same auth as {terminateGrant}. Must be one call: split across two transactions, anyone
    ///      could `sweep` the clawback to the treasury in between and strand the reissue.
    ///
    ///      Idle adapter balance is not redirectable, and there is no cap to keep in sync: the
    ///      adapter is flushed to the treasury before the terminate, so the only funds the
    ///      replacement can reach are the ones that termination returned. An oversized replacement
    ///      runs out of balance inside `createMetavest` rather than tripping a check here.
    ///
    ///      A fresh allocation address means the write-once price ladder registers cleanly.
    /// @param allocation The grant to terminate.
    /// @param createMetavestCalldata ABI-encoded `controller.createMetavest(...)` for the replacement.
    /// @param priceProgram The replacement's price ladder (`kind == None` for time-only).
    /// @return newAllocation The replacement MetaVesT allocation contract.
    function terminateAndReissue(
        address allocation,
        bytes calldata createMetavestCalldata,
        PriceProgramInput calldata priceProgram
    ) external returns (address newAllocation);

    /// @notice Return idle adapter balance (terminated clawbacks, over-funding) to the treasury.
    /// @dev Permissionless: the destination is fixed to the bound treasury, so there is nothing to
    ///      steal. Grant-funding proposals move tokens and call `forward` inside a single
    ///      `GovernanceExecutor.executeProposal` transaction, so a sweep cannot be wedged between them.
    function sweep(address token) external;

    /// @notice Opt this venture in or out of the Hub `vestingAdmin` path. Treasury-only (futarchy).
    /// @dev Default is opted in (`false`). Revoking leaves the treasury as the only caller.
    function setVestingAdminRevoked(bool revoked) external;

    function deployer() external view returns (address);
    function hub() external view returns (address);
    function controller() external view returns (address);
    function treasury() external view returns (address);

    /// @notice The venture token this adapter serves, resolved once in {bind}. Zero before then.
    function ventureToken() external view returns (address);
    function bound() external view returns (bool);
    function genesisClosed() external view returns (bool);
    function vestingAdminRevoked() external view returns (bool);

    /// @notice The address that may currently drive {terminateGrant} / {terminateAndReissue}
    ///         alongside the treasury, or `address(0)` when none can: the Hub has it unset, this
    ///         venture revoked the path, the adapter is unbound, or the venture is liquidating.
    /// @dev Named for the same live-resolution convention as {effectiveThreshold} /
    ///      {effectiveCliff}, and deliberately not `vestingAdmin` so it never reads as a mirror of
    ///      the Hub's slot: this answers "can the admin act here", not "what does the Hub store".
    function effectiveVestingAdmin() external view returns (address);

    /// @notice The kind of price program registered for an allocation (`None` if unregistered).
    function priceProgramKind(address allocation) external view returns (PriceProgramKind);

    /// @notice Number of milestones in an allocation's price program (thresholds or multiples).
    function programLength(address allocation) external view returns (uint256);

    /// @notice The stored absolute threshold for an allocation's milestone index (reverts for relative).
    function absoluteThresholdAt(address allocation, uint256 idx) external view returns (uint160);

    /// @notice The stored multiple (1e6 scale) for an allocation's milestone index (reverts for absolute).
    function multipleAt(address allocation, uint256 idx) external view returns (uint256);

    /// @notice The bound venture's auction (the anchor for every relative program), resolved live as
    ///         `venture.lbp().initializer()`. Zero before `bind`.
    function cca() external view returns (address);

    /// @notice The threshold the condition compares the TWAP against: the stored absolute value, or
    ///         `multiple * cca().clearingPrice()` for a relative program (capped at uint160).
    /// @dev Reverts `NotRegistered` when there is no program or `idx` is out of range, `NotBound` when
    ///      the adapter is not yet bound to a venture, and `AuctionNotCleared` when a relative
    ///      program's resolved `clearingPrice()` is 0.
    function effectiveThreshold(address allocation, uint256 idx) external view returns (uint160);

    /// @notice The milestone's cliff timestamp (unix seconds): the condition returns false before it.
    ///         0 when the milestone has no cliff (price-only).
    /// @dev Reverts `NotRegistered` when there is no program or `idx` is out of range. Never needs the
    ///      auction: cliffs are stored verbatim for absolute and relative programs alike.
    function effectiveCliff(address allocation, uint256 idx) external view returns (uint48);
}
