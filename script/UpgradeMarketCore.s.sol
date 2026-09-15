// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UpgradeBase} from "./UpgradeBase.s.sol";
import {UmiaMarketCore} from "../src/core/UmiaMarketCore.sol";

/// @notice `just forge-upgrade market-core <env> <chain>`; flow and environment in UpgradeBase.
///         Forge deploys and links fresh MarketCreationLib/SettlementLib copies; the run prints
///         their addresses for contracts.json and explorer verification.
contract UpgradeMarketCore is UpgradeBase {
    constructor() UpgradeBase(Kind.MarketCore) {}

    function _deployImplementation() internal virtual override returns (address) {
        return address(new UmiaMarketCore());
    }
}
