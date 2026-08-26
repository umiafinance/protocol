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

/// A venture whose HUB(), authorizedLiquidator() and token() the caller fully controls.
contract MockVenture {
    address public immutable HUB;
    address public immutable authorizedLiquidator;
    address public immutable token;

    constructor(address _hub, address _liquidator, address _token) {
        HUB = _hub;
        authorizedLiquidator = _liquidator;
        token = _token;
    }
}

/// A hub that names an arbitrary governance executor for any venture.
contract MockHub {
    address public immutable exec;

    constructor(address _exec) {
        exec = _exec;
    }

    function governanceExecutor(address) external view returns (address) {
        return exec;
    }
}

/// `SimpleLiquidator.initialize` must resolve authorization through the liquidator's own
/// immutable hub, not through the caller-supplied venture, so a caller cannot fabricate its
/// own authorization chain and latch `initialized` ahead of a governance-decided liquidation.
contract SimpleLiquidatorAuthTest is Test {
    address internal admin = makeAddr("admin");
    address internal marketCore = makeAddr("marketCore");
    address internal team1 = makeAddr("team1");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    UmiaHub internal hub;
    GovernanceExecutor internal executor;
    Venture internal venture;
    VentureToken internal ventureToken;
    SimpleLiquidator internal liquidator;
    MockERC20 internal moneyToken;

    function setUp() public {
        UmiaHub hubImpl = new UmiaHub();
        hub = UmiaHub(address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(UmiaHub.initialize, (admin)))));

        vm.prank(admin);
        hub.setUmiaMarketCore(marketCore);

        executor = new GovernanceExecutor(address(hub));
        vm.prank(admin);
        hub.setDefaultGovernanceExecutor(address(executor));

        moneyToken = new MockERC20("Money", "MNY", 18);

        Venture ventureImpl = new Venture();
        venture = Venture(
            payable(address(
                    new ERC1967Proxy(address(ventureImpl), abi.encodeCall(Venture.initializeProxy, (address(hub))))
                ))
        );

        ventureToken = new VentureToken("Test", "TST", address(venture));

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = team1;

        vm.prank(address(hub));
        venture.initialize(
            IVenture.InitializeVentureParams({
                token: address(ventureToken),
                moneyToken: address(moneyToken),
                lbp: address(0x1234),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );

        liquidator = new SimpleLiquidator(address(hub));

        vm.prank(address(executor));
        venture.mint(bob, 100e18);
        vm.deal(address(venture), 10 ether);
    }

    function _liquidatePlan() internal view returns (bytes memory) {
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        });

        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
    }

    /// A caller-supplied mock venture can no longer vouch for itself and latch `initialized`.
    function test_initialize_rejectsCallerSuppliedAuthorization() public {
        MockHub fakeHub = new MockHub(attacker);
        MockVenture fakeVenture = new MockVenture(address(fakeHub), address(liquidator), address(ventureToken));

        GovernanceTypes.LiquidationAsset[] memory none = new GovernanceTypes.LiquidationAsset[](0);
        vm.prank(attacker);
        vm.expectRevert(ILiquidator.CallerNotAuthorized.selector);
        liquidator.initialize(address(fakeVenture), none, 1e18);

        assertFalse(liquidator.initialized(), "attacker could not latch initialized");
        assertEq(liquidator.venture(), address(0), "liquidator unbound");
    }

    /// The governance-decided liquidation still executes and pays a real holder.
    function test_initialize_governancePathSucceeds() public {
        uint256 bobEthBefore = bob.balance;

        vm.prank(marketCore);
        executor.executeProposal(address(venture), 1, 1, _liquidatePlan());

        assertTrue(liquidator.initialized(), "governance initialized the liquidator");
        assertEq(liquidator.venture(), address(venture), "liquidator bound to the real venture");

        vm.prank(bob);
        liquidator.claim();

        assertGt(bob.balance, bobEthBefore, "bob redeemed his pro-rata treasury share");
        assertEq(ventureToken.balanceOf(bob), 0, "bob's venture tokens were burned on claim");
    }

    /// A front-run attempt does not block the legitimate liquidation that follows it.
    function test_initialize_frontRunDoesNotBlockLiquidation() public {
        MockHub fakeHub = new MockHub(attacker);
        MockVenture fakeVenture = new MockVenture(address(fakeHub), address(liquidator), address(ventureToken));

        GovernanceTypes.LiquidationAsset[] memory none = new GovernanceTypes.LiquidationAsset[](0);
        vm.prank(attacker);
        vm.expectRevert(ILiquidator.CallerNotAuthorized.selector);
        liquidator.initialize(address(fakeVenture), none, 1e18);

        vm.prank(marketCore);
        executor.executeProposal(address(venture), 1, 1, _liquidatePlan());

        assertEq(liquidator.venture(), address(venture), "liquidation proceeded after the failed front-run");
    }
}
