// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";

/// @dev Reference shape for a real V2: appended storage seeded by a `reinitializer(n)` that is
///      gated by the same authority as `_authorizeUpgrade` and delivered atomically through
///      `upgradeToAndCall`. Production contracts append before `__gap` and shrink it; these mocks
///      inherit, so the new slot lands after the gap, which is equally safe for a leaf contract.
contract UmiaHubV2 is UmiaHub {
    uint256 public v2Value;

    function initializeV2(uint256 value) external reinitializer(2) onlyOwner {
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UmiaMarketCoreV2 is UmiaMarketCore {
    uint256 public v2Value;

    function initializeV2(uint256 value) external reinitializer(2) {
        if (msg.sender != HUB.owner()) revert IUmiaMarketCore.Unauthorized();
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Venture's `initialize` is already `reinitializer(2)`, so the next version is 3. The gate
///      accepts the governance executor (the atomic opt-out path: `upgradeToAndCall`'s delegatecall
///      preserves it as msg.sender) and the hub owner, who sweeps proxies after a beacon upgrade
///      since `beacon.upgradeTo` cannot carry calldata.
contract VentureV2 is Venture {
    uint256 public v2Value;

    function initializeV2(uint256 value) external reinitializer(3) {
        address executor = IUmiaHub(HUB).governanceExecutor(address(this));
        if (msg.sender != executor && msg.sender != IUmiaHub(HUB).owner()) revert IVenture.CallerNotAuthorized();
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
