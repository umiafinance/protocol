// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockERC4626 is ERC4626 {
    using SafeERC20 for IERC20;

    error VaultIlliquid();

    uint8 private immutable _offset;
    bool public liquid = true;

    constructor(IERC20 asset_, uint8 offset_) ERC20("Mock Vault", "mVLT") ERC4626(asset_) {
        _offset = offset_;
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return _offset;
    }

    function setLiquid(bool value) external {
        liquid = value;
    }

    function donate(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (!liquid) revert VaultIlliquid();
        return super.withdraw(assets, receiver, owner);
    }
}
