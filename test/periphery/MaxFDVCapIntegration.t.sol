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
import {ValidationHookLib} from "@continuous-clearing-auction/libraries/ValidationHookLib.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MaxFDVCapIntegrationTest is Test {
    UmiaValidationHook hook;
    ContinuousClearingAuction auction;
    MockERC20 token;

    address admin = makeAddr("admin");
    address tokensRecipient = makeAddr("tokensRecipient");
    address fundsRecipient = makeAddr("fundsRecipient");

    uint256 constant TICK_SPACING = 100 << FixedPoint96.RESOLUTION;
    uint256 constant FLOOR_PRICE = 1000 << FixedPoint96.RESOLUTION;
    uint128 constant TOTAL_SUPPLY = 1000e18;
    uint256 constant AUCTION_DURATION = 100;
    uint24 constant MPS_PER_STEP = 100_000;
    uint40 constant BLOCKS_PER_STEP = 50;

    function _tickPrice(uint256 ticksAboveFloor) internal pure returns (uint256) {
        return FLOOR_PRICE + ticksAboveFloor * TICK_SPACING;
    }

    function _maxRaise(uint256 capPrice) internal pure returns (uint256) {
        return (uint256(TOTAL_SUPPLY) * capPrice) / FixedPoint96.Q96;
    }

    function _stepsData() internal pure returns (bytes memory) {
        return abi.encodePacked(MPS_PER_STEP, BLOCKS_PER_STEP, MPS_PER_STEP, BLOCKS_PER_STEP);
    }

    function _deployAuction(uint256 capPrice) internal returns (uint64 startBlock_, uint64 endBlock_) {
        token = new MockERC20("Token", "TKN", 18);
        hook = new UmiaValidationHook(admin, address(0), address(0));

        startBlock_ = uint64(block.number);
        endBlock_ = startBlock_ + uint64(AUCTION_DURATION);
        uint64 claimBlock_ = endBlock_ + 10;

        AuctionParameters memory params = AuctionParameters({
            currency: address(0),
            tokensRecipient: tokensRecipient,
            fundsRecipient: fundsRecipient,
            startBlock: startBlock_,
            endBlock: endBlock_,
            claimBlock: claimBlock_,
            tickSpacing: TICK_SPACING,
            validationHook: address(hook),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0,
            auctionStepsData: _stepsData()
        });

        auction = new ContinuousClearingAuction(address(token), TOTAL_SUPPLY, params, address(0));
        token.mint(address(auction), TOTAL_SUPPLY);
        auction.onTokensReceived();

        vm.startPrank(admin);
        hook.setCCA(address(auction));
        if (capPrice > 0) {
            hook.setMaxBidPrice(capPrice);
        }
        vm.stopPrank();
    }

    function _bid(address bidder, uint256 maxPrice, uint128 amount) internal returns (uint256) {
        vm.deal(bidder, uint256(amount));
        vm.prank(bidder);
        return auction.submitBid{value: amount}(maxPrice, amount, bidder, bytes(""));
    }

    function _tryBid(address bidder, uint256 maxPrice, uint128 amount) internal returns (bool success) {
        vm.deal(bidder, uint256(amount));
        vm.prank(bidder);
        try auction.submitBid{value: amount}(maxPrice, amount, bidder, bytes("")) {
            success = true;
        } catch {
            success = false;
        }
    }

    function _settle(uint64 endBlock_) internal {
        vm.roll(endBlock_);
        auction.checkpoint();
    }

    // ─────────────────────────────────────────────────────────
    // Core FDV Cap Tests
    // ─────────────────────────────────────────────────────────

    function test_e2e_singleLargeBidAtCap_clearingCapped() public {
        uint256 capPrice = _tickPrice(10);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(capPrice);

        assertEq(hook.maxBidPrice(), capPrice, "cap should be stored on hook");
        uint256 maxRaise = _maxRaise(capPrice);

        vm.roll(startBlock_);
        uint256 nextBidBefore = auction.nextBidId();
        uint128 amount = uint128(maxRaise);
        uint256 bidId = _bid(makeAddr("alice"), capPrice, amount);

        assertEq(auction.nextBidId(), nextBidBefore + 1, "exactly 1 bid should exist");

        Bid memory bid = auction.bids(bidId);
        assertEq(bid.maxPrice, capPrice, "bid maxPrice should equal cap");
        assertEq(bid.owner, makeAddr("alice"), "bid owner mismatch");

        _settle(endBlock_);

        assertEq(auction.clearingPrice(), capPrice, "clearing should equal cap with full demand at cap");
        assertLe(auction.currencyRaised(), maxRaise, "currency raised exceeds max FDV");
    }

    function test_e2e_bidAboveCap_reverts() public {
        uint256 capPrice = _tickPrice(5);
        (uint64 startBlock_,) = _deployAuction(capPrice);

        assertEq(hook.maxBidPrice(), capPrice, "cap should be set");

        vm.roll(startBlock_);

        uint256 nextBidBefore = auction.nextBidId();
        uint256 overPrice = _tickPrice(6);
        address bidder = makeAddr("bidder");
        uint128 amount = 1 ether;

        vm.deal(bidder, uint256(amount));
        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidationHookLib.ValidationHookCallFailed.selector,
                abi.encodeWithSelector(UmiaValidationHook.MaxBidPriceExceeded.selector)
            )
        );
        auction.submitBid{value: amount}(overPrice, amount, bidder, bytes(""));

        assertEq(auction.nextBidId(), nextBidBefore, "0 bids should exist after rejection");
        assertEq(hook.maxBidPrice(), capPrice, "cap should be unchanged after rejected bid");
    }

    function test_e2e_bidAtCap_succeeds() public {
        uint256 capPrice = _tickPrice(5);
        (uint64 startBlock_,) = _deployAuction(capPrice);

        vm.roll(startBlock_);
        uint256 nextBidBefore = auction.nextBidId();
        uint256 bidId = _bid(makeAddr("bidder"), capPrice, 1 ether);

        assertEq(auction.nextBidId(), nextBidBefore + 1, "one bid should be created");
        Bid memory bid = auction.bids(bidId);
        assertEq(bid.maxPrice, capPrice, "bid maxPrice should equal cap");
        assertEq(bid.owner, makeAddr("bidder"), "bid owner mismatch");
    }

    function test_e2e_bidOneTickBelowCap_succeeds() public {
        uint256 capPrice = _tickPrice(5);
        (uint64 startBlock_,) = _deployAuction(capPrice);

        vm.roll(startBlock_);
        uint256 nextBidBefore = auction.nextBidId();
        uint256 expectedPrice = capPrice - TICK_SPACING;
        uint256 bidId = _bid(makeAddr("bidder"), expectedPrice, 1 ether);

        assertEq(auction.nextBidId(), nextBidBefore + 1, "one bid should be created");
        Bid memory bid = auction.bids(bidId);
        assertEq(bid.maxPrice, expectedPrice, "bid maxPrice should be one tick below cap");
    }

    // ─────────────────────────────────────────────────────────
    // Stress Tests
    // ─────────────────────────────────────────────────────────

    function test_e2e_manyBiddersAtCap_clearingCapped() public {
        uint256 capPrice = _tickPrice(10);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(capPrice);

        vm.roll(startBlock_);

        uint256 maxRaise = _maxRaise(capPrice);
        uint128 bidSize = uint128(maxRaise / 5);
        assertGt(bidSize, 0, "bid size must be non-zero");

        uint256 nextBidBefore = auction.nextBidId();

        for (uint256 i; i < 5; i++) {
            address bidder = makeAddr(string.concat("bidder", vm.toString(i)));
            _bid(bidder, capPrice, bidSize);
        }
        assertEq(auction.nextBidId(), nextBidBefore + 5, "exactly 5 bids should be created");

        for (uint256 i; i < 5; i++) {
            Bid memory bid = auction.bids(nextBidBefore + i);
            assertEq(bid.maxPrice, capPrice, string.concat("bid ", vm.toString(i), " maxPrice should equal cap"));
            assertEq(
                bid.owner,
                makeAddr(string.concat("bidder", vm.toString(i))),
                string.concat("bid ", vm.toString(i), " owner mismatch")
            );
        }

        vm.roll(startBlock_ + 1);
        auction.checkpoint();
        assertEq(auction.clearingPrice(), capPrice, "clearing should reach cap after 5 bids fill demand");

        uint256 nextBidAfterFill = auction.nextBidId();
        for (uint256 i = 5; i < 20; i++) {
            address bidder = makeAddr(string.concat("bidder", vm.toString(i)));
            bool ok = _tryBid(bidder, capPrice, bidSize);
            assertFalse(ok, string.concat("bidder", vm.toString(i), " should be rejected after cap reached"));
        }
        assertEq(auction.nextBidId(), nextBidAfterFill, "no new bids should be created after cap reached");

        _settle(endBlock_);

        assertEq(auction.clearingPrice(), capPrice, "clearing should equal cap with excess demand at cap");
        assertLe(auction.currencyRaised(), maxRaise, "currency raised exceeds max FDV");
    }

    function test_e2e_auctionFullWhenClearingReachesCap() public {
        uint256 capPrice = _tickPrice(3);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(capPrice);

        assertEq(hook.maxBidPrice(), capPrice, "cap should be set");
        uint256 maxRaise = _maxRaise(capPrice);

        vm.roll(startBlock_);

        uint128 bigAmount = uint128(maxRaise * 2);
        uint256 nextBidBefore = auction.nextBidId();
        uint256 whaleBid = _bid(makeAddr("whale"), capPrice, bigAmount);
        assertEq(auction.nextBidId(), nextBidBefore + 1, "exactly 1 bid (whale) should exist");

        Bid memory whale = auction.bids(whaleBid);
        assertEq(whale.maxPrice, capPrice, "whale bid maxPrice should equal cap");
        assertEq(whale.owner, makeAddr("whale"), "whale bid owner mismatch");

        vm.roll(startBlock_ + 1);
        auction.checkpoint();
        assertEq(auction.clearingPrice(), capPrice, "clearing should reach cap after whale's 2x demand");

        uint256 nextBidAfterWhale = auction.nextBidId();
        bool latecomerOk = _tryBid(makeAddr("latecomer"), capPrice, 1 ether);
        assertFalse(latecomerOk, "latecomer bid at cap should be rejected once clearing reached cap");
        assertEq(auction.nextBidId(), nextBidAfterWhale, "latecomer should not create a bid");

        _settle(endBlock_);

        assertEq(auction.clearingPrice(), capPrice, "clearing should equal cap at settlement");
        assertLe(auction.currencyRaised(), maxRaise, "currency raised exceeds max FDV");
        assertEq(auction.nextBidId(), nextBidBefore + 1, "still exactly 1 bid total");
    }

    function test_e2e_capAtFloorPlusTick_mostConstrained() public {
        uint256 capPrice = _tickPrice(1);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(capPrice);

        assertEq(hook.maxBidPrice(), capPrice, "cap should be floor + 1 tick");
        assertEq(capPrice, FLOOR_PRICE + TICK_SPACING, "capPrice should equal floor + tick");

        vm.roll(startBlock_);
        uint256 firstBidId = auction.nextBidId();
        uint256 bidId = _bid(makeAddr("bidder"), capPrice, 1 ether);
        assertEq(bidId, firstBidId, "first bid should get firstBidId");
        assertEq(auction.nextBidId(), firstBidId + 1, "exactly 1 bid should exist");

        Bid memory bid = auction.bids(bidId);
        assertEq(bid.maxPrice, capPrice, "bid maxPrice should equal cap (floor + 1 tick)");
        assertEq(bid.owner, makeAddr("bidder"), "bid owner mismatch");

        uint256 aboveCap = _tickPrice(2);
        address rejected = makeAddr("rejected");
        vm.deal(rejected, 1 ether);
        vm.prank(rejected);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidationHookLib.ValidationHookCallFailed.selector,
                abi.encodeWithSelector(UmiaValidationHook.MaxBidPriceExceeded.selector)
            )
        );
        auction.submitBid{value: 1 ether}(aboveCap, 1 ether, rejected, bytes(""));
        assertEq(auction.nextBidId(), firstBidId + 1, "still exactly 1 bid after rejection");

        _settle(endBlock_);
        assertLe(auction.clearingPrice(), capPrice, "clearing exceeds most constrained cap");
        assertLe(auction.currencyRaised(), _maxRaise(capPrice), "currency raised exceeds max FDV at tight cap");
    }

    // ─────────────────────────────────────────────────────────
    // Cap Mutation Tests
    // ─────────────────────────────────────────────────────────

    function test_e2e_ownerLowersCap_newBidsRejected() public {
        uint256 initialCap = _tickPrice(10);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(initialCap);

        assertEq(hook.maxBidPrice(), initialCap, "initial cap should be set");

        vm.roll(startBlock_);
        uint256 firstBidId = auction.nextBidId();
        uint256 aliceBidId = _bid(makeAddr("alice"), initialCap, 1 ether);
        assertEq(aliceBidId, firstBidId, "alice should get first bid ID");
        assertEq(auction.nextBidId(), firstBidId + 1, "exactly 1 bid after alice");

        Bid memory alice = auction.bids(aliceBidId);
        assertEq(alice.maxPrice, initialCap, "alice bid maxPrice should equal initial cap");
        assertEq(alice.owner, makeAddr("alice"), "alice bid owner mismatch");

        uint256 newCap = _tickPrice(5);
        vm.prank(admin);
        hook.setMaxBidPrice(newCap);
        assertEq(hook.maxBidPrice(), newCap, "cap should be lowered");

        address bob = makeAddr("bob");
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidationHookLib.ValidationHookCallFailed.selector,
                abi.encodeWithSelector(UmiaValidationHook.MaxBidPriceExceeded.selector)
            )
        );
        auction.submitBid{value: 1 ether}(initialCap, 1 ether, bob, bytes(""));
        assertEq(auction.nextBidId(), firstBidId + 1, "still 1 bid after bob's rejection");

        uint256 carolBid = _bid(makeAddr("carol"), newCap, 1 ether);
        assertEq(auction.nextBidId(), firstBidId + 2, "exactly 2 bids after carol");

        Bid memory carol = auction.bids(carolBid);
        assertEq(carol.maxPrice, newCap, "carol bid maxPrice should equal new cap");
        assertEq(carol.owner, makeAddr("carol"), "carol bid owner mismatch");

        _settle(endBlock_);
        assertLe(auction.clearingPrice(), newCap, "clearing exceeds lowered cap");
        assertLe(auction.currencyRaised(), _maxRaise(newCap), "currency raised exceeds lowered max FDV");
    }

    function test_e2e_ownerRaisesCap_newBidsAllowed() public {
        uint256 initialCap = _tickPrice(3);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(initialCap);

        assertEq(hook.maxBidPrice(), initialCap, "initial cap should be set");

        vm.roll(startBlock_);
        uint256 firstBidId = auction.nextBidId();
        uint256 aliceBidId = _bid(makeAddr("alice"), initialCap, 1 ether);
        assertEq(aliceBidId, firstBidId, "alice should get first bid ID");
        assertEq(auction.nextBidId(), firstBidId + 1, "exactly 1 bid after alice");

        Bid memory alice = auction.bids(aliceBidId);
        assertEq(alice.maxPrice, initialCap, "alice bid maxPrice should equal initial cap");
        assertEq(alice.owner, makeAddr("alice"), "alice bid owner mismatch");

        uint256 higherPrice = _tickPrice(5);
        bool rejected = _tryBid(makeAddr("rejected"), higherPrice, 1 ether);
        assertFalse(rejected, "bid above old cap should fail");
        assertEq(auction.nextBidId(), firstBidId + 1, "still 1 bid after rejection");

        uint256 newCap = _tickPrice(10);
        vm.prank(admin);
        hook.setMaxBidPrice(newCap);
        assertEq(hook.maxBidPrice(), newCap, "cap should be raised");

        uint256 bobBid = _bid(makeAddr("bob"), higherPrice, 1 ether);
        assertEq(auction.nextBidId(), firstBidId + 2, "exactly 2 bids after bob");

        Bid memory bob = auction.bids(bobBid);
        assertEq(bob.maxPrice, higherPrice, "bob bid maxPrice should equal higherPrice");
        assertEq(bob.owner, makeAddr("bob"), "bob bid owner mismatch");

        _settle(endBlock_);
        assertLe(auction.clearingPrice(), newCap, "clearing exceeds raised cap");
        assertLe(auction.currencyRaised(), _maxRaise(newCap), "currency raised exceeds raised max FDV");
    }

    function test_e2e_capRemoved_anyPriceAllowed() public {
        uint256 initialCap = _tickPrice(3);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(initialCap);

        assertEq(hook.maxBidPrice(), initialCap, "initial cap should be set");

        vm.roll(startBlock_);

        uint256 highPrice = _tickPrice(5);
        uint256 firstBidId = auction.nextBidId();
        bool rejected = _tryBid(makeAddr("rejected"), highPrice, 1 ether);
        assertFalse(rejected, "bid above cap should fail");
        assertEq(auction.nextBidId(), firstBidId, "0 bids after rejection");

        vm.prank(admin);
        hook.setMaxBidPrice(0);
        assertEq(hook.maxBidPrice(), 0, "cap should be removed");

        uint256 bidId = _bid(makeAddr("bidder"), highPrice, 1 ether);
        assertEq(bidId, firstBidId, "bidder should get first bid ID");
        assertEq(auction.nextBidId(), firstBidId + 1, "exactly 1 bid after cap removal");

        Bid memory bid = auction.bids(bidId);
        assertEq(bid.maxPrice, highPrice, "bid maxPrice should equal highPrice (above old cap)");
        assertEq(bid.owner, makeAddr("bidder"), "bid owner mismatch");

        _settle(endBlock_);
        assertGt(auction.clearingPrice(), 0, "clearing should be positive with 1 bid");
    }

    // ─────────────────────────────────────────────────────────
    // Overflow / Huge Amount Tests
    // ─────────────────────────────────────────────────────────

    function test_e2e_hugeAmountAtCap_noOverflow() public {
        uint256 capPrice = _tickPrice(50);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(capPrice);

        vm.roll(startBlock_);

        uint256 maxRaise = _maxRaise(capPrice);
        uint128 hugeAmount = uint128(maxRaise * 10);
        assertGt(hugeAmount, 0, "huge amount must be non-zero");

        uint256 nextBidBefore = auction.nextBidId();
        uint256 bidId = _bid(makeAddr("whale"), capPrice, hugeAmount);
        assertEq(auction.nextBidId(), nextBidBefore + 1, "whale bid should be created");

        Bid memory bid = auction.bids(bidId);
        assertEq(bid.maxPrice, capPrice, "bid maxPrice should equal cap");
        assertEq(bid.owner, makeAddr("whale"), "bid owner mismatch");

        _settle(endBlock_);
        assertLe(auction.clearingPrice(), capPrice, "clearing exceeds cap with huge bid");
        assertEq(auction.clearingPrice(), capPrice, "clearing should equal cap with 10x excess demand");
        assertLe(auction.currencyRaised(), maxRaise, "currency raised exceeds max FDV");
    }

    // ─────────────────────────────────────────────────────────
    // Negative Control
    // ─────────────────────────────────────────────────────────

    function test_e2e_noCap_thenWithCap_provesCapConstrains() public {
        uint256 highPrice = _tickPrice(20);
        uint128 bigAmount = uint128(_maxRaise(highPrice));
        uint256 capPrice = _tickPrice(5);

        // --- Auction 1: no cap ---
        (uint64 startBlock1, uint64 endBlock1) = _deployAuction(0);
        assertEq(hook.maxBidPrice(), 0, "uncapped auction should have no cap");

        vm.roll(startBlock1);
        uint256 firstBidId1 = auction.nextBidId();
        uint256 aliceBidId = _bid(makeAddr("alice"), highPrice, bigAmount);
        assertEq(aliceBidId, firstBidId1, "alice should get first bid ID");
        assertEq(auction.nextBidId(), firstBidId1 + 1, "exactly 1 bid in uncapped auction");

        _settle(endBlock1);
        uint256 uncappedClearing = auction.clearingPrice();
        uint256 uncappedRaised = auction.currencyRaised();
        assertGt(uncappedClearing, 0, "uncapped clearing should be positive");
        assertGt(uncappedClearing, capPrice, "uncapped clearing should exceed the cap we will set next");

        // --- Auction 2: with cap ---
        (uint64 startBlock2, uint64 endBlock2) = _deployAuction(capPrice);
        assertEq(hook.maxBidPrice(), capPrice, "capped auction should have cap set");

        vm.roll(startBlock2);
        uint256 firstBidId2 = auction.nextBidId();

        bool highBidOk = _tryBid(makeAddr("bob"), highPrice, bigAmount);
        assertFalse(highBidOk, "bob's high bid should be rejected with cap");
        assertEq(auction.nextBidId(), firstBidId2, "0 bids after bob's rejection");

        uint256 carolBidId = _bid(makeAddr("carol"), capPrice, uint128(_maxRaise(capPrice)));
        assertEq(carolBidId, firstBidId2, "carol should get first bid ID in capped auction");
        assertEq(auction.nextBidId(), firstBidId2 + 1, "exactly 1 bid in capped auction");

        Bid memory carol = auction.bids(carolBidId);
        assertEq(carol.maxPrice, capPrice, "carol bid maxPrice should equal cap");
        assertEq(carol.owner, makeAddr("carol"), "carol bid owner mismatch");

        _settle(endBlock2);
        uint256 cappedClearing = auction.clearingPrice();
        uint256 cappedRaised = auction.currencyRaised();

        assertEq(cappedClearing, capPrice, "capped clearing should equal cap with full demand");
        assertLt(cappedClearing, uncappedClearing, "capped clearing must be strictly less than uncapped");
        assertLe(cappedRaised, _maxRaise(capPrice), "capped raise exceeds max FDV");
        assertLe(cappedRaised, uncappedRaised, "capped raise should not exceed uncapped raise");
    }

    // ─────────────────────────────────────────────────────────
    // Currency Raised Bound
    // ─────────────────────────────────────────────────────────

    function test_e2e_currencyRaisedBounded() public {
        uint256 capPrice = _tickPrice(5);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(capPrice);

        assertEq(hook.maxBidPrice(), capPrice, "cap should be set");
        uint256 maxExpected = _maxRaise(capPrice);

        vm.roll(startBlock_);
        uint256 firstBidId = auction.nextBidId();
        uint128 amount = uint128(maxExpected * 3);
        uint256 bidId = _bid(makeAddr("whale"), capPrice, amount);
        assertEq(bidId, firstBidId, "whale should get first bid ID");
        assertEq(auction.nextBidId(), firstBidId + 1, "exactly 1 bid");

        Bid memory whale = auction.bids(bidId);
        assertEq(whale.maxPrice, capPrice, "whale bid maxPrice should equal cap");
        assertEq(whale.owner, makeAddr("whale"), "whale bid owner mismatch");

        _settle(endBlock_);

        assertEq(auction.clearingPrice(), capPrice, "clearing should equal cap with 3x excess demand");
        assertLe(auction.currencyRaised(), maxExpected + 1e18, "currency raised exceeds theoretical max + dust");
        assertGt(auction.currencyRaised(), 0, "currency raised should be positive");
    }

    // ─────────────────────────────────────────────────────────
    // Fuzz Tests
    // ─────────────────────────────────────────────────────────

    function test_fuzz_randomBidsBelowCap_invariantHolds(uint256 seed) public {
        uint256 capPrice = _tickPrice(20);
        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(capPrice);

        assertEq(hook.maxBidPrice(), capPrice, "fuzz: cap should be set");

        vm.roll(startBlock_);

        uint256 firstBidId = auction.nextBidId();
        uint256 accepted;
        for (uint256 i; i < 10; i++) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
            uint256 ticks = (entropy % 20) + 1;
            uint256 bidPrice = _tickPrice(ticks);
            uint128 amount = uint128(bound(entropy >> 8, 0.01 ether, 100 ether));

            address bidder = makeAddr(string.concat("fuzz", vm.toString(i)));
            bool ok = _tryBid(bidder, bidPrice, amount);
            if (ok) accepted++;
        }

        assertGt(accepted, 0, "fuzz: at least one bid should be accepted");
        assertEq(auction.nextBidId(), firstBidId + accepted, "fuzz: nextBidId should match accepted count");

        for (uint256 i; i < accepted; i++) {
            Bid memory bid = auction.bids(firstBidId + i);
            assertLe(bid.maxPrice, capPrice, "fuzz: every accepted bid maxPrice should be <= cap");
        }

        _settle(endBlock_);
        assertLe(auction.clearingPrice(), capPrice, "fuzz: clearing exceeds cap");
        assertLe(auction.currencyRaised(), _maxRaise(capPrice), "fuzz: currency raised exceeds max FDV");
    }

    function test_fuzz_capAndBid_invariant(uint256 capTicks, uint256 bidTicks, uint128 bidAmount) public {
        capTicks = bound(capTicks, 1, 50);
        uint256 capPrice = _tickPrice(capTicks);

        (uint64 startBlock_, uint64 endBlock_) = _deployAuction(capPrice);
        assertEq(hook.maxBidPrice(), capPrice, "fuzz: cap should be set");

        vm.roll(startBlock_);

        bidTicks = bound(bidTicks, 1, capTicks);
        bidAmount = uint128(bound(bidAmount, 0.001 ether, 1000 ether));
        uint256 bidPrice = _tickPrice(bidTicks);

        uint256 firstBidId = auction.nextBidId();
        bool ok = _tryBid(makeAddr("fuzzer"), bidPrice, bidAmount);
        assertTrue(ok, "fuzz: bid at or below cap should always succeed");
        assertEq(auction.nextBidId(), firstBidId + 1, "fuzz: exactly 1 bid should be created");

        Bid memory bid = auction.bids(firstBidId);
        assertEq(bid.maxPrice, bidPrice, "fuzz: bid maxPrice should match submitted price");
        assertEq(bid.owner, makeAddr("fuzzer"), "fuzz: bid owner mismatch");
        assertLe(bid.maxPrice, capPrice, "fuzz: bid maxPrice must be <= cap");

        _settle(endBlock_);
        assertLe(auction.clearingPrice(), capPrice, "fuzz: clearing exceeds cap");
        assertLe(auction.currencyRaised(), _maxRaise(capPrice), "fuzz: currency raised exceeds max FDV");
    }
}
