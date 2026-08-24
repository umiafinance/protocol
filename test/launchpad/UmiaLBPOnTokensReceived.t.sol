// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IDistributor} from "@liquidity-launcher/interfaces/IDistributor.sol";
import {IDistributorFactory} from "@liquidity-launcher/interfaces/IDistributorFactory.sol";

import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {SpotLiquidityVault} from "../../src/core/SpotLiquidityVault.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {UmiaHook} from "../../src/periphery/UmiaHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLBPInitializer} from "../mocks/MockLBPInitializer.sol";
import {MockBadInitializer} from "../mocks/MockBadInitializer.sol";

contract UmiaLBPOnTokensReceivedTest is Test {
    address internal vaultCodePointer = SSTORE2.write(type(SpotLiquidityVault).creationCode);
    address constant VENTURE = address(0x1);
    address constant AUCTION_FACTORY = address(0x6);

    uint128 constant TOTAL_SUPPLY = 1_000_000e18;
    address constant MOCK_HUB = address(0x8);
    uint160 constant HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

    MockERC20 public mockCurrency;
    MockERC20 public mockToken;
    address public mockPoolManager;
    UmiaHook public umiaHook;

    function setUp() public {
        mockCurrency = new MockERC20("Mock Currency", "MCUR", 18);
        mockToken = new MockERC20("Mock Token", "MTOK", 18);
        mockPoolManager = address(0x5);
        umiaHook = _deployUmiaHook();

        vm.mockCall(VENTURE, abi.encodeWithSelector(IVenture.HUB.selector), abi.encode(MOCK_HUB));
        vm.mockCall(MOCK_HUB, abi.encodeWithSelector(IUmiaHub.ccaFactory.selector), abi.encode(AUCTION_FACTORY));
    }

    function _deployUmiaHook() internal returns (UmiaHook hook) {
        (, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(UmiaHook).creationCode, abi.encode(address(this)));
        hook = new UmiaHook{salt: salt}(address(this));
        hook.initialize(address(this), IPoolManager(mockPoolManager));
    }

    function deployLBP(uint256 ventureBps) internal returns (UmiaLBP) {
        bytes memory auctionParams = "";

        return new UmiaLBP(
            address(mockToken),
            TOTAL_SUPPLY,
            5_000_000,
            address(mockCurrency),
            auctionParams,
            IPoolManager(mockPoolManager),
            IUmiaHook(address(umiaHook)),
            VENTURE,
            ventureBps,
            vaultCodePointer
        );
    }

    function test_OnTokensReceived_SuccessfullyCreatesInitializer() public {
        UmiaLBP lbp = deployLBP(2000);

        MockLBPInitializer initializer = new MockLBPInitializer(0, 0, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);

        vm.expectEmit(true, true, true, true);
        emit IUmiaLBP.InitializerCreated(address(initializer));

        lbp.onTokensReceived();

        assertEq(address(lbp.initializer()), address(initializer), "Initializer should be set");
    }

    function test_OnTokensReceived_RevertsWhen_InsufficientTokens() public {
        UmiaLBP lbp = deployLBP(2000);

        mockToken.mint(address(lbp), TOTAL_SUPPLY - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IDistributor.InvalidAmountReceived.selector, TOTAL_SUPPLY, TOTAL_SUPPLY - 1)
        );
        lbp.onTokensReceived();
    }

    function test_OnTokensReceived_RevertsWhen_InitializerAlreadyCreated() public {
        UmiaLBP lbp = deployLBP(2000);

        MockLBPInitializer initializer = new MockLBPInitializer(0, 0, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);

        lbp.onTokensReceived();

        mockToken.mint(address(lbp), TOTAL_SUPPLY);

        vm.expectRevert(IUmiaLBP.InitializerAlreadyCreated.selector);
        lbp.onTokensReceived();
    }

    function test_OnTokensReceived_RevertsWhen_InitializerDoesNotSupportInterface() public {
        UmiaLBP lbp = deployLBP(2000);

        MockBadInitializer badInitializer = new MockBadInitializer();

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            abi.encode(address(badInitializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);

        vm.expectRevert(IUmiaLBP.InitializerMustImplementInterface.selector);
        lbp.onTokensReceived();
    }

    function test_OnTokensReceived_TransfersCorrectTokenAmountToInitializer() public {
        UmiaLBP lbp = deployLBP(2000);

        MockLBPInitializer initializer = new MockLBPInitializer(0, 0, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);

        uint256 expectedAuctionSupply = (TOTAL_SUPPLY * 5_000_000) / 10_000_000;

        lbp.onTokensReceived();

        assertEq(
            mockToken.balanceOf(address(initializer)),
            expectedAuctionSupply,
            "Initializer should receive auction supply"
        );
        assertEq(mockToken.balanceOf(address(lbp)), lbp.reserveTokenAmount(), "LBP should retain reserve amount");
    }

    function test_OnTokensReceived_RevertsWhen_InvalidFundsRecipient() public {
        UmiaLBP lbp = deployLBP(2000);

        MockLBPInitializer initializer = new MockLBPInitializer(0, 0, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(0x999));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);

        vm.expectRevert(IUmiaLBP.InvalidFundsRecipient.selector);
        lbp.onTokensReceived();
    }

    function test_OnTokensReceived_RevertsWhen_InvalidTokensRecipient() public {
        UmiaLBP lbp = deployLBP(2000);

        MockLBPInitializer initializer = new MockLBPInitializer(0, 0, address(mockCurrency), address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(0x999));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);

        vm.expectRevert(IUmiaLBP.InvalidTokensRecipient.selector);
        lbp.onTokensReceived();
    }

    function test_OnTokensReceived_RevertsWhen_InvalidCurrency() public {
        UmiaLBP lbp = deployLBP(2000);

        address wrongCurrency = address(0x888);
        MockLBPInitializer initializer = new MockLBPInitializer(0, 0, wrongCurrency, address(mockToken));
        initializer.setFundsRecipient(address(lbp));
        initializer.setTokensRecipient(address(lbp));

        vm.mockCall(
            AUCTION_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            abi.encode(address(initializer))
        );

        mockToken.mint(address(lbp), TOTAL_SUPPLY);

        vm.expectRevert(IUmiaLBP.InvalidCurrency.selector);
        lbp.onTokensReceived();
    }
}
