// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {UmiaHook} from "../../src/periphery/UmiaHook.sol";

/// @notice Stand-in pool manager for LBP unit tests.
/// @dev Fires the hook's beforeInitialize + afterInitialize callbacks so the singleton UmiaHook's
///      oracle state seeds even when the pool manager itself isn't real. Replies to extsload reads
///      with zero so StateLibrary.getSlot0 / getLiquidity return safe defaults.
contract MockPoolManagerForLBP {
    UmiaHook public hook;

    function setHook(UmiaHook _hook) external {
        hook = _hook;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        hook.beforeInitialize(msg.sender, key, sqrtPriceX96);
        hook.afterInitialize(msg.sender, key, sqrtPriceX96, 0);
        return 0;
    }

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}
