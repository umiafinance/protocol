// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {UmiaHook} from "../../src/periphery/UmiaHook.sol";

contract UmiaHookAddressTest is Test {
    uint160 constant EXPECTED_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

    address constant OWNER = address(0xABCD);

    function test_CreationCodeHashIsStable() public pure {
        bytes32 a = keccak256(type(UmiaHook).creationCode);
        bytes32 b = keccak256(type(UmiaHook).creationCode);
        require(a == b, "creation code hash is not stable");
    }

    function test_MinedAddressMatchesPermissionMask() public {
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), EXPECTED_FLAGS, type(UmiaHook).creationCode, abi.encode(OWNER));
        UmiaHook deployed = new UmiaHook{salt: salt}(OWNER);
        assertEq(address(deployed), predicted);
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, EXPECTED_FLAGS);
    }

    function test_HookValidatesPermissions() public {
        (, bytes32 salt) = HookMiner.find(address(this), EXPECTED_FLAGS, type(UmiaHook).creationCode, abi.encode(OWNER));
        UmiaHook deployed = new UmiaHook{salt: salt}(OWNER);
        Hooks.validateHookPermissions(IHooks(address(deployed)), deployed.getHookPermissions());
    }
}
