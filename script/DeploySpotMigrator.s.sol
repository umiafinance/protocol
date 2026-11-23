// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {OwnerHandoff} from "./OwnerHandoff.sol";
import {ProtocolState} from "./ProtocolState.sol";
import {IUmiaHub} from "../src/interfaces/IUmiaHub.sol";
import {UmiaHookV2} from "../src/periphery/UmiaHookV2.sol";
import {SpotLiquidityV2Code} from "../src/periphery/SpotLiquidityV2Code.sol";
import {SpotMigrator} from "../src/periphery/SpotMigrator.sol";

/// @title DeploySpotMigrator
/// @notice Deploys only a `SpotMigrator`, against a V2 spot liquidity stack that is already staged
///         (`DeploySpotLiquidityV2`). Use it to replace a staged migrator before the Hub points at
///         it, for example to change the fee of the pools it creates.
///
///         1. check the inputs: every address has code and the V2 hook is wired to this Hub and
///            pool manager
///         2. deploy `SpotMigrator(hub, poolManager, hookV2, sourceHook, code, targetFee)`; its
///            constructor refuses a target fee outside its bounds
///         3. read every immutable back
///         4. print the contracts.json line and the `setSpotMigrator` calldata for the Hub owner
///
///         Nothing here touches the Hub. Run without --broadcast for a dry run.
///
/// @dev forge script script/DeploySpotMigrator.s.sol --rpc-url <rpc>                      # simulate
///      forge script script/DeploySpotMigrator.s.sol --rpc-url <rpc> --broadcast --verify
///
///      Environment:
///      - SPOT_MIGRATOR_TARGET_FEE  fee of the V2 pools, in hundredths of a bip (3000 = 0.3%): a
///                                  multiple of 100 from 100 to 10000 (required)
///      - UMIA_ENV, UMIA_CHAIN      select the addresses below from contracts.json
///      - UMIA_HUB_ADDRESS          hub proxy                        (default umia.hub)
///      - POOL_MANAGER              Uniswap v4 PoolManager           (default uniswap.poolManager)
///      - UMIA_HOOK_ADDRESS         V1 hook whose pools are migrated (default umia.hook)
///      - UMIA_HOOK_V2_ADDRESS      staged UmiaHookV2                (default umia.hookV2)
///      - SPOT_LIQUIDITY_V2_CODE    staged SpotLiquidityV2Code       (default umia.spotLiquidityV2Code)
///      - DEPLOYER_PRIVATE_KEY      deploys the migrator; leave unset for a hardware wallet
///                                  (forge --ledger/--trezor) with DEPLOYER_ADDRESS set to the signer
contract DeploySpotMigrator is OwnerHandoff {
    struct Config {
        uint256 deployerKey;
        address hub;
        address poolManager;
        address sourceHook;
        address hookV2;
        address code;
        uint24 targetFee;
    }

    struct Plan {
        address migrator;
        address hub;
        address owner;
        bytes data;
        bytes32 salt;
    }

    function run() external returns (Plan memory) {
        string memory env = vm.envOr("UMIA_ENV", string(""));
        string memory chain = vm.envOr("UMIA_CHAIN", string(""));
        return deploy(
            Config({
                deployerKey: vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0)),
                hub: address(ProtocolState.hubFromContractsJson(env, chain)),
                poolManager: ProtocolState.fromContractsJson("POOL_MANAGER", env, chain, '["uniswap"]["poolManager"]'),
                sourceHook: ProtocolState.fromContractsJson("UMIA_HOOK_ADDRESS", env, chain, '["umia"]["hook"]'),
                hookV2: ProtocolState.fromContractsJson("UMIA_HOOK_V2_ADDRESS", env, chain, '["umia"]["hookV2"]'),
                code: ProtocolState.fromContractsJson(
                    "SPOT_LIQUIDITY_V2_CODE", env, chain, '["umia"]["spotLiquidityV2Code"]'
                ),
                targetFee: SafeCast.toUint24(vm.envUint("SPOT_MIGRATOR_TARGET_FEE"))
            })
        );
    }

    function deploy(Config memory cfg) public returns (Plan memory plan) {
        address deployer = _deployer(cfg.deployerKey);
        _check(cfg);
        plan.hub = cfg.hub;
        plan.owner = IUmiaHub(cfg.hub).owner();

        console.log("== Deploy SpotMigrator ==");
        console.log("hub:             ", cfg.hub);
        console.log("hub owner:       ", plan.owner);
        console.log("pool manager:    ", cfg.poolManager);
        console.log("source hook (V1):", cfg.sourceHook);
        console.log("hook V2:         ", cfg.hookV2);
        console.log("V2 code:         ", cfg.code);
        console.log("target fee:      ", cfg.targetFee);
        console.log("deployer:        ", deployer);
        console.log("deployer nonce:  ", vm.getNonce(deployer));

        _startBroadcast(cfg.deployerKey);
        SpotMigrator migrator = new SpotMigrator(
            cfg.hub,
            IPoolManager(cfg.poolManager),
            cfg.hookV2,
            cfg.sourceHook,
            SpotLiquidityV2Code(cfg.code),
            cfg.targetFee
        );
        vm.stopBroadcast();

        require(migrator.HUB() == cfg.hub, "migrator.HUB mismatch");
        require(address(migrator.poolManager()) == cfg.poolManager, "migrator.poolManager mismatch");
        require(migrator.hookV2() == cfg.hookV2, "migrator.hookV2 mismatch");
        require(migrator.sourceHook() == cfg.sourceHook, "migrator.sourceHook mismatch");
        require(migrator.targetFee() == cfg.targetFee, "migrator.targetFee mismatch");

        plan.migrator = address(migrator);
        plan.data = abi.encodeCall(IUmiaHub.setSpotMigrator, (plan.migrator));
        plan.salt = keccak256(abi.encodePacked(plan.hub, plan.migrator));

        console.log("\n--- contracts.json ---");
        console.log("umia.spotMigrator=%s", plan.migrator);
        console.log(
            "constructor args:",
            vm.toString(abi.encode(cfg.hub, cfg.poolManager, cfg.hookV2, cfg.sourceHook, cfg.code, cfg.targetFee))
        );
        _logOwnerCall(plan.hub, plan.owner, plan.data, plan.salt);
        _logLiveMigrator(plan.hub);
        console.log("\n--- Per existing venture, before its migration proposal ---");
        console.log(string.concat("   cast send ", vm.toString(plan.migrator), ' "prepare(address)" <venture>'));
    }

    function _check(Config memory cfg) internal view {
        _requireCode(cfg.hub, "hub");
        _requireCode(cfg.poolManager, "pool manager");
        _requireCode(cfg.sourceHook, "source hook");
        _requireCode(cfg.hookV2, "hook V2");
        _requireCode(cfg.code, "V2 code");
        _requireCode(SpotLiquidityV2Code(cfg.code).vaultCreationCode(), "V2 code's vault creation code");
        _requireCode(SpotLiquidityV2Code(cfg.code).almCreationCode(), "V2 code's ALM creation code");
        require(cfg.sourceHook != cfg.hookV2, "source hook and hook V2 are the same address");
        require(UmiaHookV2(cfg.hookV2).hub() == cfg.hub, "hook V2 is wired to another hub");
        require(
            address(UmiaHookV2(cfg.hookV2).poolManager()) == cfg.poolManager, "hook V2 is wired to another pool manager"
        );
    }

    function _requireCode(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat(label, " has no bytecode"));
    }

    function _logLiveMigrator(address hub) internal view {
        (bool upgraded, bytes memory live) = hub.staticcall(abi.encodeCall(IUmiaHub.spotMigrator, ()));
        if (upgraded && live.length == 32) {
            console.log("\nmigrator the Hub points at now:", abi.decode(live, (address)));
        } else {
            console.log("\nthe live Hub has no spotMigrator(): setSpotMigrator must run after the Hub upgrade,");
            console.log("later in the same batch or in a later one");
        }
    }
}
