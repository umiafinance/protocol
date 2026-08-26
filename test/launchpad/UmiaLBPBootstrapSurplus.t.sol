// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {Venture} from "../../src/core/Venture.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";

contract UmiaLBPBootstrapSurplusTest is DecisionMarketBase {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000e18;

    function _migratedVenture() internal returns (address payable ventureAddr, ISpotLiquidityVault vault) {
        (, ventureAddr) = _createVentureWithLBP(hub, alice, "surplusVenture", "SRP", TOTAL_SUPPLY);
        vault = ISpotLiquidityVault(hub.ventureLiquidityVault(ventureAddr));
    }

    function test_bootstrap_forwardsSurplusToVentureTreasury() public {
        (address payable ventureAddr, ISpotLiquidityVault vault) = _migratedVenture();
        address token = Venture(ventureAddr).token();

        assertEq(IERC20(token).balanceOf(address(vault)), 0, "vault holds idle venture tokens");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds idle money");

        assertGt(IERC20(token).balanceOf(ventureAddr), 0, "treasury did not receive the surplus");
    }

    function test_bootstrap_tokenConservation() public {
        (address payable ventureAddr, ISpotLiquidityVault vault) = _migratedVenture();
        address token = Venture(ventureAddr).token();
        address lbp = Venture(ventureAddr).lbp();
        address auction = address(UmiaLBP(payable(lbp)).initializer());

        uint256 inTreasury = IERC20(token).balanceOf(ventureAddr);
        uint256 inAuction = IERC20(token).balanceOf(auction);
        uint256 inPool = IERC20(token).balanceOf(address(manager));

        assertEq(IERC20(token).balanceOf(lbp), 0, "LBP kept tokens");
        assertEq(inTreasury + inAuction + inPool, TOTAL_SUPPLY, "token conservation");

        (uint256 ventureAssets,) = vault.totalAssets();
        assertApproxEqAbs(ventureAssets, inPool, 10, "vault NAV != in-pool reserves");
    }

    function test_bootstrap_sharesMatchPoolLiquidity() public {
        (, ISpotLiquidityVault vault) = _migratedVenture();
        assertEq(vault.totalShares(), uint256(vault.currentLiquidity()), "shares drifted from pool liquidity");
    }

    /// @dev A 95% auction split leaves a reserve too small to pair with the money raised, so the
    ///      pool runs out of tokens first and the leftover is money rather than tokens.
    function test_bootstrap_forwardsMoneySurplusWhenTokensRunOutFirst() public {
        (, address payable ventureAddr, LBPBlockConfig memory blocks) =
            _createVentureWithPendingLBP(hub, alice, "reserveBoundVenture", "RSV", TOTAL_SUPPLY, 9_500_000);
        address lbp = Venture(ventureAddr).lbp();

        vm.recordLogs();
        _runAuctionAndMigrate(lbp, blocks, 475_000e18);
        (, uint256 moneySurplus) = _readSurplusForwarded(vm.getRecordedLogs());

        address vault = hub.ventureLiquidityVault(ventureAddr);
        address token = Venture(ventureAddr).token();

        assertGt(moneySurplus, 0, "leftover money was not forwarded");
        assertEq(usdc.balanceOf(vault), 0, "vault holds idle money");
        assertEq(IERC20(token).balanceOf(vault), 0, "vault holds idle venture tokens");
        assertGt(usdc.balanceOf(ventureAddr), 0, "treasury received no money");
    }

    /// @dev The vault is deployed with CREATE from the LBP, so its address is predictable before
    ///      migration. Pre-funding it must neither brick `migrate()` nor strand the donation.
    function test_bootstrap_prefundedVaultDoesNotBrickMigration() public {
        uint256 donation = 1_000_000e6;

        (, address payable ventureAddr, LBPBlockConfig memory blocks) =
            _createVentureWithPendingLBP(hub, alice, "prefundedVenture", "PRE", TOTAL_SUPPLY);
        address lbp = Venture(ventureAddr).lbp();

        address predictedVault = vm.computeCreateAddress(lbp, 1);
        usdc.mint(predictedVault, donation);

        _runAuctionAndMigrate(lbp, blocks);

        address vault = hub.ventureLiquidityVault(ventureAddr);
        assertEq(vault, predictedVault, "vault address prediction drifted");

        address token = Venture(ventureAddr).token();
        assertEq(IERC20(token).balanceOf(vault), 0, "vault holds idle venture tokens");
        assertEq(usdc.balanceOf(vault), 0, "donated money stranded in the vault");
        assertGe(usdc.balanceOf(ventureAddr), donation, "treasury did not receive the donation");
        assertGt(usdc.balanceOf(address(manager)), 0, "pool holds no money");
    }

    /// @dev The event must report what the pool absorbed, not what the LBP handed over. Those
    ///      differ by the whole surplus, so a regression here silently overstates indexed deposits.
    function test_bootstrap_depositEventReportsAbsorbedNotHandedOver() public {
        (, address payable ventureAddr, LBPBlockConfig memory blocks) =
            _createVentureWithPendingLBP(hub, alice, "depositEventVenture", "DEP", TOTAL_SUPPLY);
        address lbp = Venture(ventureAddr).lbp();

        vm.recordLogs();
        _runAuctionAndMigrate(lbp, blocks);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (uint256 ventureUsed, uint256 moneyUsed) = _readDeposit(entries);
        (uint256 ventureSurplus,) = _readSurplusForwarded(entries);

        address token = Venture(ventureAddr).token();

        assertGt(ventureSurplus, 0, "scenario has no surplus, test proves nothing");
        assertEq(ventureUsed, IERC20(token).balanceOf(address(manager)), "reported more than the pool absorbed");
        assertEq(moneyUsed, usdc.balanceOf(address(manager)), "reported more money than the pool absorbed");
    }

    function _readDeposit(Vm.Log[] memory entries) internal pure returns (uint256 ventureUsed, uint256 moneyUsed) {
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == ISpotLiquidityVault.Deposit.selector) {
                (ventureUsed, moneyUsed,) = abi.decode(entries[i].data, (uint256, uint256, uint256));
                return (ventureUsed, moneyUsed);
            }
        }
        revert("Deposit not emitted");
    }

    function _readSurplusForwarded(Vm.Log[] memory entries)
        internal
        pure
        returns (uint256 ventureAmount, uint256 moneyAmount)
    {
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == ISpotLiquidityVault.BootstrapSurplusForwarded.selector) {
                return abi.decode(entries[i].data, (uint256, uint256));
            }
        }
        revert("BootstrapSurplusForwarded not emitted");
    }
}
