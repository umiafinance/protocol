// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IContinuousClearingAuction} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ValidationHookLib} from "@continuous-clearing-auction/libraries/ValidationHookLib.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {Venture} from "../../src/core/Venture.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";

/// @notice The production launch order on real contracts: hook, venture created with it, setCCA, gated bid, migrate.
contract GatedVentureE2ETest is DecisionMarketBase {
    uint256 internal constant PERMIT_SIGNER_PK = 0xbeef;
    address internal hookAdmin = makeAddr("hookAdmin");

    UmiaValidationHook internal gateHook;
    UmiaLBP internal ventureLbp;
    IContinuousClearingAuction internal cca;
    LBPBlockConfig internal lbpBlocks;

    function setUp() public override {
        super.setUp();
        gateHook = new UmiaValidationHook(hookAdmin, address(0), vm.addr(PERMIT_SIGNER_PK));

        (, address payable ventureAddr, LBPBlockConfig memory cfg) =
            _createVentureWithPendingLBP(hub, alice, "gatedUMO", "GATED", 1_000_000e18, 5_000_000, address(gateHook));
        lbpBlocks = cfg;
        ventureLbp = UmiaLBP(payable(Venture(ventureAddr).lbp()));
        cca = IContinuousClearingAuction(address(ventureLbp.initializer()));
    }

    function test_ventureIsCreatedWithTheHookAsItsImmutableValidationHook() public view {
        assertEq(address(cca.validationHook()), address(gateHook));
        assertEq(gateHook.cca(), address(0));
    }

    function test_unpairedHookPassesBids() public {
        _runAuctionAndMigrate(address(ventureLbp), lbpBlocks);
        assertEq(cca.nextBidId(), 1);
        assertTrue(ventureLbp.migrated());
    }

    function test_pairGateBidAndMigrate() public {
        vm.startPrank(hookAdmin);
        gateHook.setCCA(address(cca));
        gateHook.enableStep(0, new bytes32[](0), new string[](0));
        gateHook.enableStepPermit(0);
        vm.stopPrank();
        assertEq(gateHook.cca(), address(cca));
        assertEq(gateHook.getSteps().length, 2);

        uint128 amount = _auctionBidAmount(250_000e18);
        vm.roll(lbpBlocks.startBlock);
        _fundAuctionBidder(auctionBidder, address(cca), amount);
        vm.prank(auctionBidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidationHookLib.ValidationHookCallFailed.selector,
                abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0)
            )
        );
        cca.submitBid(AUCTION_TARGET_PRICE, amount, auctionBidder, AUCTION_FLOOR_PRICE, bytes(""));

        bytes32 nonce = keccak256("gated-e2e");
        bytes memory hookData = _permitHookData(auctionBidder, 0, nonce, block.timestamp + 1 hours, amount);
        _runAuctionAndMigrate(address(ventureLbp), lbpBlocks, 250_000e18, hookData);

        assertEq(cca.nextBidId(), 1);
        assertTrue(gateHook.isPermitNonceUsed(nonce));
        assertTrue(ventureLbp.migrated());
    }

    function test_setCCAIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        gateHook.setCCA(address(cca));
    }

    function _permitHookData(address wallet, uint256 step, bytes32 nonce, uint256 deadline, uint128 amount)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(gateHook.SERVER_PERMIT_TYPEHASH(), wallet, step, nonce, deadline, amount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", gateHook.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PERMIT_SIGNER_PK, digest);
        return abi.encodePacked(uint8(0x01), abi.encode(step, nonce, deadline, abi.encodePacked(r, s, v)));
    }
}
