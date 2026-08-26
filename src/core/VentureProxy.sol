// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @title VentureProxy
/// @notice Beacon-first proxy with UUPS opt-out support.
///         By default, reads the implementation from an UpgradeableBeacon so all
///         Venture instances share the canonical implementation. If the ERC1967
///         implementation slot is written (via UUPS upgradeToAndCall from the
///         governance executor), the proxy switches to that direct implementation
///         and no longer follows the beacon.
contract VentureProxy is Proxy {
    /// @notice The beacon contract to use for the proxy.
    address private immutable _beacon;

    /// @notice Initializes the proxy with a beacon and data.
    /// @param beacon The beacon contract to use for the proxy.
    /// @param data The data to use for the proxy.
    constructor(address beacon, bytes memory data) payable {
        ERC1967Utils.upgradeBeaconToAndCall(beacon, data);
        _beacon = beacon;
    }

    /// @notice Returns the implementation address for the proxy.
    /// @return impl The implementation address.
    function _implementation() internal view override returns (address impl) {
        impl = ERC1967Utils.getImplementation();
        if (impl == address(0) || impl.code.length == 0) {
            impl = IBeacon(_beacon).implementation();
        }
    }
}
