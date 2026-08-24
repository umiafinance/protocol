// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {IUmiaLBP} from "../interfaces/IUmiaLBP.sol";
import {IVentureVestingAuthority} from "../interfaces/IVentureVestingAuthority.sol";

/// @notice Minimal MetaVesT controller surface used for the two-step authority handoff. Declared
///         locally so this adapter carries no AGPL-licensed import (cf. UmiaTwapMilestoneCondition).
interface IMetaVesTController {
    function acceptAuthorityRole() external;
}

/// @notice Minimal MetaVesT allocation read surface for `AllocationFunded` emission (no AGPL import).
interface IMetaVestAllocationView {
    function getVestingType() external view returns (uint256);
    function grantee() external view returns (address);
    function milestoneAwardTotal() external view returns (uint256);
    function getMetavestDetails()
        external
        view
        returns (
            uint256 tokenStreamTotal,
            uint128 vestingCliffCredit,
            uint128 unlockingCliffCredit,
            uint160 vestingRate,
            uint48 vestingStartTime,
            uint160 unlockRate,
            uint48 unlockStartTime,
            address tokenContract
        );
}

/// @notice Minimal CCA surface: a relative ladder anchors to this auction's clearing price.
interface ICCAClearingPrice {
    function clearingPrice() external view returns (uint256);
}

