// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";

contract UmiaHubV2 is UmiaHub {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UmiaMarketCoreV2 is UmiaMarketCore {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract VentureV2 is Venture {
    function version() external pure returns (uint256) {
        return 2;
    }
}
