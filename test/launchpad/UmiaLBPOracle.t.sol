// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {ContinuousClearingAuctionFactory} from "@continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {ContinuousClearingAuction} from "@continuous-clearing-auction/ContinuousClearingAuction.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "@continuous-clearing-auction/../test/utils/AuctionStepsBuilder.sol";
import {PosmTestSetup} from "@uniswap/v4-periphery/test/shared/PosmTestSetup.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {SpotLiquidityVault} from "../../src/core/SpotLiquidityVault.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {UmiaHook} from "../../src/periphery/UmiaHook.sol";
import {UmiaLBPFactory} from "../../src/launchpad/UmiaLBPFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ILBPMigrationCallback} from "../../src/interfaces/ILBPMigrationCallback.sol";
import {SpotMarketOracle} from "../../src/libraries/SpotMarketOracle.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";

import {PositionDescriptor} from "@uniswap/v4-periphery/src/PositionDescriptor.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";

contract UmiaLBPOracleTest is Test, PosmTestSetup {
    address internal vaultCodePointer = SSTORE2.write(type(SpotLiquidityVault).creationCode);
    using AuctionStepsBuilder for bytes;
    using FixedPointMathLib for *;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    UmiaLBP public lbp;
    UmiaHook public umiaHook;
    ContinuousClearingAuctionFactory public ccaFactory;

    MockERC20 public token;
    MockERC20 public currency;

    address constant VENTURE = address(0x1111);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint128 constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 constant VENTURE_BPS = 2000;
    uint160 constant HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

    uint256 public constant FLOOR_PRICE = 1000 << FixedPoint96.RESOLUTION;
    uint256 public constant TICK_SPACING_CCA = 100 << FixedPoint96.RESOLUTION;

    uint64 startBlock;
    uint64 endBlock;
    uint64 migrationBlock;
    uint64 sweepBlock;
    uint256 nextTokenId;

    PoolKey poolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployPosm(manager);

        token = new MockERC20("Project Token", "PROJ", 18);
        currency = new MockERC20("Currency", "CURR", 18);

        ccaFactory = new ContinuousClearingAuctionFactory(address(0));
        umiaHook = _deployUmiaHook();

        // Pretend the test contract is the LBP factory: any caller of registerPool passes.
        vm.mockCall(address(this), abi.encodeWithSelector(bytes4(keccak256("isLBP(address)"))), abi.encode(true));

        nextTokenId = lpm.nextTokenId();

        startBlock = uint64(block.number + 1);
        endBlock = startBlock + 100;
        migrationBlock = endBlock + 100;
        sweepBlock = migrationBlock + 200;

        vm.mockCall(VENTURE, abi.encodeWithSelector(ILBPMigrationCallback.onLBPMigrated.selector), abi.encode());

        _deployAndMigrate();
    }

    function _deployUmiaHook() internal returns (UmiaHook hook) {
        (, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(UmiaHook).creationCode, abi.encode(address(this)));
        hook = new UmiaHook{salt: salt}(address(this));
        hook.initialize(address(this), IPoolManager(address(manager)));
    }

    function _deployAndMigrate() internal {
        bytes memory stepsData = AuctionStepsBuilder.init().addStep(100_000, 50).addStep(100_000, 50);
        bytes memory auctionParamsData = abi.encode(
            AuctionParameters({
                currency: address(currency),
                tokensRecipient: address(1),
                fundsRecipient: address(1),
                startBlock: startBlock,
                endBlock: endBlock,
                claimBlock: migrationBlock,
                tickSpacing: TICK_SPACING_CCA,
                validationHook: address(0),
                floorPrice: FLOOR_PRICE,
                requiredCurrencyRaised: 0,
                auctionStepsData: stepsData
            })
        );

        // The LBP derives its hub from the venture at construction and reads pool/timing params
        // from that hub at migrate() time. VENTURE is a placeholder EOA, so the test contract
        // acts as the hub; the vault's real full-range bootstrap still runs against the real
        // PoolManager.
        vm.mockCall(VENTURE, abi.encodeWithSelector(IVenture.HUB.selector), abi.encode(address(this)));
        vm.mockCall(
            address(this), abi.encodeWithSelector(IUmiaHub.ccaFactory.selector), abi.encode(address(ccaFactory))
        );
        vm.mockCall(
            address(this), abi.encodeWithSelector(IUmiaHub.migrationDelayBlocks.selector), abi.encode(uint64(100))
        );
        vm.mockCall(address(this), abi.encodeWithSelector(IUmiaHub.spotSwapFeeBps.selector), abi.encode(uint16(30)));
        vm.mockCall(
            address(this), abi.encodeWithSelector(IUmiaHub.defaultPoolTickSpacing.selector), abi.encode(int24(60))
        );

        lbp = new UmiaLBP(
            address(token),
            TOTAL_SUPPLY,
            5_000_000,
            address(currency),
            auctionParamsData,
            IPoolManager(address(manager)),
            IUmiaHook(address(umiaHook)),
            VENTURE,
            VENTURE_BPS,
            vaultCodePointer
        );

        vm.mockCall(VENTURE, abi.encodeWithSignature("token()"), abi.encode(address(token)));
        vm.mockCall(VENTURE, abi.encodeWithSignature("moneyToken()"), abi.encode(address(currency)));
        vm.mockCall(VENTURE, abi.encodeWithSignature("lbp()"), abi.encode(address(lbp)));
        vm.mockCall(address(this), abi.encodeWithSignature("registerSpotLiquidityVault(address,address)"), abi.encode());

        token.mint(address(this), TOTAL_SUPPLY);
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        IContinuousClearingAuction auction = IContinuousClearingAuction(address(lbp.initializer()));

        vm.roll(startBlock);
        uint256 targetPrice = FLOOR_PRICE + TICK_SPACING_CCA;
        uint128 bidAmount = uint128(uint256(250_000e18).fullMulDivUp(targetPrice, FixedPoint96.Q96));

        _submitBid(auction, alice, bidAmount, targetPrice, FLOOR_PRICE, 0);
        _submitBid(auction, bob, bidAmount, targetPrice, FLOOR_PRICE, 1);

        vm.roll(endBlock);
        auction.checkpoint();

        vm.roll(uint256(lbp.initializer().endBlock()) + lbp.hub().migrationDelayBlocks());
        lbp.migrate();

        // No LP NFT in the vault model; the canonical pool key is deterministic from the params.
        (address c0, address c1) = address(token) < address(currency)
            ? (address(token), address(currency))
            : (address(currency), address(token));
        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(umiaHook))
        });
    }

    function _submitBid(
        IContinuousClearingAuction auction,
        address bidder,
        uint128 amount,
        uint256 price,
        uint256 prevPrice,
        uint256 expectedId
    ) internal {
        currency.mint(bidder, amount);
        vm.prank(bidder);
        currency.approve(address(permit2), amount);
        vm.prank(bidder);
        permit2.approve(address(currency), address(auction), uint160(amount), uint48(block.timestamp + 1000));
        vm.prank(bidder);
        uint256 bidId = auction.submitBid(price, amount, bidder, prevPrice, bytes(""));
        assertEq(bidId, expectedId);
    }

    function _doSwap(uint256 amount, bool zeroForOne) internal {
        address swapper = makeAddr("swapper");
        MockERC20 inputToken = zeroForOne
            ? (Currency.unwrap(poolKey.currency0) == address(token) ? token : currency)
            : (Currency.unwrap(poolKey.currency1) == address(token) ? token : currency);

        inputToken.mint(swapper, amount);
        vm.prank(swapper);
        inputToken.approve(address(swapRouter), amount);

        vm.prank(swapper);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ============ Tests ============

    function test_OracleInitializedAfterMigration() public view {
        PoolId id = poolKey.toId();
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = umiaHook.oracleStates(id);
        assertEq(cardinality, 1);
        assertEq(cardinalityNext, 100, "Migration should grow cardinalityNext to the bootstrap seed");
        assertEq(index, 0);
    }

    function test_ObserveCurrentTick() public view {
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;

        (int48[] memory tickCumulatives,) = umiaHook.observe(poolKey, secondsAgos);
        assertEq(tickCumulatives.length, 1);
    }

    function test_SwapWritesObservation() public {
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(currency);

        // Migration already grew cardinalityNext to 250, so index will advance
        vm.warp(block.timestamp + 60);
        _doSwap(1e18, zeroForOne);

        PoolId id = poolKey.toId();
        (uint16 index, uint16 cardinality,) = umiaHook.oracleStates(id);
        assertEq(index, 1, "Oracle index should advance after swap");
        assertEq(cardinality, 100, "Cardinality should jump to cardinalityNext on first write");
    }

    function test_TWAPOverWindow() public {
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(currency);

        // Migration already provides 100 observation slots
        // First swap at t+60
        vm.warp(block.timestamp + 60);
        _doSwap(1e18, zeroForOne);

        // Second swap at t+120
        vm.warp(block.timestamp + 60);
        _doSwap(1e18, zeroForOne);

        // Query 60s TWAP (covers the window between the last two observations)
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 60;
        secondsAgos[1] = 0;

        (int48[] memory tickCumulatives,) = umiaHook.observe(poolKey, secondsAgos);
        int48 twapTick = (tickCumulatives[1] - tickCumulatives[0]) / int48(60);

        // The pool has a non-zero tick from migration pricing
        (, int24 spotTick,,) = manager.getSlot0(poolKey.toId());
        int48 diff = twapTick > int48(spotTick) ? twapTick - int48(spotTick) : int48(spotTick) - twapTick;
        // TWAP should be close to spot (small swaps shouldn't move price dramatically)
        assertTrue(diff < 1000, "TWAP should be close to spot tick");
    }

    function test_IncreaseCardinalityNext() public {
        PoolId id = poolKey.toId();

        // Migration already set cardinalityNext to the bootstrap seed, grow further to 2000
        (uint16 oldNext, uint16 newNext) = umiaHook.increaseCardinalityNext(poolKey, 2000);
        assertEq(oldNext, 100);
        assertEq(newNext, 2000);

        (,, uint16 cardinalityNextAfter) = umiaHook.oracleStates(id);
        assertEq(cardinalityNextAfter, 2000);
    }

    function test_IncreaseCardinalityNext_NoOpIfSmaller() public {
        // Migration set cardinalityNext to the bootstrap seed, requesting less is a no-op
        (uint16 oldNext, uint16 newNext) = umiaHook.increaseCardinalityNext(poolKey, 50);
        assertEq(oldNext, 100);
        assertEq(newNext, 100);
    }

    function test_MultipleSwapsGrowOracle() public {
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(currency);

        // Migration already set cardinalityNext to 250
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 30);
            _doSwap(0.5e18, zeroForOne);
        }

        PoolId id = poolKey.toId();
        (uint16 index, uint16 cardinality,) = umiaHook.oracleStates(id);
        assertEq(index, 5, "Index should be 5 after 5 swaps");
        assertEq(cardinality, 100, "Cardinality should match cardinalityNext from migration");
    }

    function test_ObserveRevertsForTimestampBeforeInit() public {
        // Write a few observations, then query a window longer than available history.
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(currency);

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 10);
            _doSwap(0.01e18, zeroForOne);
        }

        // We have ~100s of history. Querying 1 hour back should revert.
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 3600;

        vm.expectRevert();
        umiaHook.observe(poolKey, secondsAgos);
    }

    function test_SameBlockSwapNoNewObservation() public {
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(currency);

        vm.warp(block.timestamp + 60);
        _doSwap(0.5e18, zeroForOne);

        PoolId id = poolKey.toId();
        (uint16 indexAfterFirst,,) = umiaHook.oracleStates(id);

        // Second swap in the same block should NOT advance index
        _doSwap(0.5e18, zeroForOne);

        (uint16 indexAfterSecond,,) = umiaHook.oracleStates(id);
        assertEq(indexAfterFirst, indexAfterSecond, "Same-block swaps should not create new observation");
    }

    // ============ Full-Range Enforcement Tests ============

    function _approveForMint(address lp, MockERC20 token0, MockERC20 token1) internal {
        token0.mint(lp, 100e18);
        token1.mint(lp, 100e18);
        vm.startPrank(lp);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(lpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(lpm), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function test_RejectsConcentratedLiquidity() public {
        address lp = makeAddr("lp");
        MockERC20 token0 = Currency.unwrap(poolKey.currency0) == address(token) ? token : currency;
        MockERC20 token1 = Currency.unwrap(poolKey.currency0) == address(token) ? currency : token;
        _approveForMint(lp, token0, token1);

        PositionConfig memory config = PositionConfig({poolKey: poolKey, tickLower: -600, tickUpper: 600});

        vm.prank(lp);
        vm.expectRevert();
        mint(config, 1e18, lp, "");
    }

    /// @dev Liquidity is operator-gated: an arbitrary LP (not the venture's SpotLiquidityVault)
    ///      cannot add liquidity to the canonical pool, regardless of range. Full-range enforcement
    ///      and the operator gate are exercised directly in UmiaHook.t.sol.
    function test_RejectsNonOperatorLiquidity() public {
        address lp = makeAddr("lp");
        MockERC20 token0 = Currency.unwrap(poolKey.currency0) == address(token) ? token : currency;
        MockERC20 token1 = Currency.unwrap(poolKey.currency0) == address(token) ? currency : token;
        _approveForMint(lp, token0, token1);

        int24 minTick = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(poolKey.tickSpacing);
        PositionConfig memory config = PositionConfig({poolKey: poolKey, tickLower: minTick, tickUpper: maxTick});

        vm.prank(lp);
        vm.expectRevert();
        mint(config, 1e18, lp, "");
    }

    function test_oldestObservationTimestamp_notExposed() public {
        (bool success,) = address(umiaHook)
            .call(
                abi.encodeWithSignature("oldestObservationTimestamp((address,address,uint24,int24,address))", poolKey)
            );

        assertFalse(success, "oldestObservationTimestamp should not be part of the public ABI");
    }
}
