// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {Venture} from "../../src/core/Venture.sol";
import {VentureProxy} from "../../src/core/VentureProxy.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {IGovernanceExecutor} from "../../src/interfaces/IGovernanceExecutor.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {GovernanceActions} from "../../src/libraries/GovernanceActions.sol";
import {UmiaHubV2, UmiaMarketCoreV2, VentureV2} from "../mocks/UpgradedImplementations.sol";

contract NonUUPSContract {
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(0);
    }
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

contract UpgradeabilityTest is Test {
    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");
    address internal team1 = makeAddr("team1");

    UmiaHub internal hub;
    UmiaHub internal hubImpl;
    UmiaMarketCore internal mm;
    UmiaMarketCore internal mmImpl;
    GovernanceExecutor internal executor;
    UpgradeableBeacon internal beacon;
    Venture internal ventureImpl;

    function setUp() public {
        hubImpl = new UmiaHub();
        hub = UmiaHub(address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(UmiaHub.initialize, (owner)))));

        mmImpl = new UmiaMarketCore();
        mm = UmiaMarketCore(
            address(new ERC1967Proxy(address(mmImpl), abi.encodeCall(UmiaMarketCore.initialize, (address(hub)))))
        );

        executor = new GovernanceExecutor(address(hub));

        ventureImpl = new Venture();
        beacon = new UpgradeableBeacon(address(ventureImpl), owner);

        vm.startPrank(owner);
        hub.setUmiaMarketCore(address(mm));
        hub.setDefaultGovernanceExecutor(address(executor));
        hub.setVentureBeacon(address(beacon));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────

    function _deployVentureViaBeacon() internal returns (Venture venture, VentureToken qToken) {
        venture = Venture(
            payable(address(new VentureProxy(address(beacon), abi.encodeCall(Venture.initializeProxy, (address(hub))))))
        );
        qToken = new VentureToken("Test", "TST", address(venture));

        address[] memory members = new address[](1);
        members[0] = team1;

        vm.prank(address(hub));
        venture.initialize(
            IVenture.InitializeVentureParams({
                token: address(qToken),
                moneyToken: address(1),
                lbp: address(0xBEEF),
                teamMembers: members,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function _upgradeAction(address newImpl) internal pure returns (bytes memory) {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.UPGRADE_IMPLEMENTATION,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.UpgradeImplementation({newImplementation: newImpl, data: ""}))
        });
        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
    }

    // ═════════════════════════════════════════════════════
    //  Hub Upgrade Access Control
    // ═════════════════════════════════════════════════════

    function test_hub_ownerCanUpgrade() public {
        UmiaHubV2 v2 = new UmiaHubV2();

        vm.prank(owner);
        hub.upgradeToAndCall(address(v2), "");

        assertEq(UmiaHubV2(address(hub)).version(), 2);
        assertEq(hub.ventureBeacon(), address(beacon));
        assertEq(hub.owner(), owner);
    }

    function test_hub_nonOwnerCannotUpgrade() public {
        UmiaHubV2 v2 = new UmiaHubV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hub.upgradeToAndCall(address(v2), "");
    }

    function test_hub_cannotUpgradeToNonUUPS() public {
        NonUUPSContract bad = new NonUUPSContract();

        vm.prank(owner);
        vm.expectRevert();
        hub.upgradeToAndCall(address(bad), "");
    }

    // ═════════════════════════════════════════════════════
    //  MarketCore Upgrade Access Control
    // ═════════════════════════════════════════════════════

    function test_mm_hubOwnerCanUpgrade() public {
        UmiaMarketCoreV2 v2 = new UmiaMarketCoreV2();

        vm.prank(owner);
        mm.upgradeToAndCall(address(v2), "");

        assertEq(UmiaMarketCoreV2(address(mm)).version(), 2);
        assertEq(address(mm.HUB()), address(hub));
    }

    function test_mm_nonHubOwnerCannotUpgrade() public {
        UmiaMarketCoreV2 v2 = new UmiaMarketCoreV2();

        vm.prank(attacker);
        vm.expectRevert(IUmiaMarketCore.Unauthorized.selector);
        mm.upgradeToAndCall(address(v2), "");
    }

    function test_mm_cannotUpgradeToNonUUPS() public {
        NonUUPSContract bad = new NonUUPSContract();

        vm.prank(owner);
        vm.expectRevert();
        mm.upgradeToAndCall(address(bad), "");
    }

    function test_mm_domainSeparatorUsesProxyAddress() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("UmiaMarketCore")),
                keccak256(bytes("1")),
                block.chainid,
                address(mm)
            )
        );
        assertEq(mm.DOMAIN_SEPARATOR(), expected);
    }

    // ═════════════════════════════════════════════════════
    //  Venture UUPS Opt-Out (Governance Path)
    // ═════════════════════════════════════════════════════

    function test_venture_executorCanUpgrade() public {
        (Venture venture,) = _deployVentureViaBeacon();
        VentureV2 v2 = new VentureV2();

        bytes memory payload = _upgradeAction(address(v2));

        vm.expectEmit(true, true, false, false);
        emit GovernanceActions.ImplementationOptOut(address(venture), address(v2));

        vm.prank(address(mm));
        executor.executeProposal(address(venture), 1, 1, payload);

        assertEq(VentureV2(payable(address(venture))).version(), 2);
    }

    function test_venture_nonExecutorCannotUpgrade() public {
        (Venture venture,) = _deployVentureViaBeacon();
        VentureV2 v2 = new VentureV2();

        vm.prank(attacker);
        vm.expectRevert(IVenture.CallerNotAuthorized.selector);
        UUPSUpgradeable(address(venture)).upgradeToAndCall(address(v2), "");
    }

    function test_venture_hubOwnerCannotUpgrade() public {
        (Venture venture,) = _deployVentureViaBeacon();
        VentureV2 v2 = new VentureV2();

        vm.prank(owner);
        vm.expectRevert(IVenture.CallerNotAuthorized.selector);
        UUPSUpgradeable(address(venture)).upgradeToAndCall(address(v2), "");
    }

    function test_venture_beaconMode_teamMemberCannotUpgrade() public {
        (Venture venture,) = _deployVentureViaBeacon();
        VentureV2 v2 = new VentureV2();

        vm.prank(team1);
        vm.expectRevert(IVenture.CallerNotAuthorized.selector);
        UUPSUpgradeable(address(venture)).upgradeToAndCall(address(v2), "");
    }

    function test_venture_afterOptOut_noLongerFollowsBeacon() public {
        (Venture venture,) = _deployVentureViaBeacon();
        VentureV2 v2Opt = new VentureV2();

        // Opt out via governance
        bytes memory payload = _upgradeAction(address(v2Opt));
        vm.prank(address(mm));
        executor.executeProposal(address(venture), 1, 1, payload);
        assertEq(VentureV2(payable(address(venture))).version(), 2);

        // Upgrade beacon to a different V2
        VentureV2 v2Beacon = new VentureV2();
        vm.prank(owner);
        beacon.upgradeTo(address(v2Beacon));

        // Opted-out Venture still uses its direct implementation, not the beacon's
        address implSlot = address(
            uint160(
                uint256(vm.load(address(venture), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))
            )
        );
        assertEq(implSlot, address(v2Opt));
    }

    function test_venture_cannotUpgradeToNonUUPS() public {
        (Venture venture,) = _deployVentureViaBeacon();
        NonUUPSContract bad = new NonUUPSContract();

        bytes memory payload = _upgradeAction(address(bad));

        vm.prank(address(mm));
        vm.expectRevert();
        executor.executeProposal(address(venture), 1, 1, payload);
    }

    // ═════════════════════════════════════════════════════
    //  Beacon (Protocol-Wide) Upgrades
    // ═════════════════════════════════════════════════════

    function test_beacon_ownerCanUpgrade() public {
        (Venture venture,) = _deployVentureViaBeacon();
        VentureV2 v2 = new VentureV2();

        vm.prank(owner);
        beacon.upgradeTo(address(v2));

        assertEq(VentureV2(payable(address(venture))).version(), 2);
    }

    function test_beacon_nonOwnerCannotUpgrade() public {
        VentureV2 v2 = new VentureV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        beacon.upgradeTo(address(v2));
    }

    function test_beacon_upgradeAffectsAllVentures() public {
        (Venture venture1,) = _deployVentureViaBeacon();
        (Venture venture2,) = _deployVentureViaBeacon();
        VentureV2 v2 = new VentureV2();

        vm.prank(owner);
        beacon.upgradeTo(address(v2));

        assertEq(VentureV2(payable(address(venture1))).version(), 2);
        assertEq(VentureV2(payable(address(venture2))).version(), 2);
    }

    function test_beacon_doesNotAffectOptedOutVenture() public {
        (Venture venture1,) = _deployVentureViaBeacon();
        (Venture venture2,) = _deployVentureViaBeacon();

        // Opt out venture1 via governance
        VentureV2 v2Opt = new VentureV2();
        bytes memory payload = _upgradeAction(address(v2Opt));
        vm.prank(address(mm));
        executor.executeProposal(address(venture1), 1, 1, payload);

        // Upgrade beacon
        VentureV2 v2Beacon = new VentureV2();
        vm.prank(owner);
        beacon.upgradeTo(address(v2Beacon));

        // venture1 still has its own impl, venture2 follows beacon
        address venture1Impl = address(
            uint160(
                uint256(vm.load(address(venture1), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))
            )
        );
        assertEq(venture1Impl, address(v2Opt));
        assertEq(VentureV2(payable(address(venture2))).version(), 2);
    }

    // ═════════════════════════════════════════════════════
    //  Implementation Contract Protection
    // ═════════════════════════════════════════════════════

    function test_impl_hubCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hubImpl.initialize(owner);
    }

    function test_impl_mmCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        mmImpl.initialize(address(hub));
    }

    function test_impl_ventureCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ventureImpl.initializeProxy(address(hub));
    }

    // ═════════════════════════════════════════════════════
    //  State Persistence After Upgrade
    // ═════════════════════════════════════════════════════

    function test_hub_statePersistsAfterUpgrade() public {
        uint256 countBefore = hub.ventureCount();
        address beaconBefore = hub.ventureBeacon();
        address mmBefore = hub.umiaMarketCore();

        UmiaHubV2 v2 = new UmiaHubV2();
        vm.prank(owner);
        hub.upgradeToAndCall(address(v2), "");

        assertEq(hub.ventureCount(), countBefore);
        assertEq(hub.ventureBeacon(), beaconBefore);
        assertEq(hub.umiaMarketCore(), mmBefore);
        assertEq(hub.owner(), owner);
    }

    function test_mm_statePersistsAfterUpgrade() public {
        address hubBefore = address(mm.HUB());
        bytes32 domainBefore = mm.DOMAIN_SEPARATOR();

        UmiaMarketCoreV2 v2 = new UmiaMarketCoreV2();
        vm.prank(owner);
        mm.upgradeToAndCall(address(v2), "");

        assertEq(address(mm.HUB()), hubBefore);
        assertEq(mm.DOMAIN_SEPARATOR(), domainBefore);
    }

    function test_venture_statePersistsAfterBeaconUpgrade() public {
        (Venture venture,) = _deployVentureViaBeacon();

        address tokenBefore = venture.token();
        address hubBefore = venture.HUB();

        VentureV2 v2 = new VentureV2();
        vm.prank(owner);
        beacon.upgradeTo(address(v2));

        assertEq(venture.token(), tokenBefore);
        assertEq(venture.HUB(), hubBefore);
        assertTrue(venture.isTeamMember(team1));
        assertEq(VentureV2(payable(address(venture))).version(), 2);
    }

    function test_venture_statePersistsAfterUUPSOptOut() public {
        (Venture venture,) = _deployVentureViaBeacon();

        address tokenBefore = venture.token();
        address hubBefore = venture.HUB();

        VentureV2 v2 = new VentureV2();
        bytes memory payload = _upgradeAction(address(v2));
        vm.prank(address(mm));
        executor.executeProposal(address(venture), 1, 1, payload);

        assertEq(venture.token(), tokenBefore);
        assertEq(venture.HUB(), hubBefore);
        assertTrue(venture.isTeamMember(team1));
        assertEq(VentureV2(payable(address(venture))).version(), 2);
    }
}
