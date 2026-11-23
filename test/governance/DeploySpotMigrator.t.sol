// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeploySpotMigrator} from "../../script/DeploySpotMigrator.s.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {UmiaHookV2} from "../../src/periphery/UmiaHookV2.sol";
import {SpotLiquidityV2Code} from "../../src/periphery/SpotLiquidityV2Code.sol";
import {SpotMigrator} from "../../src/periphery/SpotMigrator.sol";

contract DeploySpotMigratorTest is Deployers {
    uint256 constant DEPLOYER_KEY = 0xDE9107;
    uint256 constant MIN_DELAY = 2 days;
    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant SOURCE_HOOK = address(uint160(0x1111 << 20) | 0x3A80);
    address constant HOOK_V2 = address(uint160(0x2222 << 20) | 0x3A80);

    UmiaHub hub;
    SpotLiquidityV2Code code;
    DeploySpotMigrator script;

    function setUp() public {
        deployFreshManagerAndRouters();
        hub = UmiaHub(address(new ERC1967Proxy(address(new UmiaHub()), abi.encodeCall(UmiaHub.initialize, (OWNER)))));
        deployCodeTo("UmiaHook.sol:UmiaHook", abi.encode(OWNER), SOURCE_HOOK);
        deployCodeTo("UmiaHookV2.sol:UmiaHookV2", abi.encode(OWNER), HOOK_V2);
        vm.prank(OWNER);
        UmiaHookV2(HOOK_V2).initialize(FACTORY, manager, address(hub));
        code = new SpotLiquidityV2Code();
        script = new DeploySpotMigrator();
    }

    function _config() internal view returns (DeploySpotMigrator.Config memory) {
        return DeploySpotMigrator.Config({
            deployerKey: DEPLOYER_KEY,
            hub: address(hub),
            poolManager: address(manager),
            sourceHook: SOURCE_HOOK,
            hookV2: HOOK_V2,
            code: address(code),
            targetFee: 3_000
        });
    }

    function test_deploysFromTheDeployerAndHandsOffToTheOwner() public {
        address expected = vm.computeCreateAddress(vm.addr(DEPLOYER_KEY), vm.getNonce(vm.addr(DEPLOYER_KEY)));

        DeploySpotMigrator.Plan memory plan = script.deploy(_config());

        assertEq(plan.migrator, expected);
        SpotMigrator migrator = SpotMigrator(plan.migrator);
        assertEq(migrator.HUB(), address(hub));
        assertEq(address(migrator.poolManager()), address(manager));
        assertEq(migrator.hookV2(), HOOK_V2);
        assertEq(migrator.sourceHook(), SOURCE_HOOK);
        assertEq(migrator.targetFee(), 3_000);

        assertEq(plan.owner, OWNER);
        assertEq(plan.data, abi.encodeCall(IUmiaHub.setSpotMigrator, (plan.migrator)));
        assertEq(hub.spotMigrator(), address(0));
        vm.prank(OWNER);
        (bool ok,) = plan.hub.call(plan.data);
        assertTrue(ok);
        assertEq(hub.spotMigrator(), plan.migrator);
    }

    function test_timelockHandoffExecutesViaScheduleAndExecute() public {
        address safe = makeAddr("safe");
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
        vm.prank(OWNER);
        hub.transferOwnership(address(timelock));

        DeploySpotMigrator.Plan memory plan = script.deploy(_config());
        assertEq(plan.owner, address(timelock));

        vm.prank(safe);
        timelock.schedule(plan.hub, 0, plan.data, bytes32(0), plan.salt, MIN_DELAY);
        skip(MIN_DELAY);
        timelock.execute(plan.hub, 0, plan.data, bytes32(0), plan.salt);
        assertEq(hub.spotMigrator(), plan.migrator);
    }

    function test_failsOnATargetFeeTheMigratorRefuses() public {
        DeploySpotMigrator.Config memory cfg = _config();
        cfg.targetFee = 150;
        vm.expectRevert(SpotMigrator.InvalidParams.selector);
        script.deploy(cfg);
    }

    function test_rejectsAHookWiredToAnotherHub() public {
        DeploySpotMigrator.Config memory cfg = _config();
        cfg.hub = address(new ERC1967Proxy(address(new UmiaHub()), abi.encodeCall(UmiaHub.initialize, (OWNER))));
        vm.expectRevert(bytes("hook V2 is wired to another hub"));
        script.deploy(cfg);
    }

    function test_rejectsAHookWiredToAnotherPoolManager() public {
        DeploySpotMigrator.Config memory cfg = _config();
        cfg.poolManager = address(hub);
        vm.expectRevert(bytes("hook V2 is wired to another pool manager"));
        script.deploy(cfg);
    }

    function test_rejectsInputsWithoutCode() public {
        DeploySpotMigrator.Config memory cfg = _config();
        cfg.sourceHook = address(0xDEAD);
        vm.expectRevert(bytes("source hook has no bytecode"));
        script.deploy(cfg);

        cfg = _config();
        cfg.code = address(0xDEAD);
        vm.expectRevert(bytes("V2 code has no bytecode"));
        script.deploy(cfg);
    }

    function test_rejectsTheSourceHookAsHookV2() public {
        DeploySpotMigrator.Config memory cfg = _config();
        cfg.sourceHook = HOOK_V2;
        vm.expectRevert(bytes("source hook and hook V2 are the same address"));
        script.deploy(cfg);
    }
}
