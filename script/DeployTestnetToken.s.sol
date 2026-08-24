// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UmiaHub} from "../src/core/UmiaHub.sol";

contract TestnetToken is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) Ownable(msg.sender) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

/// @title DeployTestnetToken
/// @notice Deploys a mintable ERC20 for testnet use.
/// @dev Environment variables:
///   DEPLOYER_PRIVATE_KEY  — required
///   TOKEN_NAME            — optional, defaults to "USD Coin"
///   TOKEN_SYMBOL          — optional, defaults to "USDC"
///   TOKEN_DECIMALS        — optional, defaults to 6
///   INITIAL_MINT          — optional, amount to mint to deployer (in token units, not wei)
///   UMIA_HUB_ADDRESS      — optional, if set registers token as approved money token on Hub
contract DeployTestnetToken is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory name = vm.envOr("TOKEN_NAME", string("USD Coin"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("USDC"));
        uint8 tokenDecimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(6)));

        console.log("Deploying TestnetToken...");
        console.log("Deployer:", deployer);
        console.log("Token:", name, symbol);

        vm.startBroadcast(pk);

        TestnetToken token = new TestnetToken(name, symbol, tokenDecimals);
        console.log("TestnetToken deployed at:", address(token));

        uint256 initialMint = vm.envOr("INITIAL_MINT", uint256(0));
        if (initialMint > 0) {
            uint256 amount = initialMint * (10 ** tokenDecimals);
            token.mint(deployer, amount);
            console.log("Minted", initialMint, "tokens to deployer");
        }

        address hubAddress = vm.envOr("UMIA_HUB_ADDRESS", address(0));
        if (hubAddress != address(0)) {
            UmiaHub hub = UmiaHub(hubAddress);
            hub.setApprovedMoneyToken(address(token), true);
            console.log("Registered as approved money token on Hub:", hubAddress);
        }

        vm.stopBroadcast();

        console.log("\n--- Environment Variables ---");
        console.log("TOKEN_ADDRESS=%s", address(token));
    }
}
