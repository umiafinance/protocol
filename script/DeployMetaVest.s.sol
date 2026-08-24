// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {MetaVesTFactory} from "@metavest/MetaVesTFactory.sol";
import {VestingAllocationFactory} from "@metavest/VestingAllocationFactory.sol";
import {TokenOptionFactory} from "@metavest/TokenOptionFactory.sol";
import {RestrictedTokenFactory} from "@metavest/RestrictedTokenFactory.sol";
import {UmiaTwapMilestoneCondition} from "../src/periphery/UmiaTwapMilestoneCondition.sol";

/// @title DeployMetaVest
/// @notice Deploys the per-chain MetaVesT vesting singletons once (#1053): the MetaVesT factory, the
///         three allocation factories, and the UmiaTwapMilestoneCondition price gate. The per-venture
///         metavestController and VentureVestingAuthority adapter are intentionally NOT deployed here
///         -- they are created per venture by the launch orchestration (§8.1).
/// @dev forge script script/DeployMetaVest.s.sol:DeployMetaVest --rpc-url <rpc> --broadcast
///      TWAP_WINDOW (seconds) is optional and defaults to 1800 (30 min).
contract DeployMetaVest is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint32 twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(1800)));

        console.log("Deployer:", vm.addr(pk));
        console.log("TWAP window (s):", twapWindow);

        vm.startBroadcast(pk);

        MetaVesTFactory metavestFactory = new MetaVesTFactory();
        VestingAllocationFactory vestingFactory = new VestingAllocationFactory();
        TokenOptionFactory tokenOptionFactory = new TokenOptionFactory();
        RestrictedTokenFactory restrictedTokenFactory = new RestrictedTokenFactory();
        UmiaTwapMilestoneCondition condition = new UmiaTwapMilestoneCondition(twapWindow);

        vm.stopBroadcast();

        console.log("\n--- Deployed MetaVesT singletons ---");
        console.log("MetaVesTFactory:           ", address(metavestFactory));
        console.log("VestingAllocationFactory:  ", address(vestingFactory));
        console.log("TokenOptionFactory:        ", address(tokenOptionFactory));
        console.log("RestrictedTokenFactory:    ", address(restrictedTokenFactory));
        console.log("UmiaTwapMilestoneCondition:", address(condition));

        console.log("\n--- Environment / contracts.json ---");
        console.log("METAVEST_FACTORY=%s", address(metavestFactory));
        console.log("VESTING_ALLOCATION_FACTORY=%s", address(vestingFactory));
        console.log("TOKEN_OPTION_FACTORY=%s", address(tokenOptionFactory));
        console.log("RESTRICTED_TOKEN_FACTORY=%s", address(restrictedTokenFactory));
        console.log("TWAP_MILESTONE_CONDITION=%s", address(condition));
    }
}
