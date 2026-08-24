// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SimpleLiquidator} from "../../src/liquidation/SimpleLiquidator.sol";
import {ILiquidator} from "../../src/interfaces/ILiquidator.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {Venture} from "../../src/core/Venture.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SimpleLiquidatorTest is Test {
    address internal admin = makeAddr("admin");
    address internal marketCore = makeAddr("marketCore");
    address internal team1 = makeAddr("team1");
    address internal bob = makeAddr("bob");
    address internal alice = makeAddr("alice");

    UmiaHub internal hub;
    GovernanceExecutor internal executor;
    Venture internal venture;
    VentureToken internal qToken;
    SimpleLiquidator internal liquidator;

    MockERC20 internal moneyToken;
    MockERC20 internal assetToken;

    function setUp() public {
        // Deploy hub via proxy
        UmiaHub hubImpl = new UmiaHub();
        hub = UmiaHub(address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(UmiaHub.initialize, (admin)))));

        vm.prank(admin);
        hub.setUmiaMarketCore(marketCore);

        executor = new GovernanceExecutor(address(hub));
        vm.prank(admin);
        hub.setDefaultGovernanceExecutor(address(executor));

        // Setup tokens
        moneyToken = new MockERC20("Money", "MNY", 18);
        assetToken = new MockERC20("Asset", "AST", 18);

        // Create venture
        Venture ventureImpl = new Venture();
        venture = Venture(
            payable(address(
                    new ERC1967Proxy(address(ventureImpl), abi.encodeCall(Venture.initializeProxy, (address(hub))))
                ))
        );

        // Create venture token
        qToken = new VentureToken("Test", "TST", address(venture));

        // Initialize venture
        address[] memory teamMembers = new address[](1);
        teamMembers[0] = team1;

        vm.prank(address(hub));
        venture.initialize(
            IVenture.InitializeVentureParams({
                token: address(qToken),
                moneyToken: address(moneyToken),
                lbp: address(0x1234),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );

        // Deploy liquidator
        liquidator = new SimpleLiquidator(address(hub));
    }

    function test_initialize_revertsWhenAlreadyInitialized() public {
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        // First initialization via governance
        _startLiquidation(assets);

        // Second initialization should revert
        vm.expectRevert(ILiquidator.AlreadyInitialized.selector);
        liquidator.initialize(address(venture), assets, 1000e18);
    }

    function test_claim_revertsWhenNotInitialized() public {
        vm.expectRevert(ILiquidator.NotInitialized.selector);
        liquidator.claim();
    }

    function test_claim_revertsWhenNothingToClaim() public {
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        _startLiquidation(assets);

        // Bob has no tokens
        vm.prank(bob);
        vm.expectRevert(ILiquidator.NothingToClaim.selector);
        liquidator.claim();
    }

    function test_claim_revertsOnDoubleClaim() public {
        // Setup: mint tokens to bob
        vm.prank(address(executor));
        venture.mint(bob, 100e18);
        vm.deal(address(venture), 10 ether);

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        _startLiquidation(assets);

        // First claim
        vm.prank(bob);
        liquidator.claim();

        // Second claim should revert
        vm.prank(bob);
        vm.expectRevert(ILiquidator.AlreadyClaimed.selector);
        liquidator.claim();
    }

    function test_claim_proRataDistribution() public {
        // Setup: mint tokens to multiple users
        vm.prank(address(executor));
        venture.mint(bob, 100e18); // 50%
        vm.prank(address(executor));
        venture.mint(alice, 100e18); // 50%

        // Fund venture with assets
        assetToken.mint(address(venture), 1000e18);
        vm.deal(address(venture), 10 ether);

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](2);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });
        assets[1] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(assetToken), tokenId: 0
        });

        _startLiquidation(assets);

        uint256 bobEthBefore = bob.balance;

        // Bob claims
        vm.prank(bob);
        liquidator.claim();

        // Total supply = 201e18 (bob: 100 + alice: 100 + team1: 1)
        // Bob had 100/201 ≈ 49.75% of supply
        assertEq(qToken.balanceOf(bob), 0, "Bob's venture tokens should be burned");
        uint256 bobExpectedEth = uint256(10 ether) * 100e18 / 201e18;
        uint256 bobExpectedTokens = uint256(1000e18) * 100e18 / 201e18;
        assertEq(bob.balance - bobEthBefore, bobExpectedEth, "Bob should get ~49.75% of ETH");
        assertEq(assetToken.balanceOf(bob), bobExpectedTokens, "Bob should get ~49.75% of assetToken");

        // Alice claims
        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        liquidator.claim();

        // Alice also had 100/201 ≈ 49.75% of supply
        assertEq(qToken.balanceOf(alice), 0, "Alice's venture tokens should be burned");
        uint256 aliceExpectedEth = uint256(10 ether) * 100e18 / 201e18;
        uint256 aliceExpectedTokens = uint256(1000e18) * 100e18 / 201e18;
        assertEq(alice.balance - aliceEthBefore, aliceExpectedEth, "Alice should get ~49.75% of ETH");
        assertEq(assetToken.balanceOf(alice), aliceExpectedTokens, "Alice should get ~49.75% of assetToken");
    }

    function test_claimableAmount_returnsProRataAmounts() public {
        // Setup
        vm.prank(address(executor));
        venture.mint(bob, 100e18); // 50%
        vm.prank(address(executor));
        venture.mint(alice, 50e18); // 25%

        assetToken.mint(address(venture), 1000e18);

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(assetToken), tokenId: 0
        });

        _startLiquidation(assets);

        // Total supply = 151e18 (bob: 100 + alice: 50 + team1: 1)
        // Bob has 100/151 ≈ 66.23% -> should get ~662.25e18
        // Alice has 50/151 ≈ 33.11% -> should get ~331.13e18

        uint256[] memory bobAmounts = liquidator.claimableAmount(bob);
        assertEq(bobAmounts.length, 1);
        uint256 bobExpected = uint256(1000e18) * 100e18 / 151e18;
        assertApproxEqAbs(bobAmounts[0], bobExpected, 1e9, "Bob's claimable amount incorrect");

        uint256[] memory aliceAmounts = liquidator.claimableAmount(alice);
        assertEq(aliceAmounts.length, 1);
        uint256 aliceExpected = uint256(1000e18) * 50e18 / 151e18;
        assertApproxEqAbs(aliceAmounts[0], aliceExpected, 1e9, "Alice's claimable amount incorrect");
    }

    function test_claimableAmount_returnsZeroAfterClaim() public {
        vm.prank(address(executor));
        venture.mint(bob, 100e18);
        vm.deal(address(venture), 10 ether);

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        _startLiquidation(assets);

        // Claim
        vm.prank(bob);
        liquidator.claim();

        // Should return zeros after claim
        uint256[] memory amounts = liquidator.claimableAmount(bob);
        assertEq(amounts[0], 0);
    }

    function test_initialize_revertsOnInvalidAssetType() public {
        SimpleLiquidator newLiquidator = new SimpleLiquidator(address(hub));

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC721, token: address(0x1234), tokenId: 1
        });

        vm.prank(address(executor));
        venture.setLiquidator(address(newLiquidator));

        vm.prank(address(executor));
        vm.expectRevert(ILiquidator.InvalidAssetType.selector);
        newLiquidator.initialize(address(venture), assets, 1000e18);
    }

    function test_liquidationAssetCount_returnsCorrectCount() public {
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](3);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });
        assets[1] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(assetToken), tokenId: 0
        });
        assets[2] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(moneyToken), tokenId: 0
        });

        _startLiquidation(assets);

        assertEq(liquidator.liquidationAssetCount(), 3);
    }

    function test_hasClaimed_returnsCorrectStatus() public {
        vm.prank(address(executor));
        venture.mint(bob, 100e18);
        vm.deal(address(venture), 10 ether);

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        _startLiquidation(assets);

        assertFalse(liquidator.hasClaimed(bob));

        vm.prank(bob);
        liquidator.claim();

        assertTrue(liquidator.hasClaimed(bob));
    }

    function test_initialize_revertsWhenNotCalledByExecutor() public {
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        vm.expectRevert(ILiquidator.CallerNotAuthorized.selector);
        liquidator.initialize(address(venture), assets, 1e18);
    }

    function test_claim_succeedsWhileTokenPaused() public {
        vm.prank(address(executor));
        venture.mint(bob, 100e18);
        vm.deal(address(venture), 10 ether);

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        _startLiquidation(assets);

        vm.prank(address(venture));
        qToken.pause();

        vm.prank(bob);
        liquidator.claim();

        assertEq(qToken.balanceOf(bob), 0);
        assertTrue(liquidator.hasClaimed(bob));
    }

    // Helper function to start liquidation via governance
    function _startLiquidation(GovernanceTypes.LiquidationAsset[] memory assets) internal {
        vm.prank(address(executor));
        venture.mint(team1, 1e18); // Ensure non-zero supply

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        });

        GovernanceTypes.ExecutionPlanV1 memory plan = GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions});

        vm.prank(marketCore);
        executor.executeProposal(address(venture), 1, 1, abi.encode(plan));
    }
}
