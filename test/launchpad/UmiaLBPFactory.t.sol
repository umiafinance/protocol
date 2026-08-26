// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmiaLBPFactory} from "../../src/launchpad/UmiaLBPFactory.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract UmiaLBPFactoryTest is Test {
    UmiaLBPFactory public factory;

    address constant TOKEN = address(0x1);
    address constant CURRENCY = address(0x2);
    address constant VENTURE = address(0x3);
    address constant POOL_MANAGER = address(0x5);
    address constant HUB = address(0x8);
    address constant UMIA_HOOK = address(0xCc000000000000000000000000000000000038c4);

    function setUp() public {
        factory = new UmiaLBPFactory(IPoolManager(POOL_MANAGER), UMIA_HOOK, HUB);
    }

    function test_Factory_Deploys() public view {
        assertEq(address(factory.poolManager()), POOL_MANAGER);
        assertEq(factory.umiaHook(), UMIA_HOOK);
        assertEq(factory.hub(), HUB);
    }

    function test_Factory_RevertsWhen_PoolManagerIsZero() public {
        vm.expectRevert(UmiaLBPFactory.InvalidPoolManager.selector);
        new UmiaLBPFactory(IPoolManager(address(0)), UMIA_HOOK, HUB);
    }

    function test_Factory_RevertsWhen_HookIsZero() public {
        vm.expectRevert(UmiaLBPFactory.InvalidUmiaHook.selector);
        new UmiaLBPFactory(IPoolManager(POOL_MANAGER), address(0), HUB);
    }

    function test_Factory_RevertsWhen_HubIsZero() public {
        vm.expectRevert(UmiaLBPFactory.InvalidHub.selector);
        new UmiaLBPFactory(IPoolManager(POOL_MANAGER), UMIA_HOOK, address(0));
    }

    function test_Factory_RevertsWhen_CallerIsNotHub() public {
        bytes memory configData = _createConfigData();

        vm.expectRevert(UmiaLBPFactory.Unauthorized.selector);
        factory.create(TOKEN, 1_000_000e18, configData, bytes32(0));
    }

    function test_Factory_RevertsTotalSupplyTooLarge() public {
        uint256 tooLarge = uint256(type(uint128).max) + 1;
        bytes memory configData = _createConfigData();

        vm.prank(HUB);
        vm.expectRevert(abi.encodeWithSelector(UmiaLBPFactory.InvalidAmount.selector, tooLarge, type(uint128).max));
        factory.create(TOKEN, tooLarge, configData, bytes32(0));
    }

    function test_Factory_PredictsAddress() public {
        uint128 totalSupply = 1_000_000e18;
        bytes memory configData = _createConfigData();
        bytes32 salt = bytes32(uint256(1));

        address predicted = address(factory.getAddress(TOKEN, totalSupply, configData, salt, HUB));
        address predicted2 = address(factory.getAddress(TOKEN, totalSupply, configData, salt, HUB));
        assertEq(predicted, predicted2, "Prediction should be deterministic");

        vm.prank(HUB);
        address deployed = address(factory.create(TOKEN, totalSupply, configData, salt));
        assertEq(predicted, deployed, "getAddress should match the create() deployment");
    }

    function test_Factory_DifferentSaltsDifferentAddresses() public view {
        uint128 totalSupply = 1_000_000e18;
        bytes memory configData = _createConfigData();

        address addr1 = address(factory.getAddress(TOKEN, totalSupply, configData, bytes32(uint256(1)), HUB));
        address addr2 = address(factory.getAddress(TOKEN, totalSupply, configData, bytes32(uint256(2)), HUB));

        assertTrue(addr1 != addr2, "Addresses should differ");
    }

    function test_Factory_GetAddressRevertsTotalSupplyTooLarge() public {
        uint256 tooLarge = uint256(type(uint128).max) + 1;
        bytes memory configData = _createConfigData();

        vm.expectRevert(abi.encodeWithSelector(UmiaLBPFactory.InvalidAmount.selector, tooLarge, type(uint128).max));
        factory.getAddress(TOKEN, tooLarge, configData, bytes32(0), HUB);
    }

    function test_Factory_PopulatesIsLBP() public {
        bytes memory configData = _createConfigData();
        vm.prank(HUB);
        address deployed = address(factory.create(TOKEN, 1_000_000e18, configData, bytes32(uint256(1))));
        assertTrue(factory.isLBP(deployed));
        assertFalse(factory.isLBP(address(0xCAFE)));
    }

    function _createConfigData() internal pure returns (bytes memory) {
        return abi.encode(uint256(5_000_000), CURRENCY, "", VENTURE, uint256(2000), address(0x7), uint256(50));
    }
}
