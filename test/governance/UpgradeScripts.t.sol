// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolState} from "../../script/ProtocolState.sol";
import {UpgradeBase} from "../../script/UpgradeBase.s.sol";
import {UpgradeHub} from "../../script/UpgradeHub.s.sol";
import {UpgradeMarketCore} from "../../script/UpgradeMarketCore.s.sol";
import {UpgradeVentureBeacon} from "../../script/UpgradeVentureBeacon.s.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";
import {VentureProxy} from "../../src/core/VentureProxy.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {UmiaHubV2, UmiaMarketCoreV2, VentureV2} from "../mocks/UpgradedImplementations.sol";

contract UpgradeToV2 is UpgradeBase {
    constructor(Kind kind) UpgradeBase(kind) {}

    function _deployImplementation() internal override returns (address) {
        if (KIND == Kind.Hub) return address(new UmiaHubV2());
        if (KIND == Kind.MarketCore) return address(new UmiaMarketCoreV2());
        return address(new VentureV2());
    }
}

contract NotUups {
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

contract UpgradeHubToNotUups is UpgradeHub {
    function _deployImplementation() internal override returns (address) {
        return address(new NotUups());
    }
}

contract UpgradeScriptsTest is Test {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant DEPLOYER_KEY = 0xDE9107;
    uint256 internal constant MIN_DELAY = 2 days;

    address internal owner;
    address internal deployer;
    address internal safe = makeAddr("safe");

    UmiaHub internal hub;
    UmiaMarketCore internal mm;
    UpgradeableBeacon internal beacon;
    Venture internal venture;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        deployer = vm.addr(DEPLOYER_KEY);

        hub = UmiaHub(address(new ERC1967Proxy(address(new UmiaHub()), abi.encodeCall(UmiaHub.initialize, (owner)))));
        mm = UmiaMarketCore(
            address(
                new ERC1967Proxy(
                    address(new UmiaMarketCore()), abi.encodeCall(UmiaMarketCore.initialize, (address(hub)))
                )
            )
        );
        beacon = new UpgradeableBeacon(address(new Venture()), owner);

        vm.startPrank(owner);
        hub.setUmiaMarketCore(address(mm));
        hub.setVentureBeacon(address(beacon));
        vm.stopPrank();

        venture = Venture(
            payable(address(new VentureProxy(address(beacon), abi.encodeCall(Venture.initializeProxy, (address(hub))))))
        );
        VentureToken token = new VentureToken("Test", "TST", address(venture));
        address[] memory members = new address[](1);
        members[0] = makeAddr("team");
        vm.prank(address(hub));
        venture.initialize(
            IVenture.InitializeVentureParams({
                token: address(token),
                moneyToken: address(1),
                lbp: address(0xBEEF),
                teamMembers: members,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function _config(uint256 key, bytes memory initData, bool execute)
        internal
        view
        returns (UpgradeBase.UpgradeConfig memory)
    {
        return UpgradeBase.UpgradeConfig({
            deployerKey: key, hub: IUmiaHub(address(hub)), initData: initData, execute: execute
        });
    }

    function _adoptTimelock() internal returns (TimelockController timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
        vm.startPrank(owner);
        hub.transferOwnership(address(timelock));
        beacon.transferOwnership(address(timelock));
        vm.stopPrank();
    }

    function _runThroughTimelock(TimelockController timelock, UpgradeBase.Plan memory plan) internal {
        vm.prank(safe);
        timelock.schedule(plan.target, 0, plan.data, bytes32(0), plan.salt, MIN_DELAY);
        skip(MIN_DELAY);
        timelock.execute(plan.target, 0, plan.data, bytes32(0), plan.salt);
    }

    // ═════════════════════════════════════════════════════
    //  Target resolution
    // ═════════════════════════════════════════════════════

    function test_targetsResolveFromHubRegistry() public {
        assertEq(new UpgradeHub().upgrade(_config(DEPLOYER_KEY, "", false)).target, address(hub));
        assertEq(new UpgradeMarketCore().upgrade(_config(DEPLOYER_KEY, "", false)).target, address(mm));
        assertEq(new UpgradeVentureBeacon().upgrade(_config(DEPLOYER_KEY, "", false)).target, address(beacon));
    }

    // ═════════════════════════════════════════════════════
    //  Hub
    // ═════════════════════════════════════════════════════

    function test_hub_executesWhenDeployerIsOwner() public {
        UpgradeBase.Plan memory plan = new UpgradeHub().upgrade(_config(OWNER_KEY, "", true));

        assertTrue(plan.executed);
        assertEq(ProtocolState.implementationOf(address(hub)), plan.newImpl);
        assertEq(hub.owner(), owner);
        assertEq(hub.umiaMarketCore(), address(mm));
    }

    function test_hub_handsOffWhenNotExecuting() public {
        address before = ProtocolState.implementationOf(address(hub));
        UpgradeBase.Plan memory plan = new UpgradeHub().upgrade(_config(DEPLOYER_KEY, "", false));

        assertFalse(plan.executed);
        assertEq(ProtocolState.implementationOf(address(hub)), before);
        assertEq(plan.previousImpl, before);
        assertEq(plan.owner, owner);
        assertEq(plan.data, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (plan.newImpl, "")));

        vm.prank(owner);
        (bool ok,) = plan.target.call(plan.data);
        assertTrue(ok);
        assertEq(ProtocolState.implementationOf(address(hub)), plan.newImpl);
    }

    function test_hub_rejectsExecuteFromNonOwner() public {
        UpgradeHub script = new UpgradeHub();
        vm.expectRevert(bytes("EXECUTE_UPGRADE set but the deployer is not the owner"));
        script.upgrade(_config(DEPLOYER_KEY, "", true));
    }

    function test_hub_forwardsInitData() public {
        bytes memory initData = abi.encodeCall(UmiaHubV2.initializeV2, (42));
        UpgradeBase.Plan memory plan = new UpgradeToV2(UpgradeBase.Kind.Hub).upgrade(_config(OWNER_KEY, initData, true));

        assertEq(plan.data, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (plan.newImpl, initData)));
        assertEq(UmiaHubV2(address(hub)).v2Value(), 42);
        assertEq(UmiaHubV2(address(hub)).version(), 2);
    }

    function test_hub_rehearsalCatchesBadInitData() public {
        UpgradeHub script = new UpgradeHub();
        vm.expectRevert();
        script.upgrade(_config(OWNER_KEY, abi.encodeWithSignature("doesNotExist()"), true));
    }

    function test_hub_rejectsNonUupsImplementation() public {
        UpgradeHubToNotUups script = new UpgradeHubToNotUups();
        vm.expectRevert(bytes("new implementation is not a UUPS implementation"));
        script.upgrade(_config(OWNER_KEY, "", false));
    }

    function test_hub_timelockHandoffExecutesViaScheduleAndExecute() public {
        TimelockController timelock = _adoptTimelock();
        bytes memory initData = abi.encodeCall(UmiaHubV2.initializeV2, (7));

        UpgradeBase.Plan memory plan =
            new UpgradeToV2(UpgradeBase.Kind.Hub).upgrade(_config(DEPLOYER_KEY, initData, false));
        assertEq(plan.owner, address(timelock));
        assertFalse(plan.executed);

        _runThroughTimelock(timelock, plan);

        assertEq(ProtocolState.implementationOf(address(hub)), plan.newImpl);
        assertEq(UmiaHubV2(address(hub)).v2Value(), 7);
        assertEq(hub.owner(), address(timelock));
    }

    function test_hub_timelockOwnerCannotExecuteDirectly() public {
        _adoptTimelock();
        UpgradeHub script = new UpgradeHub();
        vm.expectRevert(bytes("EXECUTE_UPGRADE set but the deployer is not the owner"));
        script.upgrade(_config(OWNER_KEY, "", true));
    }

    // ═════════════════════════════════════════════════════
    //  MarketCore
    // ═════════════════════════════════════════════════════

    function test_mm_executesWhenDeployerIsHubOwner() public {
        bytes32 domainBefore = mm.DOMAIN_SEPARATOR();
        UpgradeBase.Plan memory plan = new UpgradeMarketCore().upgrade(_config(OWNER_KEY, "", true));

        assertTrue(plan.executed);
        assertEq(ProtocolState.implementationOf(address(mm)), plan.newImpl);
        assertEq(address(mm.HUB()), address(hub));
        assertEq(mm.DOMAIN_SEPARATOR(), domainBefore);
    }

    function test_mm_handsOffToHubOwner() public {
        UpgradeBase.Plan memory plan = new UpgradeMarketCore().upgrade(_config(DEPLOYER_KEY, "", false));

        assertEq(plan.owner, owner);
        assertEq(plan.data, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (plan.newImpl, "")));

        vm.prank(owner);
        (bool ok,) = plan.target.call(plan.data);
        assertTrue(ok);
        assertEq(ProtocolState.implementationOf(address(mm)), plan.newImpl);
    }

    function test_mm_timelockHandoffWithInitData() public {
        TimelockController timelock = _adoptTimelock();
        bytes memory initData = abi.encodeCall(UmiaMarketCoreV2.initializeV2, (99));

        UpgradeBase.Plan memory plan =
            new UpgradeToV2(UpgradeBase.Kind.MarketCore).upgrade(_config(DEPLOYER_KEY, initData, false));
        assertEq(plan.owner, address(timelock));

        _runThroughTimelock(timelock, plan);

        assertEq(UmiaMarketCoreV2(address(mm)).v2Value(), 99);
    }

    function test_mm_linkedLibrariesResolvedFromArtifact() public {
        UpgradeMarketCore script = new UpgradeMarketCore();
        UpgradeBase.Plan memory plan = script.upgrade(_config(OWNER_KEY, "", false));
        (address settlementLib, address marketCreationLib) = script.linkedLibraries(plan.newImpl);

        assertGt(settlementLib.code.length, 0);
        assertGt(marketCreationLib.code.length, 0);
        assertTrue(settlementLib != marketCreationLib);
        assertTrue(settlementLib != plan.newImpl && marketCreationLib != plan.newImpl);
    }

    // ═════════════════════════════════════════════════════
    //  Venture beacon
    // ═════════════════════════════════════════════════════

    function test_beacon_executesWhenDeployerIsOwner() public {
        address tokenBefore = venture.token();
        UpgradeBase.Plan memory plan =
            new UpgradeToV2(UpgradeBase.Kind.VentureBeacon).upgrade(_config(OWNER_KEY, "", true));

        assertTrue(plan.executed);
        assertEq(beacon.implementation(), plan.newImpl);
        assertEq(venture.token(), tokenBefore);
        assertEq(VentureV2(payable(address(venture))).version(), 2);
        assertEq(VentureV2(payable(address(venture))).v2Value(), 0);
    }

    function test_beacon_handsOffToBeaconOwner() public {
        UpgradeBase.Plan memory plan = new UpgradeVentureBeacon().upgrade(_config(DEPLOYER_KEY, "", false));

        assertEq(plan.owner, owner);
        assertEq(plan.data, abi.encodeCall(UpgradeableBeacon.upgradeTo, (plan.newImpl)));
        assertEq(beacon.implementation(), plan.previousImpl);
    }

    function test_beacon_rejectsInitData() public {
        UpgradeVentureBeacon script = new UpgradeVentureBeacon();
        vm.expectRevert(bytes("beacon upgrades cannot carry init data"));
        script.upgrade(_config(OWNER_KEY, abi.encodeCall(VentureV2.initializeV2, (1)), false));
    }

    function test_beacon_timelockHandoff() public {
        TimelockController timelock = _adoptTimelock();
        UpgradeBase.Plan memory plan =
            new UpgradeToV2(UpgradeBase.Kind.VentureBeacon).upgrade(_config(DEPLOYER_KEY, "", false));
        assertEq(plan.owner, address(timelock));

        _runThroughTimelock(timelock, plan);

        assertEq(beacon.implementation(), plan.newImpl);
        assertEq(VentureV2(payable(address(venture))).version(), 2);
    }
}
