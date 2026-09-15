// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Aave-style aToken: balances are scaled units times a growing index, so an exact-amount
///      transfer can deliver one wei less than requested.
contract MockRebasingERC20 is IERC20 {
    uint256 private constant RAY = 1e27;

    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public index = RAY;

    mapping(address => uint256) private _scaled;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _scaledSupply;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function setIndex(uint256 rayIndex) external {
        index = rayIndex;
    }

    function mint(address to, uint256 amount) external {
        uint256 scaled = (amount * RAY) / index;
        _scaled[to] += scaled;
        _scaledSupply += scaled;
        emit Transfer(address(0), to, amount);
    }

    function totalSupply() external view returns (uint256) {
        return (_scaledSupply * index) / RAY;
    }

    function balanceOf(address account) public view returns (uint256) {
        return (_scaled[account] * index) / RAY;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 scaled = (amount * RAY) / index;
        require(_scaled[from] >= scaled, "balance");
        _scaled[from] -= scaled;
        _scaled[to] += scaled;
        emit Transfer(from, to, amount);
    }
}
