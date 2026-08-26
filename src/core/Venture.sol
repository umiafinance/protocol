// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {VentureToken} from "../tokens/VentureToken.sol";
import {ILBPMigrationCallback} from "../interfaces/ILBPMigrationCallback.sol";
import {GovernanceTypes} from "../libraries/GovernanceTypes.sol";
import {CalendarLib} from "../libraries/CalendarLib.sol";

/// @title Venture
/// @notice Umia's Venture treasury contract.
/// @dev This contract holds a venture's assets and manages token minting, burning,
///      treasury operations, and liquidation. It is upgradeable via UUPS.
contract Venture is
    Initializable,
    UUPSUpgradeable,
    IVenture,
    ILBPMigrationCallback,
    IERC721Receiver,
    IERC1155Receiver,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    /// @notice The token representing the venture asset.
    address public token;

    /// @notice The money token (quote token) for this venture.
    address public moneyToken;

    /// @notice Minimum stake required to open a market for this venture.
    uint256 public minMarketStake;

    /// @notice The address of the UmiaHub contract.
    address public HUB;

    /// @notice The LBP contract address for this venture.
    address public lbp;

    /// @notice Monthly allowance configuration per token.
    /// @dev Maps token address to AllowanceState struct containing amount, spent, and currentMonth.
    mapping(address => AllowanceState) public monthlyAllowance;

    /// @notice Team member registry for allowance withdrawals.
    /// @dev True if the address is a registered team member.
    mapping(address => bool) public isTeamMember;

    /// @notice Document registry (1-indexed).
    /// @dev Maps document ID to Document struct.
    mapping(uint256 => Document) public documents;

    /// @notice Total number of documents uploaded.
    uint256 public documentCount;

    /// @notice Duration of optional trading pause after LBP migration (0 = no pause).
    /// @dev Maximum allowed is MAX_TRADING_PAUSE_DURATION (60 days).
    uint256 public tradingPauseDuration;

    /// @notice Timestamp after which anyone can unpause trading (0 = not paused).
    uint256 public tradingPauseDeadline;

    /// @notice Maximum allowed trading pause duration (60 days).
    uint256 public constant MAX_TRADING_PAUSE_DURATION = 60 days;

    /// @notice Maximum allowed document name length.
    uint256 public constant MAX_DOCUMENT_NAME_LENGTH = 256;

    /// @notice Maximum allowed document URI length.
    uint256 public constant MAX_DOCUMENT_URI_LENGTH = 2048;

    /// @notice Liquidation state (terminal).
    /// @dev Once true, no further treasury operations except claims are allowed.
    bool public liquidationActive;

    /// @notice The authorized liquidator contract for this venture (set during liquidation).
    /// @dev During liquidation, only this address can call withdraw functions.
    address public authorizedLiquidator;

    /// @notice Gap for future upgrades.
    uint256[50] private __gap;

    // ─────────────────────────────────────────────────────────
    // Upgrade
    // ─────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable _self = address(this);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Disables initializers for the implementation contract to prevent it from being used directly.
    constructor() {
        _disableInitializers();
    }

    /// @notice Sets the HUB address during proxy deployment.
    /// @dev This is the first initialization phase (initializer 1). Called by the proxy factory.
    /// @param _hub The address of the UmiaHub contract.
    function initializeProxy(address _hub) external initializer {
        HUB = _hub;
    }

    /// @dev Override OZ's _checkProxy to only verify delegatecall context.
    ///      The default also checks `ERC1967Utils.getImplementation() == __self`,
    ///      which fails for beacon-mode Ventures where the implementation slot is address(0).
    function _checkProxy() internal view override {
        if (address(this) == _self) {
            revert UUPSUnauthorizedCallContext();
        }
    }

    /// @dev Authorizes upgrades to the implementation contract.
    /// @inheritdoc UUPSUpgradeable
    /// @notice Only the governance executor can authorize upgrades.
    function _authorizeUpgrade(address) internal view override onlyExecutor {}

    // ─────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────

    /// @notice Initializes the venture with full configuration. Only callable by UmiaHub.
    /// @dev This is the second initialization phase (reinitializer 2). Called after initializeProxy.
    ///      Sets up the token, team, allowances, and trading pause configuration.
    /// @param _params The initialization parameters including token addresses, team members, and settings.
    function initialize(InitializeVentureParams calldata _params) external reinitializer(2) {
        if (msg.sender != HUB) revert CallerNotHub();
        if (_params.token == address(0)) revert InvalidParams();
        if (_params.moneyToken == address(0)) revert InvalidParams();
        if (_params.lbp == address(0)) revert InvalidParams();
        if (_params.teamMembers.length == 0) revert InvalidParams();

        if (VentureToken(_params.token).owner() != address(this)) revert InvalidParams();
        if (IUmiaHub(HUB).umiaMarketCore() == address(0)) revert InvalidParams();

        if (_params.tradingPauseDuration > MAX_TRADING_PAUSE_DURATION) revert TradingPauseDurationTooLong();

        lbp = _params.lbp;
        token = _params.token;
        moneyToken = _params.moneyToken;
        tradingPauseDuration = _params.tradingPauseDuration;

        for (uint256 i = 0; i < _params.teamMembers.length; i++) {
            _setTeamMember(_params.teamMembers[i], true);
        }

        if (_params.startingMonthlyAllowance > 0) {
            AllowanceState storage allowance = monthlyAllowance[_params.moneyToken];
            allowance.amount = _params.startingMonthlyAllowance;
            allowance.currentMonth = CalendarLib.timestampToMonth(block.timestamp);
            emit MonthlyAllowanceUpdated(_params.moneyToken, _params.startingMonthlyAllowance);
        }
    }

    // ─────────────────────────────────────────────────────────
    // Callbacks
    // ─────────────────────────────────────────────────────────

    /// @notice Called by the LBP after migration completes.
    /// @dev The canonical spot liquidity is held by the venture's SpotLiquidityVault, not an LP
    ///      NFT owned here, so this only applies the optional post-migration trading pause.
    function onLBPMigrated() external override {
        if (msg.sender != lbp) revert CallerNotAuthorized();

        if (tradingPauseDuration > 0) {
            tradingPauseDeadline = block.timestamp + tradingPauseDuration;
            VentureToken(token).pause();
        }
    }

    /// @notice Unpauses token trading after LBP migration.
    /// @dev Team members can call anytime. After the deadline, anyone can call.
    ///      Emits TradingStarted event.
    function startTrading() external {
        if (tradingPauseDeadline == 0) revert TradingNotPaused();
        if (!isTeamMember[msg.sender] && block.timestamp < tradingPauseDeadline) {
            revert TradingPauseNotExpired();
        }

        tradingPauseDeadline = 0;
        VentureToken(token).unpause();
        emit TradingStarted(msg.sender);
    }

    // ─────────────────────────────────────────────────────────
    // Treasury Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Mints new venture tokens to the specified address.
    /// @dev Only callable by the governance executor when not in liquidation.
    /// @param _to The address to receive the minted tokens.
    /// @param _amount The amount of tokens to mint.
    function mint(address _to, uint256 _amount) external onlyExecutor whenNotLiquidating nonReentrant {
        VentureToken(token).mint(_to, _amount);
    }

    /// @notice Burns venture tokens held by the treasury.
    /// @dev Only callable by the governance executor when not in liquidation.
    /// @param _amount The amount of tokens to burn from the treasury balance.
    function burn(uint256 _amount) external onlyExecutor whenNotLiquidating nonReentrant {
        VentureToken(token).burn(address(this), _amount);
    }

    /// @notice Burns venture tokens from a specific account during liquidation.
    /// @dev Only the authorized liquidator can call this function during liquidation.
    ///      Used by liquidator contracts to burn user tokens when processing claims.
    /// @param _from The address to burn tokens from.
    /// @param _amount The amount of tokens to burn.
    function burnFrom(address _from, uint256 _amount) external nonReentrant {
        if (!liquidationActive) revert NotLiquidating();
        if (msg.sender != authorizedLiquidator) revert CallerNotAuthorized();
        VentureToken(token).burn(_from, _amount);
    }

    /// @notice Withdraws ERC20 tokens or native currency from the treasury.
    /// @dev During liquidation: only the authorized liquidator can withdraw.
    ///      During normal operations: only the governance executor can withdraw.
    /// @param _token The token address to withdraw (address(0) for native currency).
    /// @param _to The recipient address.
    /// @param _amount The amount to withdraw.
    function withdraw(address _token, address _to, uint256 _amount) external nonReentrant {
        if (liquidationActive) {
            if (msg.sender != authorizedLiquidator) revert CallerNotAuthorized();
        } else {
            if (!_isExecutor()) revert CallerNotAuthorized();
        }
        _transferToken(_token, _to, _amount);
    }

    /// @notice Withdraws an ERC721 NFT from the treasury.
    /// @dev During liquidation: only the authorized liquidator can withdraw.
    ///      During normal operations: only the governance executor can withdraw.
    /// @param _token The ERC721 token contract address.
    /// @param _to The recipient address.
    /// @param _tokenId The token ID to withdraw.
    function withdrawERC721(address _token, address _to, uint256 _tokenId) external nonReentrant {
        if (liquidationActive) {
            if (msg.sender != authorizedLiquidator) revert CallerNotAuthorized();
        } else {
            if (!_isExecutor()) revert CallerNotAuthorized();
        }
        IERC721(_token).safeTransferFrom(address(this), _to, _tokenId);
    }

    /// @notice Withdraws an ERC1155 token from the treasury.
    /// @dev During liquidation: only the authorized liquidator can withdraw.
    ///      During normal operations: only the governance executor can withdraw.
    /// @param _token The ERC1155 token contract address.
    /// @param _to The recipient address.
    /// @param _tokenId The token ID to withdraw.
    /// @param _amount The amount of tokens to withdraw.
    /// @param _data Additional data to pass to the ERC1155 safeTransferFrom hook.
    function withdrawERC1155(address _token, address _to, uint256 _tokenId, uint256 _amount, bytes calldata _data)
        external
        nonReentrant
    {
        if (liquidationActive) {
            if (msg.sender != authorizedLiquidator) revert CallerNotAuthorized();
        } else {
            if (!_isExecutor()) revert CallerNotAuthorized();
        }
        IERC1155(_token).safeTransferFrom(address(this), _to, _tokenId, _amount, _data);
    }

    /// @notice Executes an arbitrary low-level call from the treasury.
    /// @dev Only callable by the governance executor when not in liquidation.
    ///      Use with caution - this can call any contract.
    /// @param _target The contract address to call.
    /// @param _value The amount of native currency to send with the call.
    /// @param _data The calldata to send.
    /// @return result The return data from the call.
    function executeCall(address _target, uint256 _value, bytes calldata _data)
        external
        onlyExecutor
        whenNotLiquidating
        nonReentrant
        returns (bytes memory result)
    {
        if (_target == address(0)) revert InvalidParams();
        (bool success, bytes memory returnData) = _target.call{value: _value}(_data);
        if (!success) revert TransferFailed();
        return returnData;
    }

    /// @notice Updates the team member status for an address.
    /// @dev Only callable by the governance executor.
    /// @param _member The address to update.
    /// @param _approved True to add as team member, false to remove.
    function updateTeamMember(address _member, bool _approved) external onlyExecutor {
        _setTeamMember(_member, _approved);
    }

    /// @notice Updates the monthly allowance for a specific token.
    /// @dev Only callable by the governance executor when not in liquidation.
    ///      Syncs the allowance month before updating the amount.
    /// @param _token The token address for the allowance.
    /// @param _amount The new allowance amount.
    function updateMonthlyAllowance(address _token, uint256 _amount) external onlyExecutor whenNotLiquidating {
        AllowanceState storage allowance = monthlyAllowance[_token];
        _syncAllowance(allowance);
        allowance.amount = _amount;
        emit MonthlyAllowanceUpdated(_token, _amount);
    }

    /// @notice Sets an ERC20 allowance from the treasury to a specific spender.
    /// @dev Only callable by the governance executor. Enables programmatic pull access
    ///      (e.g. for TWAP buyback bots or keepers) without using the raw CALL escape hatch.
    ///      Uses forceApprove for compatibility with non-standard ERC20s.
    /// @param _token The ERC20 token address.
    /// @param _spender The address to grant allowance to.
    /// @param _amount The allowance amount (0 to revoke).
    function setAllowance(address _token, address _spender, uint256 _amount)
        external
        onlyExecutor
        whenNotLiquidating
        nonReentrant
    {
        if (_token == address(0) || _spender == address(0)) revert InvalidParams();
        IERC20(_token).forceApprove(_spender, _amount);
        emit AllowanceSet(_token, _spender, _amount);
    }

    /// @notice Withdraws tokens from the monthly allowance.
    /// @dev Only team members can call this when not in liquidation.
    ///      The amount is deducted from the current month's allowance.
    /// @param _token The token to withdraw.
    /// @param _to The recipient address.
    /// @param _amount The amount to withdraw.
    function withdrawMonthlyAllowance(address _token, address _to, uint256 _amount)
        external
        whenNotLiquidating
        nonReentrant
    {
        if (!isTeamMember[msg.sender]) revert NotTeamMember();
        if (_to == address(0) || _amount == 0) revert InvalidParams();

        AllowanceState storage allowance = monthlyAllowance[_token];
        _syncAllowance(allowance);

        if (allowance.spent >= allowance.amount) revert AllowanceExceeded();
        uint256 remaining = allowance.amount - allowance.spent;
        if (_amount > remaining) revert AllowanceExceeded();

        allowance.spent += _amount;
        _transferToken(_token, _to, _amount);
        emit MonthlyAllowanceWithdrawn(_token, _to, _amount);
    }

    /// @notice Uploads a governance document reference.
    /// @dev Only callable by the governance executor when not in liquidation.
    ///      Documents are stored with an auto-incremented ID starting from 1.
    /// @param _name The document name or title.
    /// @param _uri The document URI or reference link.
    function uploadDocument(string calldata _name, string calldata _uri) external onlyExecutor whenNotLiquidating {
        if (bytes(_name).length == 0 || bytes(_uri).length == 0) revert InvalidParams();
        if (bytes(_name).length > MAX_DOCUMENT_NAME_LENGTH) revert InvalidParams();
        if (bytes(_uri).length > MAX_DOCUMENT_URI_LENGTH) revert InvalidParams();
        uint256 docId = ++documentCount;
        documents[docId] = Document({name: _name, uri: _uri, createdAt: block.timestamp});
        emit DocumentUploaded(docId, _name, _uri);
    }

    /// @notice Authorizes a liquidator contract and activates liquidation.
    /// @dev Called by the governance executor during LIQUIDATE_TREASURY action.
    ///      Once liquidation is active, it cannot be undone.
    /// @param _liquidator The liquidator contract address to authorize.
    function setLiquidator(address _liquidator) external onlyExecutor whenNotLiquidating {
        if (_liquidator == address(0)) revert InvalidParams();

        liquidationActive = true;
        authorizedLiquidator = _liquidator;

        emit LiquidatorAuthorized(_liquidator);
    }

    /// @notice Sets the minimum stake required to open a market for this venture.
    /// @dev Only callable by UmiaHub.
    /// @param _amount The minimum stake amount in wei.
    function setMinMarketStake(uint256 _amount) external onlyHub {
        minMarketStake = _amount;
        emit MinMarketStakeUpdated(_amount);
    }

    // ─────────────────────────────────────────────────────────
    // Receive Functions
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IERC721Receiver
    /// @notice Handles ERC721 token receipts.
    /// @return bytes4 The ERC721 receiver interface ID.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    /// @notice Handles ERC1155 token receipts.
    /// @return bytes4 The ERC1155 receiver interface ID.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    /// @notice Handles batch ERC1155 token receipts.
    /// @return bytes4 The ERC1155 batch receiver interface ID.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /// @inheritdoc IERC165
    /// @notice Returns whether the contract supports a given interface.
    /// @param interfaceId The interface ID to check.
    /// @return bool True if the interface is supported (ERC721 or ERC1155 receiver).
    function supportsInterface(bytes4 interfaceId) external pure override(IERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC721Receiver).interfaceId;
    }

    /// @notice Fallback receive function to accept native currency.
    receive() external payable {}

    // ─────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────

    /// @dev Modifier to restrict function access to UmiaHub only.
    /// @notice Reverts with CallerNotHub if msg.sender is not the HUB.
    modifier onlyHub() {
        if (msg.sender != HUB) revert CallerNotHub();
        _;
    }

    /// @dev Modifier to restrict function access to the governance executor only.
    /// @notice Reverts with CallerNotAuthorized if msg.sender is not the executor.
    modifier onlyExecutor() {
        address _executor = IUmiaHub(HUB).governanceExecutor(address(this));
        if (_executor == address(0) || msg.sender != _executor) revert CallerNotAuthorized();
        _;
    }

    /// @dev Modifier to prevent function execution during liquidation.
    /// @notice Reverts with LiquidationActive if liquidationActive is true.
    modifier whenNotLiquidating() {
        if (liquidationActive) revert LiquidationActive();
        _;
    }

    // ─────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────

    /// @notice Transfers tokens or native currency to a recipient.
    /// @dev Internal function used by withdraw functions.
    /// @param _token The token address (address(0) for native).
    /// @param _to The recipient address.
    /// @param _amount The amount to transfer.
    function _transferToken(address _token, address _to, uint256 _amount) internal {
        if (_token == address(0)) {
            (bool success,) = payable(_to).call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    /// @notice Syncs the monthly allowance state to the current month.
    /// @dev Resets the spent amount if the month has changed.
    /// @param allowance The storage reference to the AllowanceState.
    function _syncAllowance(AllowanceState storage allowance) internal {
        uint256 month = CalendarLib.timestampToMonth(block.timestamp);
        if (allowance.currentMonth == month) return;
        allowance.currentMonth = month;
        allowance.spent = 0;
    }

    /// @notice Internal function to update team member status.
    /// @dev Validates the member address and updates the registry.
    /// @param _member The member address to update.
    /// @param _approved True to add, false to remove.
    function _setTeamMember(address _member, bool _approved) internal {
        if (_member == address(0)) revert InvalidParams();
        isTeamMember[_member] = _approved;
        emit TeamMemberUpdated(_member, _approved);
    }

    /// @notice Returns true if the caller is the governance executor.
    /// @dev Internal helper for authorization checks in treasury functions.
    /// @return bool True if sender is the executor.
    function _isExecutor() internal view returns (bool) {
        return msg.sender == IUmiaHub(HUB).governanceExecutor(address(this));
    }
}
