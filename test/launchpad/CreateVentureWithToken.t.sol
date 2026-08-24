// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {Venture} from "../../src/core/Venture.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";

contract CreateVentureWithTokenTest is DecisionMarketBase {
    uint256 internal constant DEFAULT_SUPPLY = 1_000_000e18;

    function setUp() public override {
        super.setUp();
    }

    function _deployExternalToken(string memory name, string memory symbol, uint256 supply)
        internal
        returns (VentureToken token)
    {
        token = new VentureToken(name, symbol, address(this));
        token.mint(address(hub), supply);
        token.transferOwnership(address(hub));
    }

    function _createVentureWithExternalToken(
        UmiaHub targetHub,
        address creator,
        VentureToken token,
        uint256 /* supply */
    )
        internal
        returns (uint256 id, address payable ventureAddr)
    {
        LBPBlockConfig memory blocks = _defaultBlockConfig();

        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = creator;

        vm.prank(targetHub.owner());
        (id, ventureAddr) = targetHub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_success() public {
        VentureToken token = _deployExternalToken("External Token", "EXT", DEFAULT_SUPPLY);

        (uint256 id, address payable ventureAddr) = _createVentureWithExternalToken(hub, alice, token, DEFAULT_SUPPLY);

        assertGt(id, 0);
        assertNotEq(ventureAddr, address(0));

        Venture createdVenture = Venture(ventureAddr);
        assertEq(createdVenture.token(), address(token));
        assertEq(createdVenture.moneyToken(), address(usdc));
        assertNotEq(createdVenture.lbp(), address(0));

        assertEq(token.owner(), ventureAddr);
        assertEq(token.balanceOf(address(hub)), 0);
    }

    function test_createVentureWithToken_ventureInfoUsesTokenName() public {
        VentureToken token = _deployExternalToken("Custom Name Token", "CNT", DEFAULT_SUPPLY);

        (uint256 id,) = _createVentureWithExternalToken(hub, alice, token, DEFAULT_SUPPLY);

        IUmiaHub.VentureInfo memory info = hub.ventureById(id);
        assertEq(info.name, "Custom Name Token");
    }

    function test_createVentureWithToken_emitsVentureCreated() public {
        VentureToken token = _deployExternalToken("Test", "TST", DEFAULT_SUPPLY);

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        uint256 hubNonce = vm.getNonce(address(hub));
        address predictedVenture = vm.computeCreateAddress(address(hub), hubNonce);

        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.expectEmit(true, true, false, false);
        emit IUmiaHub.VentureCreated(1, predictedVenture, block.timestamp);

        vm.prank(hub.owner());
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_reverts_tokenZeroAddress() public {
        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(hub.owner());
        vm.expectRevert(IUmiaHub.InvalidToken.selector);
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(0),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_reverts_notVentureToken() public {
        MockERC20 fakeToken = new MockERC20("Fake", "FAKE", 18);
        fakeToken.mint(address(hub), DEFAULT_SUPPLY);

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(hub.owner());
        vm.expectRevert(IUmiaHub.NotVentureToken.selector);
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(fakeToken),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_reverts_tokenNotOwnedByHub() public {
        VentureToken token = new VentureToken("Test", "TST", address(this));
        token.mint(address(hub), DEFAULT_SUPPLY);
        token.transferOwnership(alice);

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(hub.owner());
        vm.expectRevert(IUmiaHub.TokenOwnerNotHub.selector);
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_reverts_zeroBalance() public {
        VentureToken token = new VentureToken("Test", "TST", address(hub));

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(hub.owner());
        vm.expectRevert(IUmiaHub.TokenBalanceZero.selector);
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_reverts_supplyTooSmall() public {
        uint256 tooSmall = 99e18;
        VentureToken token = _deployExternalToken("Test", "TST", tooSmall);

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(hub.owner());
        vm.expectRevert(IUmiaHub.InvalidInitialSupply.selector);
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_reverts_supplyTooLarge() public {
        uint256 tooLarge = 1e12 * 1e18 + 1;
        VentureToken token = _deployExternalToken("Test", "TST", tooLarge);

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(hub.owner());
        vm.expectRevert(IUmiaHub.InvalidInitialSupply.selector);
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_reverts_notOwner() public {
        VentureToken token = _deployExternalToken("Test", "TST", DEFAULT_SUPPLY);

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(alice);
        vm.expectRevert();
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_reverts_moneyTokenNotApproved() public {
        VentureToken token = _deployExternalToken("Test", "TST", DEFAULT_SUPPLY);

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(hub.owner());
        vm.expectRevert(IUmiaHub.MoneyTokenNotApproved.selector);
        hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(0xdead),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function test_createVentureWithToken_existingCreateVentureStillWorks() public {
        (uint256 id, address payable ventureAddr) = _createVentureWithLBP(hub, alice);

        assertGt(id, 0);
        assertNotEq(ventureAddr, address(0));

        Venture createdVenture = Venture(ventureAddr);
        assertNotEq(createdVenture.token(), address(0));
    }

    function test_createVentureWithToken_fullLifecycleWithMigration() public {
        VentureToken token = _deployExternalToken("Lifecycle Token", "LCT", DEFAULT_SUPPLY);

        (, address payable ventureAddr) = _createVentureWithExternalToken(hub, alice, token, DEFAULT_SUPPLY);

        Venture createdVenture = Venture(ventureAddr);
        address lbpAddr = createdVenture.lbp();

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        _runAuctionAndMigrate(lbpAddr, blocks);

        // Migration is live when the venture's SpotLiquidityVault is registered (no LP NFT in the
        // vault model).
        assertTrue(hub.ventureLiquidityVault(address(createdVenture)) != address(0));
    }

    function test_createVentureWithToken_incrementsVentureCount() public {
        uint256 countBefore = hub.ventureCount();

        VentureToken token = _deployExternalToken("Test", "TST", DEFAULT_SUPPLY);
        _createVentureWithExternalToken(hub, alice, token, DEFAULT_SUPPLY);

        assertEq(hub.ventureCount(), countBefore + 1);
    }

    function test_createVentureWithToken_withTradingPause() public {
        VentureToken token = _deployExternalToken("Pause Token", "PT", DEFAULT_SUPPLY);

        LBPBlockConfig memory blocks = _defaultBlockConfig();
        bytes memory auctionParams = _buildAuctionParams(blocks);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;

        vm.prank(hub.owner());
        (, address payable ventureAddr) = hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: address(token),
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 7 days,
                startingMonthlyAllowance: 0
            })
        );

        Venture createdVenture = Venture(ventureAddr);
        assertEq(createdVenture.tradingPauseDuration(), 7 days);
    }
}
