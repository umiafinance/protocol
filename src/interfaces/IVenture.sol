// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GovernanceTypes} from "../libraries/GovernanceTypes.sol";

/// @title IVenture
/// @notice Interface for the Umia Venture treasury contract.
interface IVenture {
    // ─────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────

    struct InitializeVentureParams {
        address token;
        address moneyToken;
        address lbp;
        address[] teamMembers;
        uint256 tradingPauseDuration;
        uint256 startingMonthlyAllowance;
    }

    struct AllowanceState {
        uint256 amount;
        uint256 spent;
        uint256 currentMonth;
    }

    struct Document {
        string name;
        string uri;
        uint256 createdAt;
    }

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error CallerNotHub();
    error CallerNotAuthorized();
    error TransferFailed();
    error InvalidParams();
    error NotTeamMember();
    error AllowanceExceeded();
    error LiquidationActive();
    error NotLiquidating();
    error TradingNotPaused();
    error TradingPauseNotExpired();
    error TradingPauseDurationTooLong();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event MinMarketStakeUpdated(uint256 amount);
    event TeamMemberUpdated(address indexed member, bool approved);
    event MonthlyAllowanceUpdated(address indexed token, uint256 amount);
    event MonthlyAllowanceWithdrawn(address indexed token, address indexed to, uint256 amount);
    event AllowanceSet(address indexed token, address indexed spender, uint256 amount);
    event DocumentUploaded(uint256 indexed docId, string name, string uri);
    event LiquidatorAuthorized(address indexed liquidator);
    event TradingStarted(address indexed caller);

    // ─────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────

    function token() external view returns (address);
    function moneyToken() external view returns (address);
    function minMarketStake() external view returns (uint256);
    function HUB() external view returns (address);
    function lbp() external view returns (address);
    function monthlyAllowance(address token) external view returns (uint256 amount, uint256 spent, uint256 currentMonth);
    function isTeamMember(address member) external view returns (bool);
    function documents(uint256 docId) external view returns (string memory name, string memory uri, uint256 createdAt);
    function documentCount() external view returns (uint256);
    function tradingPauseDuration() external view returns (uint256);
    function tradingPauseDeadline() external view returns (uint256);
    function liquidationActive() external view returns (bool);
    function authorizedLiquidator() external view returns (address);

    // ─────────────────────────────────────────────────────────
    // State-Changing Functions
    // ─────────────────────────────────────────────────────────

    function initializeProxy(address _hub) external;
    function initialize(InitializeVentureParams calldata _params) external;
    function startTrading() external;
    function mint(address _to, uint256 _amount) external;
    function burn(uint256 _amount) external;
    function burnFrom(address _from, uint256 _amount) external;
    function withdraw(address _token, address _to, uint256 _amount) external;
    function withdrawERC721(address _token, address _to, uint256 _tokenId) external;
    function withdrawERC1155(address _token, address _to, uint256 _tokenId, uint256 _amount, bytes calldata _data)
        external;
    function executeCall(address _target, uint256 _value, bytes calldata _data) external returns (bytes memory);
    function updateTeamMember(address _member, bool _approved) external;
    function updateMonthlyAllowance(address _token, uint256 _amount) external;
    function setAllowance(address _token, address _spender, uint256 _amount) external;
    function withdrawMonthlyAllowance(address _token, address _to, uint256 _amount) external;
    function uploadDocument(string calldata _name, string calldata _uri) external;
    function setLiquidator(address _liquidator) external;
    function setMinMarketStake(uint256 _amount) external;
}
