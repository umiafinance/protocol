// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }
}
