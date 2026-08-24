// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {Venture} from "../../src/core/Venture.sol";
import {UmiaHubV2, UmiaMarketCoreV2, VentureV2} from "../mocks/UpgradedImplementations.sol";

contract HubTimelockTest is Test {
    uint256 internal constant MIN_DELAY = 2 days;
    bytes32 internal constant NO_PREDECESSOR = bytes32(0);
    bytes32 internal constant SALT = bytes32(0);

    address internal deployer = makeAddr("deployer");
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal rando = makeAddr("rando");

    UmiaHub internal hub;
    UmiaMarketCore internal mm;
    UpgradeableBeacon internal beacon;
    TimelockController internal timelock;

    function setUp() public {
        hub = UmiaHub(address(new ERC1967Proxy(address(new UmiaHub()), abi.encodeCall(UmiaHub.initialize, (deployer)))));
        mm = UmiaMarketCore(
            address(
                new ERC1967Proxy(
                    address(new UmiaMarketCore()), abi.encodeCall(UmiaMarketCore.initialize, (address(hub)))
                )
            )
        );
        beacon = new UpgradeableBeacon(address(new Venture()), deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        vm.startPrank(deployer);
        hub.setVetoGuardian(guardian);
        hub.transferOwnership(address(timelock));
        beacon.transferOwnership(address(timelock));
        vm.stopPrank();
    }

    function _schedule(address target, bytes memory data) internal {
        vm.prank(safe);
        timelock.schedule(target, 0, data, NO_PREDECESSOR, SALT, MIN_DELAY);
    }

    function _execute(address target, bytes memory data) internal {
        vm.prank(rando);
        timelock.execute(target, 0, data, NO_PREDECESSOR, SALT);
    }

    // ═════════════════════════════════════════════════════
    //  Ownership handoff
    // ═════════════════════════════════════════════════════

    function test_timelockIsHubOwner() public view {
        assertEq(hub.owner(), address(timelock));
        assertEq(beacon.owner(), address(timelock));
    }

    function test_safeCannotCallHubDirectly() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        hub.setProtocolFeeRecipient(safe);
    }

    function test_formerOwnerCannotCallHub() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        hub.setProtocolFeeRecipient(deployer);
    }

    // ═════════════════════════════════════════════════════
    //  Schedule → wait → execute
    // ═════════════════════════════════════════════════════

    function test_setterViaTimelock() public {
        bytes memory data = abi.encodeCall(hub.setProtocolFeeRecipient, (rando));
        _schedule(address(hub), data);

        skip(MIN_DELAY);
        _execute(address(hub), data);

        assertEq(hub.protocolFeeRecipient(), rando);
    }

    function test_executeBeforeDelayReverts() public {
        bytes memory data = abi.encodeCall(hub.setProtocolFeeRecipient, (rando));
        _schedule(address(hub), data);

        skip(MIN_DELAY - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        vm.prank(rando);
        timelock.execute(address(hub), 0, data, NO_PREDECESSOR, SALT);
    }

    function test_scheduleBelowMinDelayReverts() public {
        bytes memory data = abi.encodeCall(hub.setProtocolFeeRecipient, (rando));
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, MIN_DELAY - 1, MIN_DELAY)
        );
        vm.prank(safe);
        timelock.schedule(address(hub), 0, data, NO_PREDECESSOR, SALT, MIN_DELAY - 1);
    }

    function test_nonProposerCannotSchedule() public {
        bytes memory data = abi.encodeCall(hub.setProtocolFeeRecipient, (rando));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rando, timelock.PROPOSER_ROLE()
            )
        );
        vm.prank(rando);
        timelock.schedule(address(hub), 0, data, NO_PREDECESSOR, SALT, MIN_DELAY);
    }

    function test_safeCanCancelQueuedOperation() public {
        bytes memory data = abi.encodeCall(hub.setProtocolFeeRecipient, (rando));
        _schedule(address(hub), data);
        bytes32 id = timelock.hashOperation(address(hub), 0, data, NO_PREDECESSOR, SALT);

        vm.prank(safe);
        timelock.cancel(id);

        skip(MIN_DELAY);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        vm.prank(rando);
        timelock.execute(address(hub), 0, data, NO_PREDECESSOR, SALT);
    }

    // ═════════════════════════════════════════════════════
    //  Upgrades through the timelock
    // ═════════════════════════════════════════════════════

    function test_hubUpgradeViaTimelock() public {
        UmiaHubV2 v2 = new UmiaHubV2();
        bytes memory data = abi.encodeCall(hub.upgradeToAndCall, (address(v2), ""));

        _schedule(address(hub), data);
        skip(MIN_DELAY);
        _execute(address(hub), data);

        assertEq(UmiaHubV2(address(hub)).version(), 2);
        assertEq(hub.owner(), address(timelock));
    }

    function test_marketCoreUpgradeViaTimelock() public {
        UmiaMarketCoreV2 v2 = new UmiaMarketCoreV2();
        bytes memory data = abi.encodeCall(mm.upgradeToAndCall, (address(v2), ""));

        _schedule(address(mm), data);
        skip(MIN_DELAY);
        _execute(address(mm), data);

        assertEq(UmiaMarketCoreV2(address(mm)).version(), 2);
    }

    function test_beaconUpgradeViaTimelock() public {
        VentureV2 v2 = new VentureV2();
        bytes memory data = abi.encodeCall(beacon.upgradeTo, (address(v2)));

        _schedule(address(beacon), data);
        skip(MIN_DELAY);
        _execute(address(beacon), data);

        assertEq(beacon.implementation(), address(v2));
    }

    // ═════════════════════════════════════════════════════
    //  Veto guardian fast path
    // ═════════════════════════════════════════════════════

    function test_guardianTripsInstantly_resetGoesThroughTimelock() public {
        uint256 marketId = 42;

        vm.prank(guardian);
        hub.tripDecisionMarketCircuitBreaker(marketId);
        assertTrue(hub.decisionMarketCircuitBreakerActive(marketId));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        hub.resetDecisionMarketCircuitBreaker(marketId);

        bytes memory data = abi.encodeCall(hub.resetDecisionMarketCircuitBreaker, (marketId));
        _schedule(address(hub), data);
        skip(MIN_DELAY);
        _execute(address(hub), data);

        assertFalse(hub.decisionMarketCircuitBreakerActive(marketId));
    }

    function test_randoCannotTrip() public {
        vm.prank(rando);
        vm.expectRevert(IUmiaHub.UnauthorizedVeto.selector);
        hub.tripDecisionMarketCircuitBreaker(1);
    }

    // ═════════════════════════════════════════════════════
    //  Timelock self-administration
    // ═════════════════════════════════════════════════════

    function test_safeCannotGrantRolesDirectly() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, safe, timelock.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(safe);
        timelock.grantRole(proposerRole, safe);
    }

    function test_safeCannotUpdateDelayDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, safe));
        vm.prank(safe);
        timelock.updateDelay(1 hours);
    }

    function test_delayUpdateViaScheduledOperation() public {
        bytes memory data = abi.encodeCall(timelock.updateDelay, (3 days));

        _schedule(address(timelock), data);
        skip(MIN_DELAY);
        _execute(address(timelock), data);

        assertEq(timelock.getMinDelay(), 3 days);
    }
}
