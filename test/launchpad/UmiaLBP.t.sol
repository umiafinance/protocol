// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {SpotLiquidityVault} from "../../src/core/SpotLiquidityVault.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {UmiaHook} from "../../src/periphery/UmiaHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract UmiaLBPTest is Test {
    address internal vaultCodePointer = SSTORE2.write(type(SpotLiquidityVault).creationCode);
    address constant VENTURE = address(0x1);
    address constant TOKEN = address(0x2);
    address constant CURRENCY = address(0x3);
    address constant POOL_MANAGER = address(0x5);

    uint128 constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 constant VENTURE_BPS = 2000; // 20%
    uint256 constant MAX_BPS = 9_999;
    uint256 constant TOKEN_SPLIT = 5_000_000; // 50%
    address constant MOCK_HUB = address(0x8);

    /// @dev UmiaHook permission flags: beforeInitialize | afterInitialize | beforeAddLiquidity
    ///      | beforeSwap | afterSwap | afterSwapReturnDelta.
    uint160 constant HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

    UmiaHook public umiaHook;

    function setUp() public {
        umiaHook = _deployUmiaHook();

        vm.mockCall(VENTURE, abi.encodeWithSelector(IVenture.HUB.selector), abi.encode(MOCK_HUB));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.ccaFactory.selector), abi.encode(address(0x6)));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.migrationDelayBlocks.selector), abi.encode(uint64(50)));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.sweepDelayBlocks.selector), abi.encode(uint64(50)));
    }

    function _deployUmiaHook() internal returns (UmiaHook hook) {
        (, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(UmiaHook).creationCode, abi.encode(address(this)));
        hook = new UmiaHook{salt: salt}(address(this));
        hook.initialize(address(this), IPoolManager(POOL_MANAGER));
    }

    function createAuctionParams() internal pure returns (bytes memory) {
        return "";
    }

    function _deployLBP(
        address _token,
        uint128 _totalSupply,
        uint256 _tokenSplitToAuction,
        address _moneyToken,
        bytes memory _auctionParams,
        address _venture,
        uint256 _ventureBps
    ) internal returns (UmiaLBP) {
        return new UmiaLBP(
            _token,
            _totalSupply,
            _tokenSplitToAuction,
            _moneyToken,
            _auctionParams,
            IPoolManager(POOL_MANAGER),
            IUmiaHook(address(umiaHook)),
            _venture,
            _ventureBps,
            vaultCodePointer
        );
    }

    /// @notice Test: Constructor should revert when venture is address(0)
    function test_Constructor_RevertsWhen_VentureIsZeroAddress() public {
        bytes memory auctionParams = createAuctionParams();

        vm.expectRevert(IUmiaLBP.InvalidVentureAddress.selector);
        _deployLBP(TOKEN, TOTAL_SUPPLY, TOKEN_SPLIT, CURRENCY, auctionParams, address(0), VENTURE_BPS);
    }

    /// @notice Test: Constructor should revert when ventureBps > MAX_BPS (9999)
    function test_Constructor_RevertsWhen_VentureBpsExceedsMax() public {
        bytes memory auctionParams = createAuctionParams();

        vm.expectRevert(IUmiaLBP.InvalidVentureBps.selector);
        _deployLBP(TOKEN, TOTAL_SUPPLY, TOKEN_SPLIT, CURRENCY, auctionParams, VENTURE, 10_000);
    }

    /// @notice Test: Constructor should succeed with valid parameters
    function test_Constructor_SucceedsWithValidParameters() public {
        bytes memory auctionParams = createAuctionParams();

        UmiaLBP lbp = _deployLBP(TOKEN, TOTAL_SUPPLY, TOKEN_SPLIT, CURRENCY, auctionParams, VENTURE, VENTURE_BPS);

        assertEq(lbp.venture(), VENTURE, "venture address mismatch");
        assertEq(lbp.ventureBps(), VENTURE_BPS, "ventureBps mismatch");
        assertEq(lbp.token(), TOKEN, "token address mismatch");
        assertEq(lbp.totalSupply(), TOTAL_SUPPLY, "totalSupply mismatch");
        assertEq(address(lbp.umiaHook()), address(umiaHook), "umiaHook mismatch");
    }

    /// @notice Test: Constructor should revert when tokenSplitToAuction >= 100%
    function test_Constructor_RevertsWhen_TokenSplitTooHigh() public {
        bytes memory auctionParams = createAuctionParams();

        vm.expectRevert(IUmiaLBP.TokenSplitTooHigh.selector);
        _deployLBP(TOKEN, TOTAL_SUPPLY, 10_000_000, CURRENCY, auctionParams, VENTURE, VENTURE_BPS);
    }

    /// @notice Test: Constructor should revert when token split produces zero auction supply
    function test_Constructor_RevertsWhen_InitializerTokenSplitIsZero() public {
        bytes memory auctionParams = createAuctionParams();

        vm.expectRevert(IUmiaLBP.InitializerTokenSplitIsZero.selector);
        _deployLBP(TOKEN, TOTAL_SUPPLY, 0, CURRENCY, auctionParams, VENTURE, VENTURE_BPS);
    }
}
