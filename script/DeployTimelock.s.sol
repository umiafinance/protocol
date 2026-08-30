// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {UmiaHub} from "../src/core/UmiaHub.sol";
import {Reclaim} from "../src/reclaim/Reclaim.sol";

/// @title DeployTimelock
/// @notice Deploys a stock OZ TimelockController and makes it the protocol owner.
///
///         The timelock becomes the owner of the UmiaHub proxy, which transitively gates
///         UmiaMarketCore upgrades (its _authorizeUpgrade checks HUB.owner()) and every
///         onlyOwner setter on the hub. Optionally it also takes over the Venture beacon.
///
///         Roles follow the standard OZ setup:
///         - TIMELOCK_PROPOSER (the Safe) gets PROPOSER_ROLE + CANCELLER_ROLE
///         - EXECUTOR_ROLE defaults to open (address(0)): anyone may execute an operation
///           once its delay has elapsed, since the payload is already fixed at schedule time
///         - the timelock administers itself; role changes require a scheduled operation
///
///         This is deliberately NOT part of Deploy.s.sol: devnet needs an instantly
///         operable deployer-owned hub for seeding, and adopting the timelock on a
///         persistent chain is a one-shot governance action. UmiaHub uses single-step
///         Ownable, so the transfer is irreversible - hence the pre-transfer assertions.
///
///         Environment:
///         - DEPLOYER_PRIVATE_KEY        current hub owner key (required)
///         - UMIA_HUB_ADDRESS            hub proxy (required)
///         - TIMELOCK_PROPOSER           Safe address (required)
///         - TIMELOCK_MIN_DELAY          seconds, default 2 days
///         - TIMELOCK_EXECUTOR           default address(0) = open execution
///         - VENTURE_BEACON_ADDRESS      also transfer the beacon (optional)
///         - RECLAIM_ADDRESS             also nominate the timelock as Reclaim owner (optional)
///         - TIMELOCK_ALLOW_EOA_PROPOSER allow a proposer with no bytecode (default false)
///         - TIMELOCK_ALLOW_SHORT_DELAY  allow a delay below 1 hour (default false)
contract DeployTimelock is Script {
    struct AdoptionConfig {
        uint256 ownerKey;
        address hub;
        address proposer;
        uint256 minDelay;
        address executor;
        address beacon;
        address reclaim;
        bool allowEoaProposer;
        bool allowShortDelay;
    }

    function run() external {
        adopt(
            AdoptionConfig({
                ownerKey: vm.envUint("DEPLOYER_PRIVATE_KEY"),
                hub: vm.envAddress("UMIA_HUB_ADDRESS"),
                proposer: vm.envAddress("TIMELOCK_PROPOSER"),
                minDelay: vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days)),
                executor: vm.envOr("TIMELOCK_EXECUTOR", address(0)),
                beacon: vm.envOr("VENTURE_BEACON_ADDRESS", address(0)),
                reclaim: vm.envOr("RECLAIM_ADDRESS", address(0)),
                allowEoaProposer: vm.envOr("TIMELOCK_ALLOW_EOA_PROPOSER", false),
                allowShortDelay: vm.envOr("TIMELOCK_ALLOW_SHORT_DELAY", false)
            })
        );
    }

    function adopt(AdoptionConfig memory cfg) public returns (TimelockController timelock) {
        address currentOwner = vm.addr(cfg.ownerKey);
        UmiaHub hub = UmiaHub(cfg.hub);

        require(hub.owner() == currentOwner, "DEPLOYER_PRIVATE_KEY is not the hub owner");
        require(cfg.proposer != address(0), "TIMELOCK_PROPOSER must not be the zero address");
        require(
            cfg.proposer.code.length > 0 || cfg.allowEoaProposer,
            "TIMELOCK_PROPOSER has no bytecode (expected a Safe); set TIMELOCK_ALLOW_EOA_PROPOSER=true to override"
        );
        require(
            cfg.minDelay >= 1 hours || cfg.allowShortDelay,
            "TIMELOCK_MIN_DELAY below 1 hour; set TIMELOCK_ALLOW_SHORT_DELAY=true to override"
        );
        if (cfg.beacon != address(0)) {
            require(
                UpgradeableBeacon(cfg.beacon).owner() == currentOwner,
                "DEPLOYER_PRIVATE_KEY is not the venture beacon owner"
            );
        }
        // Reclaim's owner controls `addNewEpoch`, i.e. the witness set every zkTLS proof in the
        // protocol is checked against. Leaving that with the deploy EOA makes the EOA the trust
        // anchor for participation gating, which defeats the point of moving the hub behind a
        // timelock, so the same adoption run hands it over too.
        if (cfg.reclaim != address(0)) {
            require(cfg.reclaim.code.length > 0, "RECLAIM_ADDRESS has no bytecode on this chain");
            require(Reclaim(cfg.reclaim).owner() == currentOwner, "DEPLOYER_PRIVATE_KEY is not the Reclaim owner");
        }

        console.log("Deploying TimelockController...");
        console.log("Current owner:", currentOwner);
        console.log("Proposer (Safe):", cfg.proposer);
        console.log("Min delay (s):", cfg.minDelay);
        console.log("Executor (0 = open):", cfg.executor);

        address[] memory proposers = new address[](1);
        proposers[0] = cfg.proposer;
        address[] memory executors = new address[](1);
        executors[0] = cfg.executor;

        vm.startBroadcast(cfg.ownerKey);
        timelock = new TimelockController(cfg.minDelay, proposers, executors, address(0));

        require(timelock.hasRole(timelock.PROPOSER_ROLE(), cfg.proposer), "proposer missing PROPOSER_ROLE");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), cfg.proposer), "proposer missing CANCELLER_ROLE");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), cfg.executor), "executor missing EXECUTOR_ROLE");
        require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "timelock not self-admined");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), currentOwner), "deployer must not be timelock admin");
        require(timelock.getMinDelay() == cfg.minDelay, "unexpected min delay");

        hub.transferOwnership(address(timelock));
        if (cfg.beacon != address(0)) {
            UpgradeableBeacon(cfg.beacon).transferOwnership(address(timelock));
        }
        // Nomination only: Reclaim uses two-step ownership and `acceptOwnership` must come from the
        // nominee, so the timelock has to schedule that call itself. Until it does, `owner` is still
        // the deploy EOA — the handover is not complete when this script returns.
        if (cfg.reclaim != address(0)) {
            Reclaim(cfg.reclaim).transferOwnership(address(timelock));
        }
        vm.stopBroadcast();

        require(hub.owner() == address(timelock), "hub ownership transfer failed");
        if (cfg.reclaim != address(0)) {
            require(Reclaim(cfg.reclaim).pendingOwner() == address(timelock), "Reclaim nomination failed");
            console.log("Reclaim pending owner (timelock must call acceptOwnership):", address(timelock));
        }

        console.log("TimelockController deployed at:", address(timelock));
        console.log("UmiaHub owner:", hub.owner());
        if (cfg.beacon != address(0)) {
            console.log("Venture beacon owner:", UpgradeableBeacon(cfg.beacon).owner());
        }

        console.log("\n--- Copy to .env ---");
        console.log("TIMELOCK_ADDRESS=", address(timelock));
    }
}
