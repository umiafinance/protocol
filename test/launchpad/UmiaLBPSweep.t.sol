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
import {MockERC20} from "../mocks/MockERC20.sol";

contract UmiaLBPSweepTest is Test {
    address internal vaultCodePointer = SSTORE2.write(type(SpotLiquidityVault).creationCode);
    address constant VENTURE = address(0x1);
    address constant RANDOM_CALLER = address(0x999);
    address constant MOCK_HUB = address(0x8);
    uint64 constant MIGRATED_AT_BLOCK = 1;

    uint128 constant TOTAL_SUPPLY = 1_000_000e18;
    uint160 constant HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

    MockERC20 public mockCurrency;
    MockERC20 public mockToken;
    address public mockPoolManager;
    UmiaHook public umiaHook;

    function setUp() public {
        mockCurrency = new MockERC20("Mock Currency", "MCUR", 18);
        mockToken = new MockERC20("Mock Token", "MTOK", 18);
        mockPoolManager = address(0x5);
        umiaHook = _deployUmiaHook();

        vm.mockCall(VENTURE, abi.encodeWithSelector(IVenture.HUB.selector), abi.encode(MOCK_HUB));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.sweepDelayBlocks.selector), abi.encode(uint64(50)));
    }

    function _deployUmiaHook() internal returns (UmiaHook hook) {
        (, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(UmiaHook).creationCode, abi.encode(address(this)));
        hook = new UmiaHook{salt: salt}(address(this));
        hook.initialize(address(this), IPoolManager(mockPoolManager));
    }

    function deployLBP(uint256 ventureBps) internal returns (UmiaLBP lbp) {
        bytes memory auctionParams = "";

        lbp = new UmiaLBP(
            address(mockToken),
            TOTAL_SUPPLY,
            5_000_000,
            address(mockCurrency),
            auctionParams,
            IPoolManager(mockPoolManager),
            IUmiaHook(address(umiaHook)),
            VENTURE,
            ventureBps,
            vaultCodePointer
        );

        _forceMigrated(lbp);
    }

    /// @dev Sweeps require `migrated == true`. A full migrate() needs real Uniswap infra, so this
    ///      pure-mock suite writes the migrated flag directly. Slot 1 packs
    ///      `initializer`(offset 0) | `migrated`(offset 20) | `migratedAtBlock`(offset 21).
    function _forceMigrated(UmiaLBP lbp) internal {
        uint256 packed = (uint256(1) << 160) | (uint256(MIGRATED_AT_BLOCK) << 168);
        vm.store(address(lbp), bytes32(uint256(1)), bytes32(packed));
    }

    function _sweepWindow(UmiaLBP lbp) internal view returns (uint256) {
        return uint256(lbp.migratedAtBlock()) + lbp.hub().sweepDelayBlocks();
    }

    function test_SweepToken_SuccessfullyTransfersTokensToVenture() public {
        UmiaLBP lbp = deployLBP(2000);

        mockToken.mint(address(lbp), 100 ether);

        vm.roll(_sweepWindow(lbp));

        uint256 ventureBalanceBefore = mockToken.balanceOf(VENTURE);

        vm.expectEmit(true, true, true, true);
        emit IUmiaLBP.TokensSwept(VENTURE, 100 ether);
        lbp.sweepToken();

        assertEq(mockToken.balanceOf(VENTURE) - ventureBalanceBefore, 100 ether, "Venture should receive tokens");
        assertEq(mockToken.balanceOf(address(lbp)), 0, "LBP should have 0 tokens after sweep");
    }

    function test_SweepToken_RevertsWhen_BeforeSweepBlock() public {
        UmiaLBP lbp = deployLBP(2000);

        mockToken.mint(address(lbp), 100 ether);

        vm.roll(_sweepWindow(lbp) - 1);

        vm.expectRevert(IUmiaLBP.SweepNotAllowed.selector);
        lbp.sweepToken();
    }

    function test_SweepToken_AnyoneCanCall() public {
        UmiaLBP lbp = deployLBP(2000);

        mockToken.mint(address(lbp), 100 ether);

        vm.roll(_sweepWindow(lbp));

        uint256 ventureBalanceBefore = mockToken.balanceOf(VENTURE);

        vm.prank(RANDOM_CALLER);
        lbp.sweepToken();

        assertEq(mockToken.balanceOf(VENTURE) - ventureBalanceBefore, 100 ether, "Venture should receive tokens");
    }

    function test_SweepToken_DoesNothingWhen_NoTokenBalance() public {
        UmiaLBP lbp = deployLBP(2000);

        vm.roll(_sweepWindow(lbp));

        uint256 ventureBalanceBefore = mockToken.balanceOf(VENTURE);

        lbp.sweepToken();

        assertEq(mockToken.balanceOf(VENTURE), ventureBalanceBefore, "Venture balance should not change");
    }

    function test_SweepCurrency_SuccessfullyTransfersCurrencyToVenture() public {
        UmiaLBP lbp = deployLBP(2000);

        mockCurrency.mint(address(lbp), 50 ether);

        vm.roll(_sweepWindow(lbp));

        uint256 ventureBalanceBefore = mockCurrency.balanceOf(VENTURE);

        vm.expectEmit(true, true, true, true);
        emit IUmiaLBP.CurrencySwept(VENTURE, 50 ether);
        lbp.sweepCurrency();

        assertEq(mockCurrency.balanceOf(VENTURE) - ventureBalanceBefore, 50 ether, "Venture should receive currency");
        assertEq(mockCurrency.balanceOf(address(lbp)), 0, "LBP should have 0 currency after sweep");
    }

    function test_SweepCurrency_RevertsWhen_BeforeSweepBlock() public {
        UmiaLBP lbp = deployLBP(2000);

        mockCurrency.mint(address(lbp), 50 ether);

        vm.roll(_sweepWindow(lbp) - 1);

        vm.expectRevert(IUmiaLBP.SweepNotAllowed.selector);
        lbp.sweepCurrency();
    }

    function test_SweepCurrency_AnyoneCanCall() public {
        UmiaLBP lbp = deployLBP(2000);

        mockCurrency.mint(address(lbp), 50 ether);

        vm.roll(_sweepWindow(lbp));

        uint256 ventureBalanceBefore = mockCurrency.balanceOf(VENTURE);

        vm.prank(RANDOM_CALLER);
        lbp.sweepCurrency();

        assertEq(mockCurrency.balanceOf(VENTURE) - ventureBalanceBefore, 50 ether, "Venture should receive currency");
    }

    function test_SweepCurrency_DoesNothingWhen_NoCurrencyBalance() public {
        UmiaLBP lbp = deployLBP(2000);

        vm.roll(_sweepWindow(lbp));

        uint256 ventureBalanceBefore = mockCurrency.balanceOf(VENTURE);

        lbp.sweepCurrency();

        assertEq(mockCurrency.balanceOf(VENTURE), ventureBalanceBefore, "Venture balance should not change");
    }

    /// @dev The LBP is ERC-20 only and has no native exit path, so it deliberately declares no
    ///      `receive()`: value transfers must bounce rather than strand ETH here forever.
    function test_NativeTransfer_RevertsAndStrandsNothing() public {
        UmiaLBP lbp = deployLBP(2000);

        vm.deal(address(this), 1 ether);
        (bool success,) = address(lbp).call{value: 1 ether}("");

        assertFalse(success, "LBP should reject native currency");
        assertEq(address(lbp).balance, 0, "LBP should hold no native currency");
    }
}
