// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {YieldPositionGuardian} from "../src/periphery/YieldPositionGuardian.sol";

/// @title DeployYieldPositionGuardian
/// @notice Deploys an YieldPositionGuardian wrapper for one venture. Inert until governance wires it:
///         - Aave-style:    SET_ALLOWANCE(aToken, wrapper, type(uint256).max)  // aToken, not underlying
///         - Morpho Blue:   CALL(morpho, setAuthorization(wrapper, true))       // direct market supply only
///         - ERC-4626 vault: SET_ALLOWANCE(vaultShares, wrapper, type(uint256).max)
///
///         Environment:
///         - DEPLOYER_PRIVATE_KEY        deployer key (required)
///         - VENTURE_ADDRESS             the venture treasury this wrapper serves (required)
///         - EMERGENCY_OPERATOR          operator address, ideally a Safe (required)
///         - ALLOW_EOA_OPERATOR          set "true" to permit a bytecode-less operator
///                                       (default false; a Safe deploys its own bytecode)
contract DeployYieldPositionGuardian is Script {
    function run() external returns (YieldPositionGuardian exit_) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address venture = vm.envAddress("VENTURE_ADDRESS");
        address operator = vm.envAddress("EMERGENCY_OPERATOR");
        bool allowEoa = vm.envOr("ALLOW_EOA_OPERATOR", false);

        require(venture != address(0), "VENTURE_ADDRESS unset");
        require(operator != address(0), "EMERGENCY_OPERATOR unset");
        require(venture.code.length > 0, "VENTURE_ADDRESS has no bytecode");
        if (!allowEoa) {
            require(
                operator.code.length > 0, "EMERGENCY_OPERATOR has no bytecode (set ALLOW_EOA_OPERATOR=true to override)"
            );
        }
        require(operator != venture, "operator must not be the venture itself");

        console.log("Venture:  ", venture);
        console.log("Operator: ", operator);

        vm.startBroadcast(deployerKey);
        exit_ = new YieldPositionGuardian(venture, operator);
        vm.stopBroadcast();

        // Post-deploy assertions: the safety invariant is entirely in these two values.
        require(exit_.venture() == venture, "venture mismatch");
        require(exit_.owner() == operator, "operator mismatch");

        console.log("YieldPositionGuardian deployed:", address(exit_));
        console.log("");
        console.log("Next steps (governance plan actions):");
        console.log("  Aave-style:    SET_ALLOWANCE(aToken, wrapper, maxUint256)");
        console.log("  Morpho Blue:   CALL(morpho, setAuthorization(wrapper, true))");
        console.log("  ERC-4626 vault: SET_ALLOWANCE(vaultShares, wrapper, maxUint256)");
    }
}
