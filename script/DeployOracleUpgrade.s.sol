// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {UmiaHook} from "../src/periphery/UmiaHook.sol";
import {UmiaLBPFactory} from "../src/launchpad/UmiaLBPFactory.sol";
import {UmiaTwapMilestoneCondition} from "../src/periphery/UmiaTwapMilestoneCondition.sol";

// Canonical constants; duplicated from Deploy.s.sol (same pattern as MineUmiaHookSalt.s.sol).
address constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
uint160 constant UMIA_HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

/// @title DeployOracleUpgrade
/// @notice Targeted deployment for the dual-cadence oracle upgrade (#2240) onto a chain that
///         already has the protocol live. Deploys ONLY the three contracts whose bytecode changed
///         behavior, wired to the EXISTING hub:
///
///           1. new UmiaHook (CreateX, freshly mined salt — bytecode changed, so the canonical
///              address changes; see docs/NEW_CHAIN_DEPLOYMENT.md "When to re-mine")
///           2. new UmiaLBPFactory(poolManager, newHook, hub) — embeds the new SpotLiquidityVault
///              creation code via SSTORE2
///           3. newHook.initialize(newFactory, poolManager) — one-shot, INITIAL_OWNER-gated
///           4. new UmiaTwapMilestoneCondition(TWAP_WINDOW)
///
///         It deliberately does NOT call `hub.setLbpStrategyFactory`: the flip is the hub owner's
///         separate transaction, done only after the keeper and indexer are deployed against the
///         new addresses (keeper tolerates legacy hooks; the indexer must watch both). The script
///         prints the exact flip command at the end.
///
///         Existing pools keep the old hook forever (the hook address is hashed into every V4
///         PoolId). Legacy MetaVesT grants must keep the OLD condition contract: the new one calls
///         `hook.COARSE_INTERVAL()` and reverts against legacy hooks.
///
/// @dev forge script script/DeployOracleUpgrade.s.sol:DeployOracleUpgrade --rpc-url <rpc>          # simulate
///      forge script script/DeployOracleUpgrade.s.sol:DeployOracleUpgrade --rpc-url <rpc> --broadcast --verify
///
///      Env (all required):
///        DEPLOYER_PRIVATE_KEY — funded key; MUST derive to UMIA_HOOK_DEPLOYER (initialize reverts otherwise)
///        UMIA_HOOK_DEPLOYER   — EOA embedded as the hook's INITIAL_OWNER
///        UMIA_HOOK_SALT       — salt mined from THIS commit's bytecode (MineUmiaHookSalt.s.sol)
///        POOL_MANAGER         — canonical Uniswap v4 PoolManager on this chain
///        UMIA_HUB_ADDRESS     — the live hub proxy
///        TWAP_WINDOW          — condition window in seconds (mainnet: 2592000). No default.
contract DeployOracleUpgrade is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerEOA = vm.envAddress("UMIA_HOOK_DEPLOYER");
        bytes32 hookSalt = vm.envBytes32("UMIA_HOOK_SALT");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hubAddr = vm.envAddress("UMIA_HUB_ADDRESS");
        uint32 twapWindow = uint32(vm.envUint("TWAP_WINDOW"));

        address broadcaster = vm.addr(deployerPrivateKey);
        require(
            broadcaster == deployerEOA,
            "DeployOracleUpgrade: DEPLOYER_PRIVATE_KEY must derive to UMIA_HOOK_DEPLOYER (initialize is one-shot, INITIAL_OWNER-gated)"
        );
        require(hubAddr.code.length > 0, "DeployOracleUpgrade: UMIA_HUB_ADDRESS has no bytecode on this chain");
        require(poolManager.code.length > 0, "DeployOracleUpgrade: POOL_MANAGER has no bytecode on this chain");

        console.log("Deployer / INITIAL_OWNER:", broadcaster);
        console.log("Hub (existing):", hubAddr);
        console.log("PoolManager:", poolManager);
        console.log("TWAP window (s):", twapWindow);

        // CreateX's _guard for our `0xDead00...DD00` salt prefix (SenderBytes.Random,
        // RedeployFlag.False) hashes the salt before passing it to CREATE2:
        //     guardedSalt = keccak256(salt)
        // so the predicted address must use the hashed salt. We still pass the RAW salt to
        // CreateX; CreateX applies _guard internally. MineUmiaHookSalt.s.sol mirrors this
        // transformation when mining, so the address it predicts matches what CreateX deploys.
        bytes32 hookGuardedSalt = keccak256(abi.encodePacked(hookSalt));
        bytes memory hookCreationCode = abi.encodePacked(type(UmiaHook).creationCode, abi.encode(deployerEOA));
        address predictedHook = HookMiner.computeAddress(CREATE_X, uint256(hookGuardedSalt), hookCreationCode);
        require(
            uint160(predictedHook) & 0x3FFF == UMIA_HOOK_FLAGS,
            "DeployOracleUpgrade: predicted UmiaHook address missing required permission bits"
        );
        require(
            predictedHook.code.length == 0,
            "DeployOracleUpgrade: hook already deployed at predicted address (stale salt for this bytecode?)"
        );
        console.log("UmiaHook will deploy at:", predictedHook);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy via CreateX. The selector is deployCreate2(bytes32 salt, bytes memory initCode).
        (bool ok, bytes memory ret) =
            CREATE_X.call(abi.encodeWithSignature("deployCreate2(bytes32,bytes)", hookSalt, hookCreationCode));
        require(ok, "DeployOracleUpgrade: CreateX UmiaHook deploy failed");
        address umiaHookAddr = abi.decode(ret, (address));
        require(umiaHookAddr == predictedHook, "DeployOracleUpgrade: actual UmiaHook address differs from predicted");
        UmiaHook umiaHook = UmiaHook(umiaHookAddr);
        console.log("UmiaHook deployed at:", umiaHookAddr);

        // Deploy the factory against the EXISTING hub; it embeds the new SpotLiquidityVault
        // creation code, so post-flip ventures seed the coarse ring at bootstrap.
        UmiaLBPFactory lbpFactory = new UmiaLBPFactory(IPoolManager(poolManager), umiaHookAddr, hubAddr);
        console.log("UmiaLBPFactory deployed at:", address(lbpFactory));

        // One-shot wiring; broadcaster is INITIAL_OWNER (checked above).
        umiaHook.initialize(address(lbpFactory), IPoolManager(poolManager));
        console.log("UmiaHook initialized");

        UmiaTwapMilestoneCondition condition = new UmiaTwapMilestoneCondition(twapWindow);
        console.log("UmiaTwapMilestoneCondition deployed at:", address(condition));

        vm.stopBroadcast();

        // Post-deploy wiring assertions.
        require(umiaHook.factory() == address(lbpFactory), "DeployOracleUpgrade: hook.factory mismatch");
        require(address(umiaHook.poolManager()) == poolManager, "DeployOracleUpgrade: hook.poolManager mismatch");
        require(lbpFactory.umiaHook() == umiaHookAddr, "DeployOracleUpgrade: factory.umiaHook mismatch");
        require(lbpFactory.hub() == hubAddr, "DeployOracleUpgrade: factory.hub mismatch");
        require(condition.TWAP_WINDOW() == twapWindow, "DeployOracleUpgrade: condition window mismatch");

        console.log("\n--- contracts.json ---");
        console.log("umiaHook=%s", umiaHookAddr);
        console.log("lbpFactory=%s", address(lbpFactory));
        console.log("twapMilestoneCondition=%s", address(condition));

        console.log("\n--- Next steps (in order) ---");
        console.log("1. Deploy keeper + indexer against these addresses (indexer must watch BOTH hooks).");
        console.log("2. Flip the factory from the hub owner:");
        console.log(
            string.concat(
                "   cast send ",
                vm.toString(hubAddr),
                ' "setLbpStrategyFactory(address)" ',
                vm.toString(address(lbpFactory)),
                " --rpc-url <rpc> --private-key <hub-owner>"
            )
        );
        console.log("3. Keep the OLD condition address for legacy MetaVesT grants (legacy hooks have");
        console.log("   no COARSE_INTERVAL; the new condition reverts against them).");
    }
}
