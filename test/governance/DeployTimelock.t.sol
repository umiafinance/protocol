// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployTimelock} from "../../script/DeployTimelock.s.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {Venture} from "../../src/core/Venture.sol";

contract DeployTimelockScriptTest is Test {
    uint256 internal constant OWNER_KEY = 0xA11CE;

    address internal owner;
    UmiaHub internal hub;
    UpgradeableBeacon internal beacon;
    DeployTimelock internal script;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        hub = UmiaHub(address(new ERC1967Proxy(address(new UmiaHub()), abi.encodeCall(UmiaHub.initialize, (owner)))));
        beacon = new UpgradeableBeacon(address(new Venture()), owner);
        script = new DeployTimelock();
    }

    function _config() internal view returns (DeployTimelock.AdoptionConfig memory) {
        return DeployTimelock.AdoptionConfig({
            ownerKey: OWNER_KEY,
            hub: address(hub),
            proposer: address(this),
            minDelay: 2 days,
            executor: address(0),
            beacon: address(beacon),
            allowEoaProposer: false,
            allowShortDelay: false
        });
    }

    function test_adopt_handsOwnershipToConfiguredTimelock() public {
        TimelockController timelock = script.adopt(_config());

        assertEq(hub.owner(), address(timelock));
        assertEq(beacon.owner(), address(timelock));
        assertEq(timelock.getMinDelay(), 2 days);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), owner));
    }

    function test_adopt_skipsBeaconWhenUnset() public {
        DeployTimelock.AdoptionConfig memory cfg = _config();
        cfg.beacon = address(0);

        TimelockController timelock = script.adopt(cfg);

        assertEq(hub.owner(), address(timelock));
        assertEq(beacon.owner(), owner);
    }

    function test_adopt_revertsWhenKeyIsNotHubOwner() public {
        DeployTimelock.AdoptionConfig memory cfg = _config();
        cfg.ownerKey = 0xB0B;

        vm.expectRevert(bytes("DEPLOYER_PRIVATE_KEY is not the hub owner"));
        script.adopt(cfg);
    }

    function test_adopt_revertsWhenKeyIsNotBeaconOwner() public {
        vm.prank(owner);
        beacon.transferOwnership(makeAddr("other"));

        vm.expectRevert(bytes("DEPLOYER_PRIVATE_KEY is not the venture beacon owner"));
        script.adopt(_config());
    }

    function test_adopt_rejectsZeroProposerEvenWithOverride() public {
        DeployTimelock.AdoptionConfig memory cfg = _config();
        cfg.proposer = address(0);
        cfg.allowEoaProposer = true;

        vm.expectRevert(bytes("TIMELOCK_PROPOSER must not be the zero address"));
        script.adopt(cfg);
    }

    function test_adopt_rejectsEoaProposerWithoutOverride() public {
        DeployTimelock.AdoptionConfig memory cfg = _config();
        cfg.proposer = makeAddr("eoaProposer");

        vm.expectRevert(
            bytes(
                "TIMELOCK_PROPOSER has no bytecode (expected a Safe); set TIMELOCK_ALLOW_EOA_PROPOSER=true to override"
            )
        );
        script.adopt(cfg);
    }

    function test_adopt_allowsEoaProposerWithOverride() public {
        DeployTimelock.AdoptionConfig memory cfg = _config();
        cfg.proposer = makeAddr("eoaProposer");
        cfg.allowEoaProposer = true;

        TimelockController timelock = script.adopt(cfg);

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), cfg.proposer));
    }

    function test_adopt_rejectsShortDelayWithoutOverride() public {
        DeployTimelock.AdoptionConfig memory cfg = _config();
        cfg.minDelay = 10 minutes;

        vm.expectRevert(bytes("TIMELOCK_MIN_DELAY below 1 hour; set TIMELOCK_ALLOW_SHORT_DELAY=true to override"));
        script.adopt(cfg);
    }

    function test_adopt_allowsShortDelayWithOverride() public {
        DeployTimelock.AdoptionConfig memory cfg = _config();
        cfg.minDelay = 10 minutes;
        cfg.allowShortDelay = true;

        TimelockController timelock = script.adopt(cfg);

        assertEq(timelock.getMinDelay(), 10 minutes);
    }
}
