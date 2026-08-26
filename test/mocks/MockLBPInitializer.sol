// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    ILBPInitializer,
    LBPInitializationParams,
    ILBP_INITIALIZER_INTERFACE_ID
} from "@liquidity-launcher/interfaces/ILBPInitializer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockLBPInitializer is ILBPInitializer {
    uint256 private _currencyRaised;
    uint256 private _initialPriceX96;
    address private _currency;
    address private _token;
    address private _fundsRecipient;
    address private _tokensRecipient;
    uint64 private _endBlock;

    uint256 public sweepCurrencyBlock;
    uint256 public sweepUnsoldTokensBlock;

    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;

    constructor(uint256 currencyRaised_, uint256 initialPriceX96_, address currency_, address token_) {
        _currencyRaised = currencyRaised_;
        _initialPriceX96 = initialPriceX96_;
        _currency = currency_;
        _token = token_;
    }

    function setFundsRecipient(address fundsRecipient_) external {
        _fundsRecipient = fundsRecipient_;
    }

    function setTokensRecipient(address tokensRecipient_) external {
        _tokensRecipient = tokensRecipient_;
    }

    function setEndBlock(uint64 endBlock_) external {
        _endBlock = endBlock_;
    }

    function sweepCurrency() external virtual {
        require(sweepCurrencyBlock == 0, "Already swept currency");
        sweepCurrencyBlock = block.number;
        uint256 bal = IERC20(_currency).balanceOf(address(this));
        if (bal > 0) {
            IERC20(_currency).transfer(_fundsRecipient, bal);
        }
    }

    function sweepUnsoldTokens() external {
        require(sweepUnsoldTokensBlock == 0, "Already swept tokens");
        sweepUnsoldTokensBlock = block.number;
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(_token).transfer(_tokensRecipient, bal);
        }
    }

    function lbpInitializationParams() external view returns (LBPInitializationParams memory) {
        return
            LBPInitializationParams({initialPriceX96: _initialPriceX96, tokensSold: 0, currencyRaised: _currencyRaised});
    }

    function token() external view returns (address) {
        return _token;
    }

    function currency() external view returns (address) {
        return _currency;
    }

    function totalSupply() external pure returns (uint128) {
        return 0;
    }

    function tokensRecipient() external view returns (address) {
        return _tokensRecipient;
    }

    function fundsRecipient() external view returns (address) {
        return _fundsRecipient;
    }

    function startBlock() external pure returns (uint64) {
        return 0;
    }

    function endBlock() external view returns (uint64) {
        return _endBlock;
    }

    function onTokensReceived() external pure {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == ILBP_INITIALIZER_INTERFACE_ID || interfaceId == ERC165_INTERFACE_ID;
    }
}
