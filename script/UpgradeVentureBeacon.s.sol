// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpgradeBase} from "./UpgradeBase.s.sol";
import {Venture} from "../src/core/Venture.sol";

/// @notice `just forge-upgrade venture-beacon <env> <chain>`; flow and environment in UpgradeBase.
///         Every venture that has not opted out moves atomically; no calldata can ride along.
contract UpgradeVentureBeacon is UpgradeBase {
    constructor() UpgradeBase(Kind.VentureBeacon) {}

    function _deployImplementation() internal virtual override returns (address) {
        return address(new Venture());
    }
}
