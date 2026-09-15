// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {ProtocolState} from "../../script/ProtocolState.sol";
import {UpgradeBase} from "../../script/UpgradeBase.s.sol";
import {UpgradeHub} from "../../script/UpgradeHub.s.sol";
import {UpgradeMarketCore} from "../../script/UpgradeMarketCore.s.sol";
import {UpgradeVentureBeacon} from "../../script/UpgradeVentureBeacon.s.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";

/// @title UpgradeRehearsal
/// @notice Runs the real upgrade scripts against a fork of a live deployment, all the way through
///         execution: the test takes over the proxies with a key it controls, and each script
///         deploys this checkout's implementation, rehearses, executes, and diffs protocol state.
///         Skipped unless FORK_RPC_URL is set.
///
///         Environment:
///         - FORK_RPC_URL               archive-capable RPC of the target chain
///         - UMIA_ENV, UMIA_CHAIN       contracts.json entry of the deployment
///         - EXPECTED_PROTOCOL_OWNER    optional; asserts the live hub and beacon owner
contract UpgradeRehearsalForkTest is Test {
    uint256 internal constant OWNER_KEY = 0xA11CE;

    IUmiaHub internal hub;
    UpgradeableBeacon internal beacon;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        hub = ProtocolState.hubFromContractsJson(vm.envString("UMIA_ENV"), vm.envString("UMIA_CHAIN"));
        beacon = UpgradeableBeacon(hub.ventureBeacon());
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    function test_fork_hubUpgrade() public onFork {
        UpgradeBase.Plan memory plan = new UpgradeHub().upgrade(_takeOver());
        assertEq(ProtocolState.implementationOf(address(hub)), plan.newImpl);
    }

    function test_fork_marketCoreUpgrade() public onFork {
        UpgradeBase.Plan memory plan = new UpgradeMarketCore().upgrade(_takeOver());
        assertEq(ProtocolState.implementationOf(hub.umiaMarketCore()), plan.newImpl);
    }

    function test_fork_beaconUpgrade() public onFork {
        UpgradeBase.Plan memory plan = new UpgradeVentureBeacon().upgrade(_takeOver());
        assertEq(beacon.implementation(), plan.newImpl);
    }

    function test_fork_privilegedRoles() public onFork {
        console.log("hub owner:             ", hub.owner());
        console.log("beacon owner:          ", beacon.owner());
        console.log("veto guardian:         ", hub.vetoGuardian());
        console.log("market creation signer:", hub.marketCreationSigner());
        console.log("protocol fee recipient:", hub.protocolFeeRecipient());
        console.log("hub implementation:    ", ProtocolState.implementationOf(address(hub)));
        console.log("core implementation:   ", ProtocolState.implementationOf(hub.umiaMarketCore()));
        console.log("venture implementation:", beacon.implementation());

        address expected = vm.envOr("EXPECTED_PROTOCOL_OWNER", address(0));
        if (expected != address(0)) {
            assertEq(hub.owner(), expected, "hub owner");
            assertEq(beacon.owner(), expected, "beacon owner");
        }
    }

    /// @dev Hands the hub and beacon to OWNER_KEY so the scripts can run their execute path.
    function _takeOver() internal returns (UpgradeBase.UpgradeConfig memory) {
        address owner = vm.addr(OWNER_KEY);
        vm.prank(hub.owner());
        Ownable(address(hub)).transferOwnership(owner);
        vm.prank(beacon.owner());
        beacon.transferOwnership(owner);
        return UpgradeBase.UpgradeConfig({deployerKey: OWNER_KEY, hub: hub, initData: "", execute: true});
    }
}
