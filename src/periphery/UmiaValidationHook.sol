// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {
    ValidationHookIntrospection
} from "@continuous-clearing-auction/periphery/validationHooks/ValidationHookIntrospection.sol";
import {IValidationHook} from "@continuous-clearing-auction/interfaces/IValidationHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IGatedValidationHook} from "../interfaces/IGatedValidationHook.sol";
import {IMaxBidPriceValidationHook} from "../interfaces/IMaxBidPriceValidationHook.sol";
import {IUmiaValidationHook} from "../interfaces/IUmiaValidationHook.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {BlockNumberish} from "@blocknumberish/src/BlockNumberish.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {IContinuousClearingAuction} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ITickStorage} from "@continuous-clearing-auction/interfaces/ITickStorage.sol";
import {IStepStorage} from "@continuous-clearing-auction/interfaces/IStepStorage.sol";
import {AuctionStep} from "@continuous-clearing-auction/libraries/StepLib.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Reclaim} from "../reclaim/Reclaim.sol";
import {Claims} from "../reclaim/Claims.sol";
import {StringUtils} from "../reclaim/StringUtils.sol";

/// @title UmiaValidationHook
/// @notice CCA validation hook that restricts bidding to verified users.
///
/// Supports three verification flows:
///   1. Pre-verification (zkTLS): Proof submitted via submitProof(), user bids later.
///   2. Inline verification (zkTLS): User passes proof in hookData during bid submission.
///   3. Server permit (EIP-712): Server signs a single-use permit for
///      (wallet, step, nonce, deadline, amount), submitted inline in hookData
///      on every bid. Each permit is consumed on use.
///
/// All submission functions are permissionless — the proof or signature IS the authorization.
///
/// Registration is monotonic: a user verified at step N is eligible for
/// steps N, N+1, N+2, ... This models tiered access where earlier tiers
/// are supersets of later tiers.
///
/// Lifecycle:
///   1. Deploy with owner, Reclaim verifier, and initial signer addresses.
///   2. Create the CCA with this hook as its validationHook, then call setCCA() once to
///      pair with it — step ranges are cached locally.
///   3. Admin enables specific steps for verification enforcement (default: off).
///   4. Users get verified via submitProof() or inline proof/permit during validate().
///      zkTLS proofs persist verification; server permits are single-use per bid.
///   5. On every bid, validate() resolves the current step and checks eligibility.
///      Disabled steps and blocks outside all steps allow anyone.
contract UmiaValidationHook is IUmiaValidationHook, ValidationHookIntrospection, Ownable, BlockNumberish {
    // ─────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 public constant SERVER_PERMIT_TYPEHASH =
        keccak256("ServerPermit(address wallet,uint256 step,bytes32 nonce,uint256 deadline,uint128 amount)");

    // ─────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────

    /// @notice EIP-712 domain separator (bound to contract address and chain ID)
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice The Reclaim verifier contract
    Reclaim public immutable reclaim;

    // ─────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────

    /// @notice The paired CCA contract address (set once via setCCA)
    address private _cca;

    /// @notice Cached step ranges parsed from the CCA's SSTORE2 data
    BlockRange[] private _steps;

    /// @notice Bitmap: bit i set means step i enforces verification
    uint256 private _stepEnabledBitmap;

    /// @notice Per-user verification: stores stepIndex + 1 (0 = not verified).
    ///         A user with value N is eligible for steps N-1, N, N+1, ...
    mapping(address user => uint256) private _verifiedFromStep;

    /// @notice Reverse lookup: startBlock -> step index + 1 (0 = not found)
    mapping(uint64 stepStart => uint256) private _stepStartToIndex;

    /// @notice Required provider hashes for each step (empty = zkTLS proofs rejected)
    mapping(uint256 stepIndex => bytes32[]) private _stepProviderHashes;

    /// @notice Authorized server permit signer (address(0) = disabled)
    address private _signer;

    /// @notice Bitmap: bit i set means step i accepts server-permit verification
    uint256 private _stepPermitEnabledBitmap;

    /// @notice Maximum allowed bid price in Q96 format (0 = no cap)
    uint256 private _maxBidPrice;

    /// @notice Per-step cumulative cap for zkTLS-authorized bids, in money-token base units
    ///         (0 = no cap at that step). 0-indexed step. Independent of the server-permit cap.
    mapping(uint256 stepIndex => uint256) private _stepMaxBidAmount;

    /// @notice Cumulative zkTLS bid amount per (owner, stepIndex), in money-token base units.
    ///         Gross cumulative submitted — refunds/cancellations are not credited back (v1).
    mapping(address owner => mapping(uint256 stepIndex => uint256)) private _zkBidTotal;

    /// @notice Auction-wide cumulative cap for zkTLS-authorized bid volume across all wallets
    ///         and steps, in money-token base units (0 = no cap). Server permits are excluded.
    uint256 private _zkGlobalMaxBidAmount;

    /// @notice Cumulative zkTLS bid volume across all wallets and steps, in money-token base
    ///         units. Gross and monotonic: accrues even while uncapped (so a cap set
    ///         mid-auction counts volume already landed) and refunds are not credited back.
    uint256 private _zkGlobalBidTotal;

    /// @notice OPRF-based sybil gate: providerHash => identityHash => owning user.
    ///         identityHash = keccak256(abi.encodePacked(providerHash, extractedParameters_substring))
    ///         where the substring is grabbed verbatim from the signed proof context.
    ///         Same real-world account → same identityHash → can only register one wallet.
    mapping(bytes32 => mapping(bytes32 => address)) private _identityToUser;

    /// @notice Single-use permit nonces. Once a server permit is consumed in a bid,
    ///         its nonce is burned and the signature cannot be replayed.
    mapping(bytes32 nonce => bool) private _usedPermits;

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error NotVerified(address user);
    error SenderNotBidOwner();
    error CallerNotCCA();
    error ZeroAddress();
    error StepIndexOutOfBounds(uint256 stepIndex);
    error NoCCA();
    error InvalidStepData();
    error TooManySteps();
    error ContextAddressMismatch(address expected, address actual);
    error ArrayLengthMismatch();
    error ProviderHashMismatch(bytes32 expected, bytes32 actual);
    error ProviderNotFound(uint256 stepIndex, bytes32 providerHash);
    error ProofStepTooHigh(uint256 proofStep, uint256 currentStep);
    error PermitStepTooHigh(uint256 permitStep, uint256 currentStep);
    error ServerPermitNotEnabled(uint256 stepIndex);
    error ServerPermitRequired(uint256 stepIndex);
    error ProofRequired(uint256 stepIndex);
    error SignerNotSet();
    error ExpiredDeadline();
    error InvalidSignature();
    error MaxBidPriceExceeded();
    error PriceNotAlignedToTick();
    error IdentityAlreadyClaimed(bytes32 providerHash, bytes32 identityHash, address existingUser);
    error PermitAlreadyUsed(bytes32 nonce);
    error ZkBidExceedsStepCap(address owner, uint256 stepIndex, uint256 attempted, uint256 cap);
    error ZkBidExceedsGlobalCap(address owner, uint256 attempted, uint256 cap);

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event CCASet(address indexed cca);
    event StepEnabled(uint256 indexed stepIndex);
    event StepDisabled(uint256 indexed stepIndex);
    event StepProviderSet(uint256 indexed stepIndex, bytes32 providerHash, string providerId);
    event StepProviderRemoved(uint256 indexed stepIndex, bytes32 providerHash);
    event Registered(uint256 indexed stepIndex, address indexed user);
    event Unregistered(address indexed user);
    event ProofVerified(address indexed user, uint256 indexed stepIndex, bytes32 indexed proofIdentifier);
    event SignerSet(address indexed oldSigner, address indexed newSigner);
    event StepPermitEnabled(uint256 indexed stepIndex);
    event StepPermitDisabled(uint256 indexed stepIndex);
    event MaxBidPriceSet(uint256 maxBidPrice);
    event StepMaxBidAmountSet(uint256 indexed stepIndex, uint256 amount);
    event ZkGlobalMaxBidAmountSet(uint256 amount);
    event ZkGlobalBidAccrued(address indexed owner, uint256 amount, uint256 newTotal);
    event IdentityClaimed(
        address indexed user, bytes32 indexed providerHash, bytes32 indexed identityHash, uint256 stepIndex
    );
    event IdentityCleared(bytes32 indexed providerHash, bytes32 indexed identityHash);
    event PermitConsumed(address indexed user, uint256 indexed stepIndex, bytes32 indexed nonce);

    constructor(address _owner, address _reclaim, address signer_) {
        _initializeOwner(_owner);
        reclaim = Reclaim(_reclaim);
        _signer = signer_;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("UmiaValidationHook"), keccak256("1"), block.chainid, address(this))
        );
    }

    // ─────────────────────────────────────────────────────────
    // Validation
    // ─────────────────────────────────────────────────────────

    /// @notice Called by the CCA on every bid submission. Resolves the current step
    ///         (handling stale CCA cache at boundaries), then enforces verification
    ///         if the step is enabled. Disabled steps and blocks outside all steps pass.
    /// @dev Supports three flows:
    ///      1. Pre-verification: User already has valid proof stored via submitProof().
    ///      2. Inline zkTLS: hookData = abi.encodePacked(uint256 proofStep, abi.encode(Reclaim.Proof)).
    ///         The proofStep is the 0-indexed step the proof targets. The contract verifies
    ///         proofStep <= currentStep (monotonic) and checks the proof against proofStep's providers.
    ///      3. Inline server permit: hookData starts with 0x01, followed by
    ///         abi.encode(uint256 permitStep, bytes32 nonce, uint256 deadline, bytes signature).
    ///         The permitStep must be <= the current step (monotonic). The permit
    ///         is verified against permitStep's permit-enabled bitmap and the bid's
    ///         amount (the signature covers it, so a permit only authorizes the exact
    ///         amount the server approved), and the nonce is burned on consumption —
    ///         every bid requires a fresh server-signed permit.
    ///      Reverts with ServerPermitRequired / ProofRequired when the step's required
    ///      credential is absent or malformed (wrong kind or truncated), or NotVerified when a
    ///      step gated by both a permit and a proof is given empty hookData. A well-formed but
    ///      invalid credential reverts with a specific error (e.g. InvalidSignature,
    ///      ExpiredDeadline, ProviderHashMismatch).
    /// @dev Callable only by the paired CCA; reverts CallerNotCCA otherwise. This is required
    ///      because validate() mutates cumulative bid state (_zkBidTotal, _zkGlobalBidTotal); a
    ///      permissionless entry point would let anyone inflate those totals and DoS zk-path bids.
    /// @inheritdoc IValidationHook
    function validate(uint256 maxPrice, uint128 amount, address owner, address sender, bytes calldata hookData)
        external
    {
        if (_cca == address(0)) return;
        if (msg.sender != _cca) revert CallerNotCCA();
        if (sender != owner) revert SenderNotBidOwner();
        if (_maxBidPrice != 0 && maxPrice > _maxBidPrice) revert MaxBidPriceExceeded();

        uint256 rawStep = _resolveStepIndex();
        if (rawStep == 0) return;
        uint256 stepIndex = rawStep - 1;
        if ((_stepEnabledBitmap & (1 << stepIndex)) == 0) return;

        uint256 verifiedFrom = _verifiedFromStep[owner];
        if (verifiedFrom != 0 && verifiedFrom <= rawStep) {
            _enforceZkCaps(owner, stepIndex, amount);
            return;
        }

        // Nothing configured = nothing gates the step, so the bid passes. A permit-enabled
        // step still needs its permit; a zkTLS proof would revert below.
        (bool hasProofGate, bool hasPermitGate) = _stepGateKinds(stepIndex);
        if (!hasProofGate && !hasPermitGate) return;

        // The step's gate config decides which credential is required; the caller's type
        // byte only picks when BOTH gates are configured. A missing, wrong-kind, or
        // truncated payload is rejected with that gate's own error rather than an opaque
        // panic or the other gate's error.
        if (hookData.length == 0) {
            if (hasPermitGate && !hasProofGate) revert ServerPermitRequired(stepIndex);
            if (hasProofGate && !hasPermitGate) revert ProofRequired(stepIndex);
            revert NotVerified(owner);
        }

        bool suppliedPermit = hookData[0] == 0x01;

        if (hasPermitGate && (!hasProofGate || suppliedPermit)) {
            // Permit payload is 0x01 || abi.encode(uint256, bytes32, uint256, bytes). Validate the
            // full ABI envelope before decoding so a malformed payload reverts ServerPermitRequired
            // rather than an opaque abi.decode error: the four-word head plus the signature length
            // word need 161 bytes, the bytes offset must be canonical (0x80), and the declared
            // signature tail must fit.
            if (!suppliedPermit || hookData.length < 161) revert ServerPermitRequired(stepIndex);
            bytes calldata permitData = hookData[1:];
            uint256 sigLen = uint256(bytes32(permitData[128:160]));
            // Bound sigLen by the bytes actually present before the padding math, so a hostile
            // length word reverts ServerPermitRequired rather than an arithmetic-overflow panic.
            if (
                uint256(bytes32(permitData[96:128])) != 0x80 || sigLen > permitData.length
                    || permitData.length < 160 + ((sigLen + 31) / 32) * 32
            ) {
                revert ServerPermitRequired(stepIndex);
            }
            (uint256 permitStep, bytes32 nonce, uint256 deadline, bytes memory signature) =
                abi.decode(permitData, (uint256, bytes32, uint256, bytes));
            if (permitStep > stepIndex) revert PermitStepTooHigh(permitStep, stepIndex);
            _verifyAndConsumeServerPermit(owner, permitStep, nonce, deadline, amount, signature);
        } else {
            // Proof payload is abi.encodePacked(uint256 proofStep, Reclaim.Proof); require the
            // leading proofStep word so the slices below can't panic on a short payload.
            if (suppliedPermit || hookData.length < 32) revert ProofRequired(stepIndex);
            uint256 proofStep = uint256(bytes32(hookData[:32]));
            if (proofStep > stepIndex) revert ProofStepTooHigh(proofStep, stepIndex);
            _verifyAndStoreProof(owner, proofStep, hookData[32:]);
            _enforceZkCaps(owner, stepIndex, amount);
        }
    }

    /// @dev Enforces both zkTLS bid caps for a zk-path bid: the auction-wide cap, then the
    ///      per-(owner, step) cap. Server-permit bids never reach this.
    function _enforceZkCaps(address owner, uint256 stepIndex, uint128 amount) internal {
        _enforceZkGlobalCap(owner, amount);
        _enforceZkStepCap(owner, stepIndex, amount);
    }

    /// @dev Enforces the auction-wide cumulative zkTLS cap. Unlike the per-step cap, the
    ///      total accrues even while uncapped, so a cap set mid-auction counts volume already
    ///      landed. Every accrual is emitted with the new total: the indexer copies it into
    ///      its display state verbatim rather than re-deriving the zk path off-chain.
    function _enforceZkGlobalCap(address owner, uint128 amount) internal {
        uint256 next = _zkGlobalBidTotal + amount;
        uint256 cap = _zkGlobalMaxBidAmount;
        if (cap != 0 && next > cap) revert ZkBidExceedsGlobalCap(owner, next, cap);
        _zkGlobalBidTotal = next;
        emit ZkGlobalBidAccrued(owner, amount, next);
    }

    /// @dev Enforces the per-step cumulative zkTLS bid cap. No-op when the step has no cap (0).
    ///      Reverts ZkBidExceedsStepCap when this bid would push the owner's cumulative total
    ///      at this step over the cap; otherwise accrues the amount into _zkBidTotal.
    function _enforceZkStepCap(address owner, uint256 stepIndex, uint128 amount) internal {
        uint256 cap = _stepMaxBidAmount[stepIndex];
        if (cap == 0) return;
        uint256 next = _zkBidTotal[owner][stepIndex] + amount;
        if (next > cap) revert ZkBidExceedsStepCap(owner, stepIndex, next, cap);
        _zkBidTotal[owner][stepIndex] = next;
    }

    // ─────────────────────────────────────────────────────────
    // Proof Submission (Permissionless)
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IUmiaValidationHook
    function submitProof(address user, uint256 stepIndex, bytes calldata proofData) external {
        if (_steps.length == 0) revert NoCCA();
        if (stepIndex >= _steps.length) revert StepIndexOutOfBounds(stepIndex);
        if (user == address(0)) revert ZeroAddress();

        _verifyAndStoreProof(user, stepIndex, proofData);
    }

    /// @inheritdoc IUmiaValidationHook
    function submitProofBatch(address[] calldata users, uint256 stepIndex, bytes[] calldata proofDataArray) external {
        if (_steps.length == 0) revert NoCCA();
        if (stepIndex >= _steps.length) revert StepIndexOutOfBounds(stepIndex);
        if (users.length != proofDataArray.length) revert ArrayLengthMismatch();

        for (uint256 i; i < users.length;) {
            if (users[i] == address(0)) revert ZeroAddress();
            _verifyAndStoreProof(users[i], stepIndex, proofDataArray[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Verifies proof with Reclaim and stores verification status
    function _verifyAndStoreProof(address user, uint256 stepIndex, bytes calldata proofData) internal {
        Reclaim.Proof memory proof = abi.decode(proofData, (Reclaim.Proof));

        string memory contextAddress = Claims.extractFieldFromContext(proof.claimInfo.context, '"contextAddress":"');
        address proofUser = StringUtils.str2address(contextAddress);
        if (proofUser != user) revert ContextAddressMismatch(user, proofUser);

        bytes32[] memory requiredProviders = _stepProviderHashes[stepIndex];
        if (requiredProviders.length == 0) revert ProviderNotFound(stepIndex, bytes32(0));

        string memory providerHashStr = Claims.extractFieldFromContext(proof.claimInfo.context, '"providerHash":"');
        bytes32 proofProvider = StringUtils.str2bytes32(providerHashStr);
        bool found;
        for (uint256 i; i < requiredProviders.length;) {
            if (proofProvider == requiredProviders[i]) {
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        if (!found) revert ProviderHashMismatch(requiredProviders[0], proofProvider);

        // OPRF sybil gate: bind one OPRF identity to one user. The substring is hashed verbatim
        // out of the signed context — same bytes off-chain and onchain — so identityHash is
        // deterministic across submissions. If extractedParameters is absent (provider spec
        // misconfigured), skip the gate rather than DoSing the auction.
        bytes memory paramsBytes =
            Claims.extractJsonObjectFromContext(proof.claimInfo.context, '"extractedParameters":');
        if (paramsBytes.length > 0) {
            bytes32 identityHash = keccak256(abi.encodePacked(proofProvider, paramsBytes));
            address existingOwner = _identityToUser[proofProvider][identityHash];
            if (existingOwner == address(0)) {
                _identityToUser[proofProvider][identityHash] = user;
                emit IdentityClaimed(user, proofProvider, identityHash, stepIndex);
            } else if (existingOwner != user) {
                revert IdentityAlreadyClaimed(proofProvider, identityHash, existingOwner);
            }
            // existingOwner == user → idempotent re-verify, no-op.
        }

        reclaim.verifyProof(proof);

        uint256 newValue = stepIndex + 1;
        uint256 existing = _verifiedFromStep[user];
        if (existing == 0 || newValue < existing) {
            _verifiedFromStep[user] = newValue;
        }

        emit Registered(stepIndex, user);
        emit ProofVerified(user, stepIndex, proof.signedClaim.claim.identifier);
    }

    // ─────────────────────────────────────────────────────────
    // Registration Management
    // ─────────────────────────────────────────────────────────

    /// @notice Remove a user's verification status entirely
    /// @param _user The user address to unregister
    function unregister(address _user) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        _verifiedFromStep[_user] = 0;
        emit Unregistered(_user);
    }

    /// @notice Remove multiple users' verification status entirely
    /// @param _users Array of user addresses to unregister
    function unregisterBatch(address[] calldata _users) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        for (uint256 i; i < _users.length;) {
            _verifiedFromStep[_users[i]] = 0;
            emit Unregistered(_users[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Free an identity slot so it can be re-claimed by another wallet.
    /// @dev `unregister` does NOT auto-clear identity slots — call this in addition
    ///      when a user needs to fully release their (provider, identity) pair so
    ///      the same OPRF identity can register a new wallet. Off-chain tooling can
    ///      look up the params from `proof_submissions.identity_hash`.
    /// @param providerHash The provider hash the identity was registered under.
    /// @param identityHash The identity hash to clear.
    function clearIdentity(bytes32 providerHash, bytes32 identityHash) external onlyOwner {
        delete _identityToUser[providerHash][identityHash];
        emit IdentityCleared(providerHash, identityHash);
    }

    /// @inheritdoc IUmiaValidationHook
    function identityOwner(bytes32 providerHash, bytes32 identityHash) external view returns (address) {
        return _identityToUser[providerHash][identityHash];
    }

    // ─────────────────────────────────────────────────────────
    // Server Permit
    // ─────────────────────────────────────────────────────────

    /// @notice Update the authorized signer. Can be set to address(0) to disable.
    /// @param newSigner The new signer address
    function setSigner(address newSigner) external onlyOwner {
        address old = _signer;
        _signer = newSigner;
        emit SignerSet(old, newSigner);
    }

    /// @notice Enable server-permit verification for a step
    /// @param _stepIndex The step to enable server-permit for
    function enableStepPermit(uint256 _stepIndex) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndex >= _steps.length) revert StepIndexOutOfBounds(_stepIndex);
        _stepPermitEnabledBitmap |= (1 << _stepIndex);
        emit StepPermitEnabled(_stepIndex);
    }

    /// @notice Disable server-permit verification for a step
    /// @param _stepIndex The step to disable server-permit for
    function disableStepPermit(uint256 _stepIndex) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndex >= _steps.length) revert StepIndexOutOfBounds(_stepIndex);
        _stepPermitEnabledBitmap &= ~(1 << _stepIndex);
        emit StepPermitDisabled(_stepIndex);
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price
    // ─────────────────────────────────────────────────────────

    /// @notice Set the maximum allowed bid price. Bids with a higher maxPrice will be rejected.
    /// @param maxBidPrice_ The maximum allowed price in Q96 format. Set to 0 to remove the cap.
    function setMaxBidPrice(uint256 maxBidPrice_) external onlyOwner {
        if (_cca == address(0)) revert NoCCA();
        if (maxBidPrice_ != 0) {
            uint256 floorPrice = ITickStorage(_cca).floorPrice();
            uint256 tickSpacing = ITickStorage(_cca).tickSpacing();
            if (maxBidPrice_ < floorPrice || (maxBidPrice_ - floorPrice) % tickSpacing != 0) {
                revert PriceNotAlignedToTick();
            }
        }
        _maxBidPrice = maxBidPrice_;
        emit MaxBidPriceSet(maxBidPrice_);
    }

    /// @notice Set the per-step cumulative cap for zkTLS-authorized bids.
    /// @dev Independent of the server-permit cap. Unlike the permit cap, 0 means "no cap"
    ///      at that step (not "blocked") — to block a wallet, simply do not authorize it.
    /// @param stepIndex The 0-indexed step to configure
    /// @param amount The cumulative cap in money-token base units. Set to 0 to remove the cap.
    function setStepMaxBidAmount(uint256 stepIndex, uint256 amount) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        if (stepIndex >= _steps.length) revert StepIndexOutOfBounds(stepIndex);
        _stepMaxBidAmount[stepIndex] = amount;
        emit StepMaxBidAmountSet(stepIndex, amount);
    }

    /// @notice Set the auction-wide cumulative cap for zkTLS-authorized bid volume.
    /// @dev Applies across all wallets and steps on the zk path; server-permit bids are
    ///      excluded. The running total accrues from the first zk bid regardless of the cap,
    ///      so a cap set mid-auction counts volume already landed. Settable before setCCA.
    /// @param amount The cumulative cap in money-token base units. Set to 0 to remove the cap.
    function setZkGlobalMaxBidAmount(uint256 amount) external onlyOwner {
        _zkGlobalMaxBidAmount = amount;
        emit ZkGlobalMaxBidAmountSet(amount);
    }

    /// @dev Verifies an EIP-712 server permit, burns its nonce, and authorizes a single bid.
    ///      The signature is bound to the bid amount, so a permit obtained for a small
    ///      server-approved amount cannot authorize a larger bid. Does NOT update
    ///      _verifiedFromStep — every bid requires a fresh permit by design, because the
    ///      off-chain signer is the source of truth for per-wallet bid caps.
    function _verifyAndConsumeServerPermit(
        address user,
        uint256 stepIndex,
        bytes32 nonce,
        uint256 deadline,
        uint128 amount,
        bytes memory signature
    ) internal {
        if ((_stepPermitEnabledBitmap & (1 << stepIndex)) == 0) {
            revert ServerPermitNotEnabled(stepIndex);
        }
        if (_signer == address(0)) revert SignerNotSet();
        if (block.timestamp > deadline) revert ExpiredDeadline();
        if (_usedPermits[nonce]) revert PermitAlreadyUsed(nonce);

        bytes32 structHash = keccak256(abi.encode(SERVER_PERMIT_TYPEHASH, user, stepIndex, nonce, deadline, amount));
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);

        // tryRecover (not recover) so a wrong-length or malleable signature reverts this hook's
        // InvalidSignature rather than OpenZeppelin's own ECDSA error.
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != _signer) revert InvalidSignature();

        _usedPermits[nonce] = true;

        emit PermitConsumed(user, stepIndex, nonce);
    }

    /// @inheritdoc IUmiaValidationHook
    function isPermitNonceUsed(bytes32 nonce) external view returns (bool) {
        return _usedPermits[nonce];
    }

    // ─────────────────────────────────────────────────────────
    // CCA Configuration
    // ─────────────────────────────────────────────────────────

    /// @notice Pair this hook with a CCA contract. Reads the CCA's SSTORE2 step data
    ///         and caches all step ranges locally. Idempotent: no-op if already configured.
    /// @dev Parses packed step data (8 bytes per step: 3B mps + 5B blockDelta). Reverts if
    ///      data is empty, not aligned to 8 bytes, has zero-length steps, or exceeds 256 steps.
    /// @param _newCCA The CCA contract address to read steps from
    function setCCA(address _newCCA) external onlyOwner {
        if (_newCCA == address(0)) revert ZeroAddress();
        if (_cca != address(0)) return;

        _cca = _newCCA;
        _cacheStepsFromCCA(_newCCA);

        emit CCASet(_newCCA);
    }

    /// @dev Reads packed step data from the CCA's SSTORE2 storage and caches
    ///      each step's block range for O(1) lookups during validation.
    function _cacheStepsFromCCA(address _newCCA) internal {
        bytes memory packedSteps = SSTORE2.read(IStepStorage(_newCCA).pointer());
        uint64 cursor = IContinuousClearingAuction(_newCCA).startBlock();

        _validatePackedStepData(packedSteps);

        uint256 stepCount;
        for (uint256 offset; offset < packedSteps.length;) {
            if (stepCount >= 256) revert TooManySteps();

            uint40 blockDelta = _extractBlockDelta(packedSteps, offset);
            if (blockDelta == 0) revert InvalidStepData();

            uint64 stepEnd = cursor + uint64(blockDelta);
            _cacheStep(stepCount, cursor, stepEnd);

            cursor = stepEnd;
            unchecked {
                offset += 8;
                ++stepCount;
            }
        }
    }

    /// @dev Validates that packed step data is non-empty and properly aligned.
    ///      Each step is 8 bytes: 3B minPriceStep (unused here) + 5B blockDelta.
    function _validatePackedStepData(bytes memory packedSteps) internal pure {
        if (packedSteps.length == 0 || packedSteps.length % 8 != 0) {
            revert InvalidStepData();
        }
    }

    /// @dev Extracts the 5-byte blockDelta from an 8-byte packed step entry.
    ///      Layout: [3 bytes mps][5 bytes blockDelta] — we only need blockDelta.
    function _extractBlockDelta(bytes memory packedSteps, uint256 offset) internal pure returns (uint40 blockDelta) {
        assembly {
            let packed := shr(192, mload(add(add(packedSteps, 0x20), offset)))
            blockDelta := and(packed, 0xFFFFFFFFFF)
        }
    }

    /// @dev Stores a step's block range and builds the reverse lookup index.
    ///      Index is 1-based so that 0 can represent "not found" in lookups.
    function _cacheStep(uint256 stepIndex, uint64 startBlock, uint64 endBlock) internal {
        _stepStartToIndex[startBlock] = stepIndex + 1;
        _steps.push(BlockRange({startBlock: startBlock, endBlock: endBlock}));
    }

    // ─────────────────────────────────────────────────────────
    // Step Toggles
    // ─────────────────────────────────────────────────────────

    /// @notice Enable verification enforcement for a step with required providers
    /// @param _stepIndex The step to enable
    /// @param _providerHashes Required provider hashes (empty = no zkTLS proof gate; step open unless a server permit is enabled)
    /// @param _providerIds Human-readable provider IDs (emitted in events for indexer)
    function enableStep(uint256 _stepIndex, bytes32[] calldata _providerHashes, string[] calldata _providerIds)
        external
        onlyOwner
    {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndex >= _steps.length) revert StepIndexOutOfBounds(_stepIndex);
        if (_providerHashes.length != _providerIds.length) revert ArrayLengthMismatch();
        _stepEnabledBitmap |= (1 << _stepIndex);
        _emitProviderRemovals(_stepIndex, _providerHashes);
        _stepProviderHashes[_stepIndex] = _providerHashes;
        emit StepEnabled(_stepIndex);
        for (uint256 i; i < _providerHashes.length;) {
            emit StepProviderSet(_stepIndex, _providerHashes[i], _providerIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Disable verification enforcement for a step
    /// @param _stepIndex The step to disable
    function disableStep(uint256 _stepIndex) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndex >= _steps.length) revert StepIndexOutOfBounds(_stepIndex);
        _stepEnabledBitmap &= ~(1 << _stepIndex);
        emit StepDisabled(_stepIndex);
    }

    /// @notice Enable verification enforcement for multiple steps with required providers
    /// @param _stepIndices Array of step indices to enable
    /// @param _providerHashes Array of provider hash arrays (one array per step)
    /// @param _providerIds Array of provider ID arrays (one array per step, parallel to hashes)
    function enableStepBatch(
        uint256[] calldata _stepIndices,
        bytes32[][] calldata _providerHashes,
        string[][] calldata _providerIds
    ) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndices.length != _providerHashes.length) revert ArrayLengthMismatch();
        if (_stepIndices.length != _providerIds.length) revert ArrayLengthMismatch();
        for (uint256 i; i < _stepIndices.length;) {
            if (_stepIndices[i] >= _steps.length) revert StepIndexOutOfBounds(_stepIndices[i]);
            if (_providerHashes[i].length != _providerIds[i].length) revert ArrayLengthMismatch();
            _stepEnabledBitmap |= (1 << _stepIndices[i]);
            _emitProviderRemovals(_stepIndices[i], _providerHashes[i]);
            _stepProviderHashes[_stepIndices[i]] = _providerHashes[i];
            emit StepEnabled(_stepIndices[i]);
            for (uint256 j; j < _providerHashes[i].length;) {
                emit StepProviderSet(_stepIndices[i], _providerHashes[i][j], _providerIds[i][j]);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Disable verification enforcement for multiple steps
    /// @param _stepIndices Array of step indices to disable
    function disableStepBatch(uint256[] calldata _stepIndices) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        for (uint256 i; i < _stepIndices.length;) {
            if (_stepIndices[i] >= _steps.length) revert StepIndexOutOfBounds(_stepIndices[i]);
            _stepEnabledBitmap &= ~(1 << _stepIndices[i]);
            emit StepDisabled(_stepIndices[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // Provider Configuration
    // ─────────────────────────────────────────────────────────

    /// @notice Replace all required providers for a step
    /// @param _stepIndex The step to configure
    /// @param _providerHashes Required provider hashes (empty = no zkTLS proof gate; step open unless a server permit is enabled)
    /// @param _providerIds Human-readable provider IDs (emitted in events for indexer)
    function setStepProviders(uint256 _stepIndex, bytes32[] calldata _providerHashes, string[] calldata _providerIds)
        external
        onlyOwner
    {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndex >= _steps.length) revert StepIndexOutOfBounds(_stepIndex);
        if (_providerHashes.length != _providerIds.length) revert ArrayLengthMismatch();
        _emitProviderRemovals(_stepIndex, _providerHashes);
        _stepProviderHashes[_stepIndex] = _providerHashes;
        for (uint256 i; i < _providerHashes.length;) {
            emit StepProviderSet(_stepIndex, _providerHashes[i], _providerIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Append providers to steps
    /// @param _stepIndices Step index for each provider to add
    /// @param _providerHashes Provider hash for each entry
    /// @param _providerIds Human-readable provider ID for each entry
    function addStepProviders(
        uint256[] calldata _stepIndices,
        bytes32[] calldata _providerHashes,
        string[] calldata _providerIds
    ) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndices.length != _providerHashes.length) revert ArrayLengthMismatch();
        if (_stepIndices.length != _providerIds.length) revert ArrayLengthMismatch();
        for (uint256 i; i < _stepIndices.length;) {
            if (_stepIndices[i] >= _steps.length) revert StepIndexOutOfBounds(_stepIndices[i]);
            _stepProviderHashes[_stepIndices[i]].push(_providerHashes[i]);
            emit StepProviderSet(_stepIndices[i], _providerHashes[i], _providerIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Remove providers from steps
    /// @param _stepIndices Step index for each provider to remove
    /// @param _providerHashes Provider hash for each entry to remove
    function removeStepProviders(uint256[] calldata _stepIndices, bytes32[] calldata _providerHashes)
        external
        onlyOwner
    {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndices.length != _providerHashes.length) revert ArrayLengthMismatch();
        for (uint256 i; i < _stepIndices.length;) {
            if (_stepIndices[i] >= _steps.length) revert StepIndexOutOfBounds(_stepIndices[i]);
            bytes32[] storage providers = _stepProviderHashes[_stepIndices[i]];
            uint256 len = providers.length;
            bool found;
            for (uint256 j; j < len;) {
                if (providers[j] == _providerHashes[i]) {
                    providers[j] = providers[len - 1];
                    providers.pop();
                    found = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (!found) revert ProviderNotFound(_stepIndices[i], _providerHashes[i]);
            emit StepProviderRemoved(_stepIndices[i], _providerHashes[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Replace all required providers for multiple steps
    /// @param _stepIndices Array of step indices to configure
    /// @param _providerHashes Array of provider hash arrays (one array per step)
    /// @param _providerIds Array of provider ID arrays (one array per step)
    function setStepProvidersBatch(
        uint256[] calldata _stepIndices,
        bytes32[][] calldata _providerHashes,
        string[][] calldata _providerIds
    ) external onlyOwner {
        if (_steps.length == 0) revert NoCCA();
        if (_stepIndices.length != _providerHashes.length) revert ArrayLengthMismatch();
        if (_stepIndices.length != _providerIds.length) revert ArrayLengthMismatch();
        for (uint256 i; i < _stepIndices.length;) {
            if (_stepIndices[i] >= _steps.length) revert StepIndexOutOfBounds(_stepIndices[i]);
            if (_providerHashes[i].length != _providerIds[i].length) revert ArrayLengthMismatch();
            _emitProviderRemovals(_stepIndices[i], _providerHashes[i]);
            _stepProviderHashes[_stepIndices[i]] = _providerHashes[i];
            for (uint256 j; j < _providerHashes[i].length;) {
                emit StepProviderSet(_stepIndices[i], _providerHashes[i][j], _providerIds[i][j]);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IUmiaValidationHook
    function isVerified(uint256 _stepIndex, address _user) public view returns (bool) {
        if (_stepIndex >= _steps.length) return false;
        uint256 verifiedFrom = _verifiedFromStep[_user];
        return verifiedFrom != 0 && verifiedFrom - 1 <= _stepIndex;
    }

    /// @inheritdoc IUmiaValidationHook
    function isStepEnabled(uint256 _stepIndex) public view returns (bool) {
        if (_stepIndex >= _steps.length) return false;
        return (_stepEnabledBitmap & (1 << _stepIndex)) != 0;
    }

    /// @inheritdoc IUmiaValidationHook
    function getStepProviders(uint256 _stepIndex) public view returns (bytes32[] memory) {
        return _stepProviderHashes[_stepIndex];
    }

    /// @inheritdoc IUmiaValidationHook
    function getSteps() external view returns (BlockRange[] memory) {
        return _steps;
    }

    /// @inheritdoc IUmiaValidationHook
    function cca() external view returns (address) {
        return _cca;
    }

    /// @inheritdoc IUmiaValidationHook
    function isStepPermitEnabled(uint256 _stepIndex) public view returns (bool) {
        if (_stepIndex >= _steps.length) return false;
        return (_stepPermitEnabledBitmap & (1 << _stepIndex)) != 0;
    }

    /// @inheritdoc IUmiaValidationHook
    function signer() external view returns (address) {
        return _signer;
    }

    /// @inheritdoc IMaxBidPriceValidationHook
    function maxBidPrice() external view returns (uint256) {
        return _maxBidPrice;
    }

    /// @inheritdoc IGatedValidationHook
    /// @dev Derived, not stored, because the step toggles move the gate at any time. Reports the
    ///      highest gated step, so a gap between gated steps reads as gated throughout.
    function expirationBlock() external view returns (uint256) {
        for (uint256 i = _steps.length; i != 0;) {
            unchecked {
                --i;
            }
            if (_isStepGated(i)) return _steps[i].endBlock;
        }
        return 0;
    }

    /// @inheritdoc IUmiaValidationHook
    function stepMaxBidAmount(uint256 stepIndex) external view returns (uint256) {
        return _stepMaxBidAmount[stepIndex];
    }

    /// @inheritdoc IUmiaValidationHook
    function zkBidTotal(address wallet, uint256 stepIndex) external view returns (uint256) {
        return _zkBidTotal[wallet][stepIndex];
    }

    /// @notice Get the auction-wide cumulative zkTLS bid-volume cap (0 = no cap), in
    ///         money-token base units.
    function zkGlobalMaxBidAmount() external view returns (uint256) {
        return _zkGlobalMaxBidAmount;
    }

    /// @notice Get the cumulative zkTLS bid volume across all wallets and steps, in
    ///         money-token base units. Gross and monotonic: accrues while uncapped and
    ///         refunds are not credited back.
    function zkGlobalBidTotal() external view returns (uint256) {
        return _zkGlobalBidTotal;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ValidationHookIntrospection, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || interfaceId == type(IUmiaValidationHook).interfaceId
            || interfaceId == type(IMaxBidPriceValidationHook).interfaceId
            || interfaceId == type(IGatedValidationHook).interfaceId;
    }

    // ─────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────

    /// @dev Empty provider list = no zkTLS proof gate (see enableStep).
    function _stepGateKinds(uint256 stepIndex) internal view returns (bool hasProofGate, bool hasPermitGate) {
        hasProofGate = _stepProviderHashes[stepIndex].length != 0;
        hasPermitGate = (_stepPermitEnabledBitmap & (1 << stepIndex)) != 0;
    }

    function _isStepGated(uint256 stepIndex) internal view returns (bool) {
        if ((_stepEnabledBitmap & (1 << stepIndex)) == 0) return false;
        (bool hasProofGate, bool hasPermitGate) = _stepGateKinds(stepIndex);
        return hasProofGate || hasPermitGate;
    }

    /// @dev Emits StepProviderRemoved for any existing providers not in the new set
    function _emitProviderRemovals(uint256 _stepIndex, bytes32[] calldata _newProviders) internal {
        bytes32[] storage oldProviders = _stepProviderHashes[_stepIndex];
        for (uint256 i; i < oldProviders.length;) {
            bool retained;
            for (uint256 j; j < _newProviders.length;) {
                if (oldProviders[i] == _newProviders[j]) {
                    retained = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (!retained) {
                emit StepProviderRemoved(_stepIndex, oldProviders[i]);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Resolves the 1-indexed step index for the current block.
    ///      Returns stepIndex + 1 so that 0 means "outside all steps".
    ///      First tries cca.step() for O(1) lookup. If the CCA's cached step
    ///      is stale (block >= endBlock), falls back to a forward scan of the
    ///      cached _steps array.
    function _resolveStepIndex() internal view returns (uint256) {
        AuctionStep memory s = IStepStorage(_cca).step();
        uint64 currentBlock = uint64(_getBlockNumberish());

        if (currentBlock >= s.startBlock && currentBlock < s.endBlock) {
            return _stepStartToIndex[s.startBlock];
        }

        if (currentBlock >= s.endBlock) {
            uint256 raw = _stepStartToIndex[s.startBlock];
            if (raw == 0) return 0;
            for (uint256 idx = raw; idx < _steps.length; ++idx) {
                if (currentBlock < _steps[idx].endBlock) return idx + 1;
            }
        }

        return 0;
    }
}
