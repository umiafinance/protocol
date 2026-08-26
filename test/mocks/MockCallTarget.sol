// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockCallTarget {
    uint256 public value;
    uint256 public lastValue;
    bytes public lastData;

    event Called(uint256 value, bytes data);

    function setValue(uint256 nextValue) external payable returns (uint256) {
        value = nextValue;
        lastValue = msg.value;
        lastData = msg.data;
        emit Called(msg.value, msg.data);
        return value;
    }

    function alwaysRevert() external pure {
        revert("fail");
    }
}
