// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpgradeBase} from "./UpgradeBase.s.sol";
import {UmiaHub} from "../src/core/UmiaHub.sol";

/// @notice `just forge-upgrade hub <env> <chain>`; flow and environment in UpgradeBase.
contract UpgradeHub is UpgradeBase {
    constructor() UpgradeBase(Kind.Hub) {}

    function _deployImplementation() internal virtual override returns (address) {
        return address(new UmiaHub());
    }
}
