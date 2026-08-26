// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IContinuousClearingAuction} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Venture} from "../../src/core/Venture.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";

contract MockArbSys {
    uint256 internal _arbBlockNumber;

    function setArbBlockNumber(uint256 value) external {
        _arbBlockNumber = value;
    }

    function arbBlockNumber() external view returns (uint256) {
        return _arbBlockNumber;
    }
}

/// @notice Full launch -> migrate -> sweep cycle on Arbitrum One's block domain, where
///         BlockNumberish reads ArbSys's fast L2 counter and raw block.number (the L1-anchored
///         counter, ~48x behind) never reaches the auction's endBlock. Regression test for the
///         LBP reading a different block domain than its CCA, which bricked migrate() forever.
contract UmiaLBPArbitrumDomainTest is DecisionMarketBase {
    address internal constant ARB_SYS = address(100);
    uint256 internal constant ARB_BLOCK_START = 335_000_000;

    UmiaLBP internal ventureLbp;
    IContinuousClearingAuction internal cca;
    LBPBlockConfig internal lbpBlocks;

    function setUp() public override {
        super.setUp();

        vm.etch(ARB_SYS, address(new MockArbSys()).code);
        vm.chainId(42_161);
        _setArbBlockNumber(ARB_BLOCK_START);

        lbpBlocks = LBPBlockConfig({
            startBlock: uint64(ARB_BLOCK_START + 1),
            endBlock: uint64(ARB_BLOCK_START + 101),
            migrationBlock: uint64(ARB_BLOCK_START + 201),
            sweepBlock: uint64(ARB_BLOCK_START + 401)
        });

        (, address payable ventureAddr) =
            _createVentureWithPendingLBP(hub, alice, "arbUMO", "ARB", 1_000_000e18, 5_000_000, address(0), lbpBlocks);
        ventureLbp = UmiaLBP(payable(Venture(ventureAddr).lbp()));
        cca = IContinuousClearingAuction(address(ventureLbp.initializer()));
    }

    function _setArbBlockNumber(uint256 value) internal {
        MockArbSys(ARB_SYS).setArbBlockNumber(value);
    }

    function test_migrateAndSweep_followTheAuctionBlockDomain() public {
        _setArbBlockNumber(lbpBlocks.startBlock);
        uint128 bidAmount = _auctionBidAmount(250_000e18);
        _fundAuctionBidder(auctionBidder, address(cca), bidAmount);
        vm.prank(auctionBidder);
        cca.submitBid(AUCTION_TARGET_PRICE, bidAmount, auctionBidder, AUCTION_FLOOR_PRICE, bytes(""));

        _setArbBlockNumber(lbpBlocks.endBlock);
        cca.checkpoint();

        uint256 migrationWindow = uint256(lbpBlocks.endBlock) + hub.migrationDelayBlocks();

        _setArbBlockNumber(migrationWindow - 1);
        vm.expectRevert(IUmiaLBP.MigrationNotAllowed.selector);
        ventureLbp.migrate();

        _setArbBlockNumber(migrationWindow);
        assertLt(block.number, lbpBlocks.startBlock, "raw block.number must stay far below the L2 domain");
        ventureLbp.migrate();
        assertTrue(ventureLbp.migrated());
        assertEq(ventureLbp.migratedAtBlock(), migrationWindow);

        uint256 sweepWindow = migrationWindow + hub.sweepDelayBlocks();

        _setArbBlockNumber(sweepWindow - 1);
        vm.expectRevert(IUmiaLBP.SweepNotAllowed.selector);
        ventureLbp.sweepToken();
        vm.expectRevert(IUmiaLBP.SweepNotAllowed.selector);
        ventureLbp.sweepCurrency();

        _setArbBlockNumber(sweepWindow);
        ventureLbp.sweepToken();
        ventureLbp.sweepCurrency();
    }
}
