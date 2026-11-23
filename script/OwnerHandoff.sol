// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title OwnerHandoff
/// @notice What every script that deploys from one account and leaves a call to another shares:
///         the deployer (a key, or a hardware wallet through forge's --ledger/--trezor flags with
///         DEPLOYER_ADDRESS set to the signer) and the printed call the owner must send, with the
///         schedule/execute pair when that owner is a TimelockController.
abstract contract OwnerHandoff is Script {
    /// @dev A zero key means hardware-wallet mode: the CLI wallet flags carry the signer.
    function _deployer(uint256 deployerKey) internal view returns (address) {
        if (deployerKey != 0) return vm.addr(deployerKey);
        return vm.envAddress("DEPLOYER_ADDRESS");
    }

    function _startBroadcast(uint256 deployerKey) internal {
        if (deployerKey != 0) vm.startBroadcast(deployerKey);
        else vm.startBroadcast();
    }

    function _logOwnerCall(address target, address owner, bytes memory data, bytes32 salt) internal view {
        console.log("\n== Owner action required ==");
        console.log("send to:  ", target);
        console.log("from:     ", owner);
        console.log("calldata: ", vm.toString(data));

        (bool isTimelock, uint256 minDelay) = _timelockDelay(owner);
        if (!isTimelock) {
            if (owner.code.length > 0) {
                console.log("owner is a contract (Safe): submit the calldata above via the transaction builder");
            } else {
                if (vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0)) != 0) {
                    console.log("owner is an EOA: cast send <send to> <calldata> --private-key <owner key>");
                } else {
                    string memory hw = vm.envOr("HW_WALLET", string("ledger"));
                    console.log(
                        string.concat(
                            "owner is an EOA: cast send <send to> <calldata> --",
                            hw,
                            " --mnemonic-index ",
                            vm.toString(vm.envOr("LEDGER_INDEX", uint256(0)))
                        )
                    );
                }
            }
            return;
        }

        TimelockController timelock = TimelockController(payable(owner));
        bytes32 id = timelock.hashOperation(target, 0, data, bytes32(0), salt);
        console.log("\nowner is a TimelockController; two steps:");
        console.log("1. proposer (Safe) -> timelock.schedule, min delay (s):", minDelay);
        console.log("   to:      ", owner);
        console.log(
            "   calldata:",
            vm.toString(abi.encodeCall(timelock.schedule, (target, 0, data, bytes32(0), salt, minDelay)))
        );
        console.log("2. executor (the Safe) -> timelock.execute once ready (isOperationReady(id))");
        console.log("   to:      ", owner);
        console.log("   calldata:", vm.toString(abi.encodeCall(timelock.execute, (target, 0, data, bytes32(0), salt))));
        console.log("   operation id:", vm.toString(id));
        console.log("   salt:        ", vm.toString(salt));
    }

    function _timelockDelay(address owner) private view returns (bool isTimelock, uint256 minDelay) {
        if (owner.code.length == 0) return (false, 0);
        (bool ok, bytes memory ret) = owner.staticcall(abi.encodeCall(TimelockController.getMinDelay, ()));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
