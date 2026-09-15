// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IAaveV3Pool, IMorphoBlue} from "../../src/periphery/YieldPositionGuardian.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev The src-level pool surface plus `supply`, shared by the unit and fork suites.
interface IAaveV3PoolSupply is IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/// @dev Stand-in for a Venture treasury: holds funds, supplies to money markets, grants allowances.
contract FakeVenture {
    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function supply(address pool, address asset, uint256 amount) external {
        IERC20(asset).approve(pool, amount);
        IAaveV3PoolSupply(pool).supply(asset, amount, address(this), 0);
    }

    function morphoSupply(address morpho, address asset, uint256 amount) external {
        IERC20(asset).approve(morpho, amount);
        FakeMorpho(morpho).supply(amount, address(this));
    }

    function morphoAuthorize(address morpho, address authorized, bool newIsAuthorized) external {
        FakeMorpho(morpho).setAuthorization(authorized, newIsAuthorized);
    }

    function vaultDeposit(address vault, uint256 assets) external {
        IERC20(IERC4626(vault).asset()).approve(vault, assets);
        IERC4626(vault).deposit(assets, address(this));
    }
}

/// @dev Minimal Morpho Blue stand-in: enforces the real setAuthorization direction and records
///      the onBehalf/receiver the wrapper passed.
contract FakeMorpho {
    IERC20 public immutable loanToken;

    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(address => uint256) public supplyBalance;
    address public lastReceiver;
    address public lastOnBehalf;

    error Unauthorized();

    constructor(address _loanToken) {
        loanToken = IERC20(_loanToken);
    }

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    function supply(uint256 amount, address onBehalf) external {
        loanToken.transferFrom(msg.sender, address(this), amount);
        supplyBalance[onBehalf] += amount;
    }

    function withdraw(IMorphoBlue.MarketParams calldata, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalf && !isAuthorized[onBehalf][msg.sender]) revert Unauthorized();
        require(assets > 0 && assets <= supplyBalance[onBehalf], "assets");
        supplyBalance[onBehalf] -= assets;
        lastOnBehalf = onBehalf;
        lastReceiver = receiver;
        loanToken.transfer(receiver, assets);
        return (assets, 0);
    }
}

/// @dev aToken stand-in: like the canonical MockERC20 but with a `burn` for the fake pool.
contract FakeAToken is MockERC20 {
    constructor() MockERC20("aUSDC", "aUSDC", 18) {}

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Minimal aToken-style pool: mints aToken 1:1 on supply, burns on withdraw, honors `to`.
contract FakeAavePool {
    IERC20 public immutable asset;
    FakeAToken public immutable aToken;

    constructor(address _asset, address _aToken) {
        asset = IERC20(_asset);
        aToken = FakeAToken(_aToken);
    }

    function supply(address _asset, uint256 amount, address onBehalfOf, uint16) external {
        require(_asset == address(asset), "asset");
        asset.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address _asset, uint256 amount, address to) external returns (uint256) {
        require(_asset == address(asset), "asset");
        uint256 balance = aToken.balanceOf(msg.sender);
        uint256 redeemed = amount == type(uint256).max ? balance : amount;
        require(redeemed <= balance, "balance");
        aToken.burn(msg.sender, redeemed);
        asset.transfer(to, redeemed);
        return redeemed;
    }
}
