// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {SpotLiquidityVault} from "../../src/core/SpotLiquidityVault.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {UmiaHook} from "../../src/periphery/UmiaHook.sol";
import {ILBPMigrationCallback} from "../../src/interfaces/ILBPMigrationCallback.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLBPInitializer} from "../mocks/MockLBPInitializer.sol";
import {MockPoolManagerForLBP} from "../mocks/MockPoolManagerForLBP.sol";

/// @notice Tests for Phase 2: Currency distribution in migrate()
contract UmiaLBPMigrationTest is Test {
    address internal vaultCodePointer = SSTORE2.write(type(SpotLiquidityVault).creationCode);
    address constant VENTURE = address(0x1);
    address constant AUCTION_FACTORY = address(0x6);
    address constant MOCK_HUB = address(0x8);

    uint128 constant TOTAL_SUPPLY = 1_000_000e18;
    uint160 constant HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

    MockERC20 public mockCurrency;
    MockERC20 public mockToken;
    MockPoolManagerForLBP public mockPoolManager;
    UmiaHook public umiaHook;

    function setUp() public {
        mockCurrency = new MockERC20("Mock Currency", "MCUR", 18);
        mockToken = new MockERC20("Mock Token", "MTOK", 18);
        mockPoolManager = new MockPoolManagerForLBP();

        umiaHook = _deployUmiaHook();
        mockPoolManager.setHook(umiaHook);

        // Mock the LBP migration callback on VENTURE
        vm.mockCall(VENTURE, abi.encodeWithSelector(ILBPMigrationCallback.onLBPMigrated.selector), abi.encode());

        // Pretend the test contract is the LBP factory: anything claiming to be an LBP passes.
        vm.mockCall(address(this), abi.encodeWithSelector(bytes4(keccak256("isLBP(address)"))), abi.encode(true));

        vm.mockCall(VENTURE, abi.encodeWithSelector(IVenture.HUB.selector), abi.encode(MOCK_HUB));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.ccaFactory.selector), abi.encode(AUCTION_FACTORY));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.migrationDelayBlocks.selector), abi.encode(uint64(50)));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.sweepDelayBlocks.selector), abi.encode(uint64(50)));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.spotSwapFeeBps.selector), abi.encode(uint16(30)));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.defaultPoolTickSpacing.selector), abi.encode(int24(60)));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.registerSpotLiquidityVault.selector), abi.encode());
    }

    function _deployUmiaHook() internal returns (UmiaHook hook) {
        (, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(UmiaHook).creationCode, abi.encode(address(this)));
        hook = new UmiaHook{salt: salt}(address(this));
        hook.initialize(address(this), IPoolManager(address(mockPoolManager)));
    }

    function deployLBP(uint256 ventureBps) internal returns (UmiaLBP) {
        bytes memory auctionParams = "";

        return new UmiaLBP(
            address(mockToken),
            TOTAL_SUPPLY,
            5_000_000,
            address(mockCurrency),
            auctionParams,
            IPoolManager(address(mockPoolManager)),
            IUmiaHook(address(umiaHook)),
            VENTURE,
            ventureBps,
            vaultCodePointer
        );
    }

    /// @notice Test insufficient currency reverts
    function test_Migrate_RevertsOn_InsufficientCurrency() public {
        UmiaLBP lbp = deployLBP(2000); // 20%

        MockLBPInitializer initializer =
            new MockLBPInitializer(100 ether, 100, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));

        // Mock factory to return our initializer
        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(bytes4(keccak256("create(address,uint256,bytes,bytes32)"))),
            abi.encode(address(initializer))
        );

        // Mint TOTAL_SUPPLY tokens to lbp and call onTokensReceived
        mockToken.mint(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        // Initializer reports 100 ETH raised but only has 10 ETH. After sweep, LBP has 10 ETH, needs 20 for venture.
        mockCurrency.mint(address(initializer), 10 ether);

        vm.roll(uint256(lbp.initializer().endBlock()) + lbp.hub().migrationDelayBlocks());
        vm.expectRevert(IUmiaLBP.InsufficientCurrency.selector);
        lbp.migrate();
    }

    /// @notice Test migration reverts before migrationBlock
    function test_Migrate_RevertsWhen_BeforeMigrationBlock() public {
        UmiaLBP lbp = deployLBP(2000); // 20%

        MockLBPInitializer initializer =
            new MockLBPInitializer(100 ether, 100, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(bytes4(keccak256("create(address,uint256,bytes,bytes32)"))),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        mockCurrency.mint(address(initializer), 100 ether);

        vm.roll(0); // Before the migration window (auction endBlock + hub migration delay)

        vm.expectRevert(IUmiaLBP.MigrationNotAllowed.selector);
        lbp.migrate();
    }

    /// @notice Test migration reverts when no currency raised
    function test_Migrate_RevertsWhen_NoCurrencyRaised() public {
        UmiaLBP lbp = deployLBP(2000); // 20%

        // Initializer reports 0 currency raised
        MockLBPInitializer initializer = new MockLBPInitializer(0, 100, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(bytes4(keccak256("create(address,uint256,bytes,bytes32)"))),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        vm.roll(uint256(lbp.initializer().endBlock()) + lbp.hub().migrationDelayBlocks());

        vm.expectRevert(IUmiaLBP.NoCurrencyRaised.selector);
        lbp.migrate();
    }

    /// @notice Test migrate reverts when currencyRaised exceeds uint128 max
    function test_Migrate_RevertsWhen_CurrencyAmountTooHigh() public {
        UmiaLBP lbp = deployLBP(2000);

        uint256 tooHighCurrency = uint256(type(uint128).max) + 1;
        MockLBPInitializer initializer =
            new MockLBPInitializer(tooHighCurrency, 100, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(bytes4(keccak256("create(address,uint256,bytes,bytes32)"))),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        mockCurrency.mint(address(initializer), 100 ether);

        vm.roll(uint256(lbp.initializer().endBlock()) + lbp.hub().migrationDelayBlocks());
        vm.expectRevert(IUmiaLBP.CurrencyAmountTooHigh.selector);
        lbp.migrate();
    }

    /// @notice Test migrate reverts on reentrancy via malicious initializer
    function test_Migrate_RevertsWhen_Reentrancy() public {
        UmiaLBP lbp = deployLBP(2000); // 20%

        uint256 oneToOnePrice = 79228162514264337593543950336;
        ReentrantInitializer initializer =
            new ReentrantInitializer(100 ether, oneToOnePrice, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));
        initializer.setTarget(address(lbp));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(bytes4(keccak256("create(address,uint256,bytes,bytes32)"))),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        mockCurrency.mint(address(initializer), 100 ether);

        vm.roll(uint256(lbp.initializer().endBlock()) + lbp.hub().migrationDelayBlocks());
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        lbp.migrate();
    }
}

contract ReentrantInitializer is MockLBPInitializer {
    address private _target;

    constructor(uint256 currencyRaised_, uint256 initialPriceX96_, address currency_, address token_)
        MockLBPInitializer(currencyRaised_, initialPriceX96_, currency_, token_)
    {}

    function setTarget(address target_) external {
        _target = target_;
    }

    function sweepCurrency() external override {
        UmiaLBP(payable(_target)).migrate();
    }
}
