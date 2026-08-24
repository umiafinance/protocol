// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ContinuousClearingAuction} from "@continuous-clearing-auction/ContinuousClearingAuction.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Bid} from "@continuous-clearing-auction/libraries/BidLib.sol";
import {FixedPoint96} from "@continuous-clearing-auction/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {CCAExitHelper} from "../../src/periphery/CCAExitHelper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// Exercises CCAExitHelper against a real CCA auction driven to a live "out-bid" state.
/// requiredCurrencyRaised == 0 keeps the auction graduated from the first block, so an
/// out-bid bid is exitable before endBlock — the case the two-tx flow existed for.
/// chainid is 31337 here, so the helper's _getBlockNumberish() == block.number and vm.roll
/// fully controls it (no ArbSys mock needed).
contract CCAExitHelperTest is Test {
    using FixedPointMathLib for uint256;

    CCAExitHelper helper;

    address tokensRecipient = makeAddr("tokensRecipient");
    address fundsRecipient = makeAddr("fundsRecipient");

    uint256 constant TICK_SPACING = 100 << FixedPoint96.RESOLUTION;
    uint256 constant FLOOR_PRICE = 1000 << FixedPoint96.RESOLUTION;
    uint128 constant TOTAL_SUPPLY = 1000e18;
    uint256 constant AUCTION_DURATION = 100;
    uint24 constant MPS_PER_STEP = 100_000;
    uint40 constant BLOCKS_PER_STEP = 50;

    function setUp() public {
        helper = new CCAExitHelper();
    }

    // 1-indexed like the CCA test suite: tick 1 == floor.
    function _tickPrice(uint256 tickNumber) internal pure returns (uint256) {
        return FLOOR_PRICE + (tickNumber - 1) * TICK_SPACING;
    }

    function _inputForTokens(uint256 tokens, uint256 maxPrice) internal pure returns (uint128) {
        return uint128(tokens.fullMulDivUp(maxPrice, FixedPoint96.Q96));
    }

    function _stepsData() internal pure returns (bytes memory) {
        return abi.encodePacked(MPS_PER_STEP, BLOCKS_PER_STEP, MPS_PER_STEP, BLOCKS_PER_STEP);
    }

    function _deployAuction(uint128 requiredCurrencyRaised)
        internal
        returns (ContinuousClearingAuction auction, uint64 startBlock_)
    {
        MockERC20 token = new MockERC20("Token", "TKN", 18);
        startBlock_ = uint64(block.number);

        AuctionParameters memory params = AuctionParameters({
            currency: address(0),
            tokensRecipient: tokensRecipient,
            fundsRecipient: fundsRecipient,
            startBlock: startBlock_,
            endBlock: startBlock_ + uint64(AUCTION_DURATION),
            claimBlock: startBlock_ + uint64(AUCTION_DURATION) + 10,
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: requiredCurrencyRaised,
            auctionStepsData: _stepsData()
        });

        auction = new ContinuousClearingAuction(address(token), TOTAL_SUPPLY, params, address(0));
        token.mint(address(auction), TOTAL_SUPPLY);
        auction.onTokensReceived();
    }

    function _bid(ContinuousClearingAuction auction, address bidder, uint256 maxPrice, uint128 amount)
        internal
        returns (uint256)
    {
        vm.deal(bidder, uint256(amount));
        vm.prank(bidder);
        return auction.submitBid{value: amount}(maxPrice, amount, bidder, bytes(""));
    }

    /// Drives `auction` to the block right after `owner`'s low bid is out-bid by a large
    /// higher bid, ready for a live exit. Returns the bid, the (stored) last-fully-filled
    /// hint, and the bid amount. `submitBid` checkpoints the clearing price *before* counting
    /// the new bid's demand, so the out-bidding bid at `startBlock_ + 1` only moves the
    /// clearing at the *next* checkpoint. Landing the exit at `startBlock_ + 2` lets its
    /// internal checkpoint write the first checkpoint whose clearing exceeds `owner`'s bid.
    function _setupOutbidBid(uint128 requiredCurrencyRaised, address owner)
        internal
        returns (ContinuousClearingAuction auction, uint256 bidId, uint64 lastFullyFilled, uint128 bidAmount)
    {
        uint64 startBlock_;
        (auction, startBlock_) = _deployAuction(requiredCurrencyRaised);

        vm.roll(startBlock_);
        bidAmount = _inputForTokens(1e18, _tickPrice(2));
        bidId = _bid(auction, owner, _tickPrice(2), bidAmount);

        lastFullyFilled = startBlock_ + 1;
        vm.roll(lastFullyFilled);
        _bid(auction, makeAddr("outbidder"), _tickPrice(3), _inputForTokens(TOTAL_SUPPLY, _tickPrice(3)));

        vm.roll(startBlock_ + 2);
    }

    function test_exitOutbidBid_singleTx_refundsOwner() public {
        address owner = makeAddr("owner");
        (ContinuousClearingAuction auction, uint256 bidId, uint64 lastFullyFilled, uint128 bidAmount) =
            _setupOutbidBid(0, owner);

        assertEq(auction.bids(bidId).exitedBlock, 0, "precondition: bid is active");
        uint256 ownerBalanceBefore = owner.balance;

        // Called by the test contract, not the owner: exits are permissionless and the
        // refund must still go to the stored bid owner.
        helper.exitOutbidBid(IContinuousClearingAuction(address(auction)), bidId, lastFullyFilled);

        Bid memory bid = auction.bids(bidId);
        assertTrue(bid.exitedBlock != 0, "bid exited in a single transaction");
        assertGt(owner.balance, ownerBalanceBefore, "owner received a refund");
        assertLe(owner.balance - ownerBalanceBefore, bidAmount, "refund cannot exceed the bid amount");
        assertEq(address(helper).balance, 0, "helper never custodies funds");
    }

    /// The one-tx wrapper must be byte-for-byte equivalent to the two-tx flow it replaces
    /// (#1643: explicit checkpoint() then exitPartiallyFilledBid with the now-stored current
    /// block). Two auctions deployed and driven in lockstep, then exited each way at the same
    /// block, must yield identical refund, tokensFilled, and exitedBlock.
    function test_exitOutbidBid_matchesTwoTxCheckpointThenExit() public {
        address twoTxOwner = makeAddr("twoTxOwner");
        address wrapperOwner = makeAddr("wrapperOwner");
        (ContinuousClearingAuction twoTx, uint64 startBlock_) = _deployAuction(0);
        (ContinuousClearingAuction wrapper, uint64 wrapperStart) = _deployAuction(0);
        assertEq(startBlock_, wrapperStart, "twin auctions must share a start block for lockstep");

        vm.roll(startBlock_);
        uint128 amount = _inputForTokens(1e18, _tickPrice(2));
        uint256 twoTxBid = _bid(twoTx, twoTxOwner, _tickPrice(2), amount);
        uint256 wrapperBid = _bid(wrapper, wrapperOwner, _tickPrice(2), amount);

        uint64 lastFullyFilled = startBlock_ + 1;
        vm.roll(lastFullyFilled);
        uint128 outbidAmount = _inputForTokens(TOTAL_SUPPLY, _tickPrice(3));
        _bid(twoTx, makeAddr("twoTxOutbidder"), _tickPrice(3), outbidAmount);
        _bid(wrapper, makeAddr("wrapperOutbidder"), _tickPrice(3), outbidAmount);

        vm.roll(startBlock_ + 2);

        uint256 twoTxBefore = twoTxOwner.balance;
        twoTx.checkpoint();
        twoTx.exitPartiallyFilledBid(twoTxBid, lastFullyFilled, uint64(block.number));
        uint256 twoTxRefund = twoTxOwner.balance - twoTxBefore;

        uint256 wrapperBefore = wrapperOwner.balance;
        helper.exitOutbidBid(IContinuousClearingAuction(address(wrapper)), wrapperBid, lastFullyFilled);
        uint256 wrapperRefund = wrapperOwner.balance - wrapperBefore;

        assertEq(wrapperRefund, twoTxRefund, "wrapper refund must equal the two-tx flow");
        assertEq(
            wrapper.bids(wrapperBid).tokensFilled,
            twoTx.bids(twoTxBid).tokensFilled,
            "wrapper tokensFilled must equal the two-tx flow"
        );
        assertEq(
            wrapper.bids(wrapperBid).exitedBlock,
            twoTx.bids(twoTxBid).exitedBlock,
            "wrapper exitedBlock must equal the two-tx flow"
        );
    }

    function test_exitOutbidBid_revertsWhenAlreadyExited() public {
        address owner = makeAddr("owner");
        (ContinuousClearingAuction auction, uint256 bidId, uint64 lastFullyFilled,) = _setupOutbidBid(0, owner);

        helper.exitOutbidBid(IContinuousClearingAuction(address(auction)), bidId, lastFullyFilled);

        vm.expectRevert(IContinuousClearingAuction.BidAlreadyExited.selector);
        helper.exitOutbidBid(IContinuousClearingAuction(address(auction)), bidId, lastFullyFilled);
    }

    function test_exitOutbidBid_revertsWhenNotGraduated() public {
        address owner = makeAddr("owner");
        (ContinuousClearingAuction auction, uint256 bidId, uint64 lastFullyFilled,) =
            _setupOutbidBid(type(uint128).max, owner);

        vm.expectRevert(IContinuousClearingAuction.CannotPartiallyExitBidBeforeGraduation.selector);
        helper.exitOutbidBid(IContinuousClearingAuction(address(auction)), bidId, lastFullyFilled);
    }

    function test_exitOutbidBid_revertsWhenStillWinning() public {
        (ContinuousClearingAuction auction, uint64 startBlock_) = _deployAuction(0);

        vm.roll(startBlock_);
        // A lone high bid is never out-bid: no stored checkpoint clears above it, so no valid
        // last-fully-filled hint exists and the exit must revert.
        uint256 bidId = _bid(auction, makeAddr("owner"), _tickPrice(5), _inputForTokens(1e18, _tickPrice(5)));

        vm.roll(block.number + 1);

        vm.expectRevert(IContinuousClearingAuction.InvalidLastFullyFilledCheckpointHint.selector);
        helper.exitOutbidBid(IContinuousClearingAuction(address(auction)), bidId, startBlock_);
    }
}
