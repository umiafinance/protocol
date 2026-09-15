// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockArbSys {
    uint256 internal _arbBlockNumber;

    function setArbBlockNumber(uint256 value) external {
        _arbBlockNumber = value;
    }

    function arbBlockNumber() external view returns (uint256) {
        return _arbBlockNumber;
    }
}
