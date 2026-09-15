// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {YieldPositionGuardian, IMorphoBlue} from "../../src/periphery/YieldPositionGuardian.sol";
import {FakeVenture} from "./YieldPositionGuardianMocks.sol";

/// @notice Fork rehearsal of the emergency-exit flow against the real Aave v3 pool and the two
///         Morpho vaults on Base from the first treasury-yield market plan.
///
///         Runs only when BASE_RPC_URL is set (shows as skipped otherwise):
///           BASE_RPC_URL=https://... forge test --match-contract YieldPositionGuardianForkTest -vv
contract YieldPositionGuardianForkTest is Test {
    // Base mainnet (chain 8453)
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant GAUNTLET_PRIME = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61;
    address constant STEAKHOUSE_PRIME = 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9;

    address operator = address(0x0F1CE);

    FakeVenture venture;
    YieldPositionGuardian exit_;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0, "BASE_RPC_URL unset");
        vm.createSelectFork(rpc);

        venture = new FakeVenture();
        exit_ = new YieldPositionGuardian(address(venture), operator);

        // Mirror the first market: venture supplies $4M USDC to Aave, then SET_ALLOWANCE(aUSDC).
        deal(USDC, address(venture), 7_000_000e6);
        venture.supply(AAVE_POOL, USDC, 4_000_000e6);
        venture.approve(AUSDC, address(exit_), type(uint256).max);

        // Plus $1.5M in each Morpho vault (a MetaMorpho V1 and a Vault V2), then SET_ALLOWANCE on the shares.
        venture.vaultDeposit(GAUNTLET_PRIME, 1_500_000e6);
        venture.vaultDeposit(STEAKHOUSE_PRIME, 1_500_000e6);
        venture.approve(GAUNTLET_PRIME, address(exit_), type(uint256).max);
        venture.approve(STEAKHOUSE_PRIME, address(exit_), type(uint256).max);

        assertGt(IERC20(AUSDC).balanceOf(address(venture)), 0, "venture holds an aUSDC position");
        assertGt(IERC20(GAUNTLET_PRIME).balanceOf(address(venture)), 0, "venture holds Gauntlet shares");
        assertGt(IERC20(STEAKHOUSE_PRIME).balanceOf(address(venture)), 0, "venture holds Steakhouse shares");
    }

    function _exitVaultFully(address vault) internal {
        uint256 before = IERC20(USDC).balanceOf(address(venture));
        uint256 position = IERC4626(vault).convertToAssets(IERC20(vault).balanceOf(address(venture)));

        vm.prank(operator);
        exit_.exitVault(vault, type(uint256).max);

        assertEq(IERC20(vault).balanceOf(address(venture)), 0, "position fully closed");
        assertApproxEqAbs(IERC20(USDC).balanceOf(address(venture)) - before, position, 2, "underlying back in treasury");
        assertEq(IERC20(USDC).balanceOf(operator), 0, "operator got nothing");
        assertEq(IERC20(vault).balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
        assertEq(IERC20(USDC).balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
    }

    function testFork_ExitVault_GauntletPrime_MetaMorphoV1() public {
        _exitVaultFully(GAUNTLET_PRIME);
    }

    function testFork_ExitVault_SteakhousePrime_VaultV2() public {
        // Vault V2 reports maxRedeem == 0 by design; redeem itself must still work.
        assertEq(IERC4626(STEAKHOUSE_PRIME).maxRedeem(address(venture)), 0);
        _exitVaultFully(STEAKHOUSE_PRIME);
    }

    function testFork_ExitVault_PartialShares() public {
        uint256 shares = IERC20(GAUNTLET_PRIME).balanceOf(address(venture));

        vm.prank(operator);
        exit_.exitVault(GAUNTLET_PRIME, shares / 2);

        assertEq(IERC20(GAUNTLET_PRIME).balanceOf(address(venture)), shares - shares / 2, "rest of position stays put");
        assertApproxEqAbs(IERC20(USDC).balanceOf(address(venture)), 750_000e6, 2, "half the position lands in treasury");
    }

    function testFork_ExitMorphoBlue_CannotTouchVaultShares() public {
        // Vault deposits leave the venture with zero Blue supply shares: the vault holds the market
        // position. Authorizing the wrapper on Morpho therefore gives it nothing to withdraw.
        venture.morphoAuthorize(MORPHO, address(exit_), true);
        IMorphoBlue.MarketParams memory cbBtcUsdc = IMorphoBlue.MarketParams({
            loanToken: USDC,
            collateralToken: 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf,
            oracle: 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9,
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 0.86e18
        });

        vm.prank(operator);
        vm.expectRevert();
        exit_.exitMorphoBlue(MORPHO, cbBtcUsdc, 100_000e6, 0);
    }

    function testFork_YieldPositionGuardian_ReturnsFullPositionToTreasury() public {
        uint256 positionBefore = IERC20(AUSDC).balanceOf(address(venture));

        vm.prank(operator);
        exit_.exitAave(AAVE_POOL, AUSDC, USDC, type(uint256).max);

        assertEq(IERC20(AUSDC).balanceOf(address(venture)), 0, "position fully closed");
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(address(venture)),
            positionBefore,
            2,
            "underlying back in treasury (aUSDC is 1:1 modulo rounding)"
        );
        assertEq(IERC20(USDC).balanceOf(operator), 0, "operator got nothing");
        assertEq(IERC20(AUSDC).balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
        assertEq(IERC20(USDC).balanceOf(address(exit_)), 0, "nothing stranded in wrapper");
    }

    function testFork_YieldPositionGuardian_PartialWithdrawal() public {
        uint256 positionBefore = IERC20(AUSDC).balanceOf(address(venture));

        vm.prank(operator);
        exit_.exitAave(AAVE_POOL, AUSDC, USDC, 1_000_000e6);

        assertEq(IERC20(USDC).balanceOf(address(venture)), 1_000_000e6, "partial exit lands in treasury");
        assertApproxEqAbs(
            IERC20(AUSDC).balanceOf(address(venture)), positionBefore - 1_000_000e6, 2, "rest of position stays put"
        );
    }

    function testFork_Revert_NotOwner() public {
        address rando = address(0xBAD);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        exit_.exitAave(AAVE_POOL, AUSDC, USDC, 1);
    }
}