/// @title VentureVestingAuthority
/// @notice Per-venture adapter that holds a MetaVesT controller's `authority` role across the
///         genesis-to-launch gap and then routes it to the venture treasury. The launch operator
///         deploys it pre-launch, hands the controller authority to it before genesis grants, funds
///         each grant via `fundGenesisGrant`, and binds it to the treasury after launch. After
///         `bind`, `forward` is the only mutating path and is gated to the treasury, so only
///         futarchy (a passed market -> GovernanceExecutor -> Venture.executeCall) can create /
///         amend / terminate vesting.
/// @dev This adapter is also the per-allocation price-milestone registry. A grant's price ladder is
///      written here in the same transaction as `createMetavest` (genesis or futarchy), so there is
///      a single mutating path and a single auth gate for grants and ladders. The TWAP condition
///      reads thresholds back via {effectiveThreshold} (allocation -> controller -> authority).
contract VentureVestingAuthority is IVentureVestingAuthority {
    using SafeERC20 for IERC20;

    /// @dev Canonical ABI signature for `metavestController.createMetavest(...)`.
    bytes4 private constant CREATE_METAVEST_SELECTOR = bytes4(
        keccak256(
            "createMetavest(uint8,address,(uint256,uint128,uint128,uint160,uint48,uint160,uint48,address),(uint256,bool,bool,address[])[],uint256,address,uint256,uint256)"
        )
    );

    /// @dev Canonical ABI signature for `metavestController.initiateAuthorityUpdate(address)`. Forwarding
    ///      this would let futarchy move authority off the adapter and break the price-ladder registry.
    bytes4 private constant INITIATE_AUTHORITY_UPDATE_SELECTOR = bytes4(keccak256("initiateAuthorityUpdate(address)"));

    /// @dev Canonical ABI signature for `metavestController.terminateMetavestVesting(address)`.
    bytes4 private constant TERMINATE_VESTING_SELECTOR = bytes4(keccak256("terminateMetavestVesting(address)"));

    /// @dev Fixed-point scale for relative multiples (2x == 2_000_000), matching the grant builder.
    uint256 private constant MULTIPLE_SCALE = 1e6;

    /// @notice A registered price ladder. `kind` selects which array is populated. A relative ladder
    ///         needs no stored anchor: the auction is resolved live from the bound venture at read time.
    ///         `cliffs` is either empty (no cliffs) or one unix timestamp per milestone (0 = price-only).
    struct PriceProgram {
        PriceProgramKind kind;
        uint160[] absoluteThresholds;
        uint256[] multiplesX1e6;
        uint48[] cliffs;
    }

    address public immutable deployer;
    address public immutable hub;
    address public immutable controller;

    address public treasury;

    /// @notice The venture token this adapter serves, resolved once in {bind}. Every grant it funds
    ///         and every clawback it sweeps is denominated in this token.
    address public ventureToken;

    bool public bound;
    bool public genesisClosed;

    /// @notice Whether this venture has opted out of the Hub `vestingAdmin` path (default: opted in).
    bool public vestingAdminRevoked;

    /// @notice Per-allocation price ladder, write-once at grant creation.
    mapping(address allocation => PriceProgram) internal _programs;

    constructor(address _hub, address _controller) {
        if (_hub == address(0) || _controller == address(0)) revert ZeroAddress();
        deployer = msg.sender;
        hub = _hub;
        controller = _controller;
    }

    /// @inheritdoc IVentureVestingAuthority
    function claim() external {
        IMetaVesTController(controller).acceptAuthorityRole();
    }

    /// @inheritdoc IVentureVestingAuthority
    function bind(uint256 ventureId) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (bound) revert AlreadyBound();

        address _treasury = IUmiaHub(hub).ventureById(ventureId).venture;
        if (_treasury == address(0)) revert VentureNotFound();

        treasury = _treasury;
        bound = true;

        address token = IVenture(_treasury).token();
        ventureToken = token;
        IERC20(token).forceApprove(controller, type(uint256).max);

        emit Bound(ventureId, _treasury, token);
    }

    /// @inheritdoc IVentureVestingAuthority
    function closeGenesis() external {
        if (msg.sender != deployer) revert NotDeployer();
        if (genesisClosed) revert GenesisClosed();
        genesisClosed = true;
        emit GenesisSealed();
    }

    /// @inheritdoc IVentureVestingAuthority
    function fundGenesisGrant(
        address token,
        uint256 amount,
        bytes calldata createMetavestCalldata,
        PriceProgramInput calldata priceProgram
    ) external returns (address allocation) {
        if (msg.sender != deployer) revert NotDeployer();
        if (bound) revert AlreadyBound();
        if (genesisClosed) revert GenesisClosed();
        if (!_isCreateMetavest(createMetavestCalldata)) revert NotCreateMetavest();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        // Genesis grants run before `bind` grants the controller its standing allowance, so approve
        // it here for the funded `amount`; `createMetavest` pulls the grant's total from it.
        IERC20(token).forceApprove(controller, amount);
        allocation = _decodeAllocationReturn(_callController(createMetavestCalldata));

        // `createMetavest` pulls the grant total (stream + milestone awards), which may be below the
        // funded `amount`; clear the leftover allowance and return any over-funded remainder so a
        // mismatched `amount` cannot strand tokens or allowance in the adapter.
        IERC20(token).forceApprove(controller, 0);
        uint256 residual = IERC20(token).balanceOf(address(this));
        if (residual != 0) IERC20(token).safeTransfer(deployer, residual);

        address allocationToken = _emitAllocationFunded(allocation);
        _registerPriceProgram(allocation, allocationToken, priceProgram);
        return allocation;
    }

    /// @inheritdoc IVentureVestingAuthority
    function forward(bytes calldata data, PriceProgramInput calldata priceProgram) external returns (bytes memory) {
        if (!bound || msg.sender != treasury) revert NotTreasury();

        bool isCreate = _isCreateMetavest(data);
        // The adapter must keep the controller's authority for the venture's life: the TWAP condition
        // resolves its ladder registry via `controller.authority()`, so moving authority bricks every
        // price milestone. Block the transfer selector even though futarchy is the caller.
        if (data.length >= 4 && bytes4(data[0:4]) == INITIATE_AUTHORITY_UPDATE_SELECTOR) {
            revert AuthorityTransferForbidden();
        }
        // Terminating this way would leave the clawback parked on the adapter. `terminateGrant`
        // accepts the treasury and sweeps, so routing every terminate through it costs nothing.
        if (data.length >= 4 && bytes4(data[0:4]) == TERMINATE_VESTING_SELECTOR) revert UseTerminateGrant();
        // A ladder may only ride a grant-creation call; amend/terminate forward with `kind == None`.
        if (!isCreate && priceProgram.kind != PriceProgramKind.None) revert InvalidPriceProgram();

        bytes memory raw = _callController(data);
        if (isCreate) {
            address allocation = _decodeAllocationReturn(raw);
            address allocationToken = _emitAllocationFunded(allocation);
            _registerPriceProgram(allocation, allocationToken, priceProgram);
        }
        return raw;
    }

    // ─────────────────────────────────────────────────────────
    // Grant administration
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IVentureVestingAuthority
    function effectiveVestingAdmin() public view returns (address) {
        if (!bound || vestingAdminRevoked) return address(0);
        if (IVenture(treasury).liquidationActive()) return address(0);
        return IUmiaHub(hub).vestingAdmin();
    }

    /// @inheritdoc IVentureVestingAuthority
    function setVestingAdminRevoked(bool revoked) external {
        if (!bound || msg.sender != treasury) revert NotTreasury();
        vestingAdminRevoked = revoked;
        emit VestingAdminRevokedSet(revoked);
    }

    /// @inheritdoc IVentureVestingAuthority
    function terminateGrant(address allocation) external {
        _requireVestingAdmin();
        _callController(abi.encodeWithSelector(TERMINATE_VESTING_SELECTOR, allocation));
        emit GrantTerminated(allocation, msg.sender);
        // MetaVesT returns the clawback to the controller's authority, which is this adapter. Send it
        // home in the same call: a clawback left parked here is silently consumed by the next grant.
        _sweep(ventureToken);
    }

    /// @inheritdoc IVentureVestingAuthority
    function terminateAndReissue(
        address allocation,
        bytes calldata createMetavestCalldata,
        PriceProgramInput calldata priceProgram
    ) external returns (address newAllocation) {
        _requireVestingAdmin();
        if (!_isCreateMetavest(createMetavestCalldata)) revert NotCreateMetavest();

        // Flush idle balance first so the only funds the replacement can reach are the ones this
        // termination returns. The cap is then structural: `createMetavest` pulls from this adapter,
        // so it reverts on insufficient balance rather than redirecting anything else.
        _sweep(ventureToken);

        _callController(abi.encodeWithSelector(TERMINATE_VESTING_SELECTOR, allocation));
        newAllocation = _decodeAllocationReturn(_callController(createMetavestCalldata));

        // Structurally the controller can only pull `ventureToken` (it is the sole standing allowance
        // `bind` grants), but assert it here so the invariant is this contract's, not a vendored
        // dependency's, and so `GrantReissued` provably describes a clawback-funded replacement.
        address newToken = _emitAllocationFunded(newAllocation);
        if (newToken != ventureToken) revert ReissueTokenMismatch();

        _registerPriceProgram(newAllocation, newToken, priceProgram);
        emit GrantReissued(allocation, newAllocation, msg.sender);
        _sweep(ventureToken);
    }

    /// @inheritdoc IVentureVestingAuthority
    function sweep(address token) external {
        if (!bound) revert NotBound();
        _sweep(token);
    }

    /// @dev Move any idle balance of `token` to the treasury. No-op at zero so callers can flush
    ///      unconditionally.
    function _sweep(address token) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        IERC20(token).safeTransfer(treasury, balance);
        emit Swept(token, balance);
    }

    /// @dev The treasury always qualifies; the Hub's vesting admin qualifies unless this venture
    ///      revoked the path or the Hub has it unset.
    function _requireVestingAdmin() internal view {
        if (!bound) revert NotBound();
        // Liquidation snapshots total supply and pays out pro-rata against it, so grant mutation has
        // to stop at the same point governance does (`GovernanceExecutor.executeProposal`, and
        // `Venture.executeCall`'s `whenNotLiquidating`). Applies to the treasury too, for symmetry.
        if (IVenture(treasury).liquidationActive()) revert LiquidationActive();
        if (msg.sender == treasury) return;
        address admin = effectiveVestingAdmin();
        if (admin == address(0) || msg.sender != admin) revert NotAuthorized();
    }

    // ─────────────────────────────────────────────────────────
    // Price program registry
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IVentureVestingAuthority
    function priceProgramKind(address allocation) external view returns (PriceProgramKind) {
        return _programs[allocation].kind;
    }

    /// @inheritdoc IVentureVestingAuthority
    function programLength(address allocation) external view returns (uint256) {
        return _programLength(_programs[allocation]);
    }

    /// @inheritdoc IVentureVestingAuthority
    function absoluteThresholdAt(address allocation, uint256 idx) external view returns (uint160) {
        PriceProgram storage p = _programs[allocation];
        if (p.kind != PriceProgramKind.Absolute || idx >= p.absoluteThresholds.length) revert NotRegistered();
        return p.absoluteThresholds[idx];
    }

    /// @inheritdoc IVentureVestingAuthority
    function multipleAt(address allocation, uint256 idx) external view returns (uint256) {
        PriceProgram storage p = _programs[allocation];
        if (p.kind != PriceProgramKind.Relative || idx >= p.multiplesX1e6.length) revert NotRegistered();
        return p.multiplesX1e6[idx];
    }

    /// @inheritdoc IVentureVestingAuthority
    function cca() public view returns (address) {
        if (treasury == address(0)) return address(0);
        return address(IUmiaLBP(IVenture(treasury).lbp()).initializer());
    }

    /// @inheritdoc IVentureVestingAuthority
    function effectiveThreshold(address allocation, uint256 idx) external view returns (uint160) {
        PriceProgram storage p = _programs[allocation];
        if (p.kind == PriceProgramKind.Absolute) {
            if (idx >= p.absoluteThresholds.length) revert NotRegistered();
            return p.absoluteThresholds[idx];
        }
        if (p.kind == PriceProgramKind.Relative) {
            if (idx >= p.multiplesX1e6.length) revert NotRegistered();
            // Resolve the venture's auction live (the adapter serves exactly one venture). Unbound is
            // NotBound; bound-but-unresolved or a 0 clearing price is AuctionNotCleared.
            if (treasury == address(0)) revert NotBound();
            address auction = cca();
            if (auction == address(0)) revert AuctionNotCleared();
            uint256 clearingPrice = ICCAClearingPrice(auction).clearingPrice();
            if (clearingPrice == 0) revert AuctionNotCleared();
            // threshold = multiple * clearingPrice, capped at the uint160 ceiling. Ascending
            // multiples (enforced at registration) give ascending thresholds for a fixed price.
            uint256 scaled = FullMath.mulDiv(p.multiplesX1e6[idx], clearingPrice, MULTIPLE_SCALE);
            return scaled > type(uint160).max ? type(uint160).max : uint160(scaled);
        }
        revert NotRegistered();
    }

    /// @inheritdoc IVentureVestingAuthority
    function effectiveCliff(address allocation, uint256 idx) external view returns (uint48) {
        PriceProgram storage p = _programs[allocation];
        if (p.kind == PriceProgramKind.None || idx >= _programLength(p)) revert NotRegistered();
        return p.cliffs.length == 0 ? 0 : p.cliffs[idx];
    }

    /// @dev Milestone count of a program: the populated array for its kind.
    function _programLength(PriceProgram storage p) internal view returns (uint256) {
        return p.kind == PriceProgramKind.Relative ? p.multiplesX1e6.length : p.absoluteThresholds.length;
    }

    /// @dev Write-once price ladder for an allocation, validated and stored in the funding tx. A
    ///      `None` input must carry no data and is a no-op (the grant simply has no price milestones);
    ///      arrays alongside `kind == None` signal a mis-built input, so fail fast rather than
    ///      silently ignore them. `token` is resolved by the caller from the same
    ///      `getMetavestDetails()` read used for the funding event.
    function _registerPriceProgram(address allocation, address token, PriceProgramInput calldata input) internal {
        if (input.kind == PriceProgramKind.None) {
            if (input.absoluteThresholds.length != 0 || input.multiplesX1e6.length != 0 || input.cliffs.length != 0) {
                revert InvalidPriceProgram();
            }
            return;
        }
        PriceProgram storage p = _programs[allocation];
        if (p.kind != PriceProgramKind.None) revert ProgramAlreadyRegistered();

        uint256 count;
        if (input.kind == PriceProgramKind.Absolute) {
            count = input.absoluteThresholds.length;
            if (count == 0) revert EmptyThresholds();
            uint160 prev;
            for (uint256 i; i < count; i++) {
                uint160 t = input.absoluteThresholds[i];
                if (t == 0) revert ZeroThreshold();
                if (i > 0 && t <= prev) revert ThresholdsNotAscending();
                prev = t;
                p.absoluteThresholds.push(t);
            }
            p.kind = PriceProgramKind.Absolute;
        } else if (input.kind == PriceProgramKind.Relative) {
            count = input.multiplesX1e6.length;
            if (count == 0) revert EmptyThresholds();
            uint256 prev;
            for (uint256 i; i < count; i++) {
                uint256 m = input.multiplesX1e6[i];
                if (m == 0) revert ZeroThreshold();
                if (i > 0 && m <= prev) revert ThresholdsNotAscending();
                prev = m;
                p.multiplesX1e6.push(m);
            }
            p.kind = PriceProgramKind.Relative;
        } else {
            revert InvalidPriceProgram();
        }

        uint256 cliffCount = input.cliffs.length;
        if (cliffCount != 0) {
            if (cliffCount != count) revert CliffsLengthMismatch();
            for (uint256 i; i < cliffCount; i++) {
                p.cliffs.push(input.cliffs[i]);
            }
        }

        emit PriceProgramRegistered(allocation, token, uint8(input.kind), count, input.cliffs);
    }

    /// @dev Forward a call to the controller, bubbling its revert reason on failure.
    function _callController(bytes memory data) internal returns (bytes memory raw) {
        bool ok;
        (ok, raw) = controller.call(data);
        if (!ok) {
            assembly {
                revert(add(raw, 0x20), mload(raw))
            }
        }
    }

    /// @dev Decode + validate a `createMetavest` return as a non-zero allocation address. A malformed
    ///      return must revert rather than yield address(0): AllocationFunded is the indexer's only
    ///      discovery signal, so a bad allocation would create an onchain grant that's never indexed.
    function _decodeAllocationReturn(bytes memory raw) internal pure returns (address allocation) {
        if (raw.length < 32) revert InvalidControllerReturn();
        allocation = abi.decode(raw, (address));
        if (allocation == address(0)) revert InvalidControllerReturn();
    }

    function _isCreateMetavest(bytes calldata data) internal pure returns (bool) {
        return data.length >= 4 && bytes4(data[0:4]) == CREATE_METAVEST_SELECTOR;
    }

    /// @dev Reads `getMetavestDetails()` once and returns the allocation's token so the caller can
    ///      pass it to `_registerPriceProgram` without a second staticcall + positional decode.
    function _emitAllocationFunded(address allocation) internal returns (address token) {
        IMetaVestAllocationView alloc = IMetaVestAllocationView(allocation);
        uint256 streamTotal;
        (streamTotal,,,,,,, token) = alloc.getMetavestDetails();
        emit AllocationFunded(
            controller,
            allocation,
            alloc.grantee(),
            token,
            uint8(alloc.getVestingType()),
            streamTotal,
            alloc.milestoneAwardTotal()
        );
    }
}
