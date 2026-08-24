// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IDistributor} from "@liquidity-launcher/interfaces/IDistributor.sol";
import {IDistributorFactory} from "@liquidity-launcher/interfaces/IDistributorFactory.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";

import {UmiaLBP} from "./UmiaLBP.sol";
import {IUmiaLBP} from "../interfaces/IUmiaLBP.sol";
import {SpotLiquidityVault} from "../core/SpotLiquidityVault.sol";

/// @title UmiaLBPFactory
/// @notice Factory for deploying UmiaLBP contracts using CREATE2.
///         The UmiaLBP and SpotLiquidityVault creation codes are stored via SSTORE2 to
///         avoid embedding them in the factory or LBP bytecode (which would exceed the
///         24KB EIP-170 limit).
/// @dev liquidity-launcher v3 removed the `StrategyFactory` base, so this implements
///      `IDistributorFactory` directly, reproducing the CREATE2 salt derivation and
///      address precomputation the base previously provided.
contract UmiaLBPFactory is IDistributorFactory {
    // ─────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────

    IPoolManager public immutable poolManager;
    address public immutable lbpCreationCodePointer;
    address public immutable vaultCreationCodePointer;
    address public immutable hub;
    address public immutable umiaHook;

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error InvalidPoolManager();
    error InvalidHub();
    error Unauthorized();
    error InvalidUmiaHook();
    error InvalidAmount(uint256 amount, uint256 max);

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event DistributionInitialized(address indexed distributionContract, address indexed token, uint256 totalSupply);

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    mapping(address => bool) public isLBP;

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Constructor
    /// @param _poolManager The uniswap v4 pool manager address
    /// @param _umiaHook The canonical UmiaHook address
    /// @param _hub The UmiaHub address (only caller allowed to create distributions)
    constructor(IPoolManager _poolManager, address _umiaHook, address _hub) {
        if (address(_poolManager) == address(0)) revert InvalidPoolManager();
        if (_umiaHook == address(0)) revert InvalidUmiaHook();
        if (_hub == address(0)) revert InvalidHub();
        poolManager = _poolManager;
        umiaHook = _umiaHook;
        hub = _hub;
        lbpCreationCodePointer = SSTORE2.write(type(UmiaLBP).creationCode);
        vaultCreationCodePointer = SSTORE2.write(type(SpotLiquidityVault).creationCode);
    }

    // ─────────────────────────────────────────────────────────
    // External Functions
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IDistributorFactory
    function create(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        override
        returns (IDistributor distributor)
    {
        if (msg.sender != hub) revert Unauthorized();
        bytes32 _salt = _hashSenderAndSalt(msg.sender, salt);
        bytes memory deployedBytecode = _validateParamsAndReturnDeployedBytecode(token, totalSupply, configData);
        distributor = IDistributor(Create2.deploy(0, _salt, deployedBytecode));
        isLBP[address(distributor)] = true;
        emit DistributionInitialized(address(distributor), token, totalSupply);
    }

    /// @inheritdoc IDistributorFactory
    function getAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt, address sender)
        external
        view
        override
        returns (IDistributor distributor)
    {
        bytes memory deployedBytecode = _validateParamsAndReturnDeployedBytecode(token, totalSupply, configData);
        distributor = IDistributor(
            Create2.computeAddress(_hashSenderAndSalt(sender, salt), keccak256(deployedBytecode), address(this))
        );
    }

    // ─────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────

    function _hashSenderAndSalt(address _sender, bytes32 _salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(_sender, _salt));
    }

    function _validateParamsAndReturnDeployedBytecode(address token, uint256 totalSupply, bytes calldata configData)
        internal
        view
        returns (bytes memory)
    {
        if (totalSupply > type(uint128).max) {
            revert InvalidAmount(totalSupply, type(uint128).max);
        }

        (
            uint256 tokenSplitToAuction,
            address moneyToken,
            bytes memory auctionParams,
            address venture,
            uint256 ventureBps
        ) = abi.decode(configData, (uint256, address, bytes, address, uint256));

        return abi.encodePacked(
            SSTORE2.read(lbpCreationCodePointer),
            abi.encode(
                token,
                uint128(totalSupply),
                tokenSplitToAuction,
                moneyToken,
                auctionParams,
                poolManager,
                umiaHook,
                venture,
                ventureBps,
                vaultCreationCodePointer
            )
        );
    }
}
