// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {VentureVestingAuthority, ICCAClearingPrice} from "../../src/periphery/VentureVestingAuthority.sol";
import {IVentureVestingAuthority} from "../../src/interfaces/IVentureVestingAuthority.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";

/// @notice Unit tests for the adapter logic with a mocked Hub / controller / treasury (no pool, no
///         real MetaVesT). The genesis handoff and futarchy-driven grants are exercised for real in
///         the MetaVesT lifecycle integration test.
contract VentureVestingAuthorityTest is Test {
    VentureVestingAuthority adapter;

    address constant HUB = address(0xB0);
    address constant CONTROLLER = address(0xC0);
    address constant TREASURY = address(0xA1);
    address constant TOKEN = address(0x71);
    address constant LBP = address(0x1B9);
    address constant CCA = address(0xCCA1);
    address constant ALLOCATION = address(0xABCD);
    address constant GRANTEE = address(0xBEEF);
    address constant STRANGER = address(0xE1);
    uint256 constant VENTURE_ID = 7;

    bytes4 private constant CREATE_METAVEST_SELECTOR = bytes4(
        keccak256(
            "createMetavest(uint8,address,(uint256,uint128,uint128,uint160,uint48,uint160,uint48,address),(uint256,bool,bool,address[])[],uint256,address,uint256,uint256)"
        )
    );

    function setUp() public {
        adapter = new VentureVestingAuthority(HUB, CONTROLLER);
    }

    function _mockBindDeps() internal {
        IUmiaHub.VentureInfo memory info =
            IUmiaHub.VentureInfo({id: VENTURE_ID, venture: TREASURY, name: "", createdAt: 0});
        vm.mockCall(HUB, abi.encodeWithSelector(IUmiaHub.ventureById.selector, VENTURE_ID), abi.encode(info));
        vm.mockCall(TREASURY, abi.encodeWithSelector(IVenture.token.selector), abi.encode(TOKEN));
        vm.mockCall(
            TOKEN, abi.encodeWithSelector(IERC20.approve.selector, CONTROLLER, type(uint256).max), abi.encode(true)
        );
    }

    function _mockAllocationView() internal {
        vm.mockCall(ALLOCATION, abi.encodeWithSignature("getVestingType()"), abi.encode(uint256(1)));
        vm.mockCall(ALLOCATION, abi.encodeWithSignature("grantee()"), abi.encode(GRANTEE));
        vm.mockCall(ALLOCATION, abi.encodeWithSignature("milestoneAwardTotal()"), abi.encode(uint256(50)));
        vm.mockCall(
            ALLOCATION,
            abi.encodeWithSignature("getMetavestDetails()"),
            abi.encode(uint256(100), uint128(0), uint128(0), uint160(0), uint48(0), uint160(0), uint48(0), TOKEN)
        );
    }

    /// @dev The condition resolves a relative ladder's anchor as `venture.lbp().initializer()`; mock
    ///      that chain (post-bind, treasury == TREASURY) so it returns CCA.
    function _mockVentureAuction() internal {
        vm.mockCall(TREASURY, abi.encodeWithSelector(IVenture.lbp.selector), abi.encode(LBP));
        vm.mockCall(LBP, abi.encodeWithSignature("initializer()"), abi.encode(CCA));
    }

    function _mockClearingPrice(uint256 price) internal {
        vm.mockCall(CCA, abi.encodeWithSelector(ICCAClearingPrice.clearingPrice.selector), abi.encode(price));
    }

    function _createMetavestCalldata() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CREATE_METAVEST_SELECTOR);
    }

    function _noProgram() internal pure returns (IVentureVestingAuthority.PriceProgramInput memory) {
        return IVentureVestingAuthority.PriceProgramInput({
            kind: IVentureVestingAuthority.PriceProgramKind.None,
            absoluteThresholds: new uint160[](0),
            multiplesX1e6: new uint256[](0),
            cliffs: new uint48[](0)
        });
    }

    function _absoluteProgram(uint160 a, uint160 b)
        internal
        pure
        returns (IVentureVestingAuthority.PriceProgramInput memory)
    {
        uint160[] memory t = new uint160[](2);
        t[0] = a;
        t[1] = b;
        return IVentureVestingAuthority.PriceProgramInput({
            kind: IVentureVestingAuthority.PriceProgramKind.Absolute,
            absoluteThresholds: t,
            multiplesX1e6: new uint256[](0),
            cliffs: new uint48[](0)
        });
    }

    function _relativeProgram(uint256 a, uint256 b)
        internal
        pure
        returns (IVentureVestingAuthority.PriceProgramInput memory)
    {
        uint256[] memory m = new uint256[](2);
        m[0] = a;
        m[1] = b;
        return IVentureVestingAuthority.PriceProgramInput({
            kind: IVentureVestingAuthority.PriceProgramKind.Relative,
            absoluteThresholds: new uint160[](0),
            multiplesX1e6: m,
            cliffs: new uint48[](0)
        });
    }

    function _withCliffs(IVentureVestingAuthority.PriceProgramInput memory program, uint48 a, uint48 b)
        internal
        pure
        returns (IVentureVestingAuthority.PriceProgramInput memory)
    {
        uint48[] memory c = new uint48[](2);
        c[0] = a;
        c[1] = b;
        program.cliffs = c;
        return program;
    }

    /// @dev Fund a genesis grant for ALLOCATION with the given price program (mocks the token + view).
    function _fundGenesis(IVentureVestingAuthority.PriceProgramInput memory program) internal {
        bytes memory data = _createMetavestCalldata();
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(adapter), 1),
            abi.encode(true)
        );
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector, address(adapter)), abi.encode(uint256(0)));
        _mockAllocationView();
        adapter.fundGenesisGrant(TOKEN, 1, data, program);
    }

    // ── constructor ──

    function test_Revert_ConstructorZeroHub() public {
        vm.expectRevert(IVentureVestingAuthority.ZeroAddress.selector);
        new VentureVestingAuthority(address(0), CONTROLLER);
    }

    function test_Revert_ConstructorZeroController() public {
        vm.expectRevert(IVentureVestingAuthority.ZeroAddress.selector);
        new VentureVestingAuthority(HUB, address(0));
    }

    function test_Constructor_SetsImmutables() public view {
        assertEq(adapter.deployer(), address(this));
        assertEq(adapter.hub(), HUB);
        assertEq(adapter.controller(), CONTROLLER);
        assertEq(adapter.treasury(), address(0));
        assertFalse(adapter.bound());
        assertFalse(adapter.genesisClosed());
    }

    // ── claim ──

    function test_Claim_CallsAcceptAuthorityRole() public {
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("acceptAuthorityRole()"), "");
        vm.expectCall(CONTROLLER, abi.encodeWithSignature("acceptAuthorityRole()"));
        adapter.claim();
    }

    // ── bind ──

    function test_Revert_BindNotDeployer() public {
        _mockBindDeps();
        vm.prank(STRANGER);
        vm.expectRevert(IVentureVestingAuthority.NotDeployer.selector);
        adapter.bind(VENTURE_ID);
    }

    function test_Bind_ResolvesTreasuryFromHubAndApproves() public {
        _mockBindDeps();
        vm.expectCall(TOKEN, abi.encodeWithSelector(IERC20.approve.selector, CONTROLLER, type(uint256).max));
        adapter.bind(VENTURE_ID);
        assertEq(adapter.treasury(), TREASURY);
        assertTrue(adapter.bound());
    }

    function test_Bind_EmitsBound() public {
        _mockBindDeps();
        vm.expectEmit(true, true, true, true);
        emit IVentureVestingAuthority.Bound(VENTURE_ID, TREASURY, TOKEN);
        adapter.bind(VENTURE_ID);
    }

    function test_Revert_BindVentureNotFound() public {
        IUmiaHub.VentureInfo memory info = IUmiaHub.VentureInfo({id: 0, venture: address(0), name: "", createdAt: 0});
        vm.mockCall(HUB, abi.encodeWithSelector(IUmiaHub.ventureById.selector, VENTURE_ID), abi.encode(info));
        vm.expectRevert(IVentureVestingAuthority.VentureNotFound.selector);
        adapter.bind(VENTURE_ID);
    }

    function test_Revert_BindTwice() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        vm.expectRevert(IVentureVestingAuthority.AlreadyBound.selector);
        adapter.bind(VENTURE_ID);
    }

    function test_Cca_ResolvedFromBoundVenture() public {
        assertEq(adapter.cca(), address(0), "unbound: no auction");
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        _mockVentureAuction();
        assertEq(adapter.cca(), CCA);
    }

    // ── closeGenesis ──

    function test_CloseGenesis_SetsFlag() public {
        adapter.closeGenesis();
        assertTrue(adapter.genesisClosed());
    }

    function test_Revert_CloseGenesisNotDeployer() public {
        vm.prank(STRANGER);
        vm.expectRevert(IVentureVestingAuthority.NotDeployer.selector);
        adapter.closeGenesis();
    }

    function test_CloseGenesis_EmitsGenesisSealed() public {
        vm.expectEmit();
        emit IVentureVestingAuthority.GenesisSealed();
        adapter.closeGenesis();
    }

    function test_Revert_CloseGenesisTwice() public {
        adapter.closeGenesis();
        vm.expectRevert(IVentureVestingAuthority.GenesisClosed.selector);
        adapter.closeGenesis();
    }

    // ── fundGenesisGrant ──

    function test_FundGenesisGrant_RoutesToControllerAndEmits() public {
        bytes memory data = _createMetavestCalldata();
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(adapter), 1),
            abi.encode(true)
        );
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector, address(adapter)), abi.encode(uint256(0)));
        _mockAllocationView();

        vm.expectEmit(true, true, true, true);
        emit IVentureVestingAuthority.AllocationFunded(CONTROLLER, ALLOCATION, GRANTEE, TOKEN, 1, 100, 50);

        address allocation = adapter.fundGenesisGrant(TOKEN, 1, data, _noProgram());
        assertEq(allocation, ALLOCATION);
        assertTrue(adapter.priceProgramKind(ALLOCATION) == IVentureVestingAuthority.PriceProgramKind.None);
    }

    function test_FundGenesisGrant_RefundsOverfundedRemainder() public {
        bytes memory data = _createMetavestCalldata();
        // Operator over-funds: pulls 10, but the controller leaves 3 behind in the adapter.
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(adapter), 10),
            abi.encode(true)
        );
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector, address(adapter)), abi.encode(uint256(3)));
        vm.mockCall(
            TOKEN, abi.encodeWithSelector(IERC20.transfer.selector, address(this), uint256(3)), abi.encode(true)
        );
        _mockAllocationView();

        vm.expectCall(TOKEN, abi.encodeWithSelector(IERC20.transfer.selector, address(this), uint256(3)));
        adapter.fundGenesisGrant(TOKEN, 10, data, _noProgram());
    }

    function test_Revert_FundGenesisGrantNotDeployer() public {
        vm.prank(STRANGER);
        vm.expectRevert(IVentureVestingAuthority.NotDeployer.selector);
        adapter.fundGenesisGrant(TOKEN, 1, _createMetavestCalldata(), _noProgram());
    }

    function test_Revert_FundGenesisGrantAfterBind() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        vm.expectRevert(IVentureVestingAuthority.AlreadyBound.selector);
        adapter.fundGenesisGrant(TOKEN, 1, _createMetavestCalldata(), _noProgram());
    }

    function test_Revert_FundGenesisGrantAfterClose() public {
        adapter.closeGenesis();
        vm.expectRevert(IVentureVestingAuthority.GenesisClosed.selector);
        adapter.fundGenesisGrant(TOKEN, 1, _createMetavestCalldata(), _noProgram());
    }

    function test_Revert_FundGenesisGrantWrongSelector() public {
        vm.expectRevert(IVentureVestingAuthority.NotCreateMetavest.selector);
        adapter.fundGenesisGrant(TOKEN, 1, abi.encodeWithSignature("terminate()"), _noProgram());
    }

    function test_Revert_FundGenesisGrantZeroAllocation() public {
        bytes memory data = _createMetavestCalldata();
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(adapter), 1),
            abi.encode(true)
        );
        vm.mockCall(CONTROLLER, data, abi.encode(address(0)));
        vm.expectRevert(IVentureVestingAuthority.InvalidControllerReturn.selector);
        adapter.fundGenesisGrant(TOKEN, 1, data, _noProgram());
    }

    // ── forward (only the bound treasury; i.e. only futarchy) ──

    function test_Revert_ForwardBeforeBind() public {
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.NotTreasury.selector);
        adapter.forward(_createMetavestCalldata(), _noProgram());
    }

    function test_Revert_ForwardNotTreasury() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        vm.prank(STRANGER);
        vm.expectRevert(IVentureVestingAuthority.NotTreasury.selector);
        adapter.forward(_createMetavestCalldata(), _noProgram());
    }

    function test_Forward_RoutesToControllerAsTreasury() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = _createMetavestCalldata();
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        vm.expectCall(CONTROLLER, data);
        _mockAllocationView();

        vm.prank(TREASURY);
        bytes memory ret = adapter.forward(data, _noProgram());
        assertEq(abi.decode(ret, (address)), ALLOCATION);
    }

    function test_Forward_EmitsAllocationFundedOnCreateMetavest() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = _createMetavestCalldata();
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        _mockAllocationView();

        vm.expectEmit(true, true, true, true);
        emit IVentureVestingAuthority.AllocationFunded(CONTROLLER, ALLOCATION, GRANTEE, TOKEN, 1, 100, 50);

        vm.prank(TREASURY);
        adapter.forward(data, _noProgram());
    }

    function test_Forward_RegistersProgram() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = _createMetavestCalldata();
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        _mockAllocationView();

        vm.prank(TREASURY);
        adapter.forward(data, _relativeProgram(2e6, 3e6));
        assertTrue(adapter.priceProgramKind(ALLOCATION) == IVentureVestingAuthority.PriceProgramKind.Relative);

        _mockVentureAuction();
        _mockClearingPrice(1000);
        assertEq(adapter.effectiveThreshold(ALLOCATION, 0), 2000);
    }

    function test_Forward_BubblesControllerRevert() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = _createMetavestCalldata();
        vm.mockCallRevert(CONTROLLER, data, abi.encodeWithSignature("Boom()"));

        vm.prank(TREASURY);
        vm.expectRevert(abi.encodeWithSignature("Boom()"));
        adapter.forward(data, _noProgram());
    }

    function test_Revert_ForwardCreateMetavestShortReturn() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = _createMetavestCalldata();
        vm.mockCall(CONTROLLER, data, hex"1234");

        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.InvalidControllerReturn.selector);
        adapter.forward(data, _noProgram());
    }

    function test_Revert_ForwardCreateMetavestZeroAllocation() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = _createMetavestCalldata();
        vm.mockCall(CONTROLLER, data, abi.encode(address(0)));

        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.InvalidControllerReturn.selector);
        adapter.forward(data, _noProgram());
    }

    function test_Forward_NonCreateMetavestEmitsNoAllocationFunded() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = abi.encodeWithSignature("updateMetavestUnlockRate(address,uint160)", ALLOCATION, uint160(3));
        vm.mockCall(CONTROLLER, data, abi.encode(uint256(7)));

        vm.recordLogs();
        vm.prank(TREASURY);
        bytes memory ret = adapter.forward(data, _noProgram());

        assertEq(abi.decode(ret, (uint256)), 7, "controller return bubbles back");
        bytes32 fundedTopic = keccak256("AllocationFunded(address,address,address,address,uint8,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0) {
                assertTrue(entries[i].topics[0] != fundedTopic, "no AllocationFunded for non-createMetavest");
            }
        }
    }

    function test_Revert_ForwardInitiateAuthorityUpdate() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = abi.encodeWithSignature("initiateAuthorityUpdate(address)", STRANGER);
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.AuthorityTransferForbidden.selector);
        adapter.forward(data, _noProgram());
    }

    function test_Forward_AmendStillWorks() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);

        bytes memory data = abi.encodeWithSignature("updateMetavestUnlockRate(address,uint160)", ALLOCATION, uint160(5));
        vm.mockCall(CONTROLLER, data, abi.encode(uint256(1)));
        vm.expectCall(CONTROLLER, data);

        vm.prank(TREASURY);
        bytes memory ret = adapter.forward(data, _noProgram());
        assertEq(abi.decode(ret, (uint256)), 1);
    }

    function test_Revert_ForwardProgramOnNonCreate() public {
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        bytes memory data = abi.encodeWithSignature("updateMetavestUnlockRate(address,uint160)", ALLOCATION, uint160(3));
        vm.prank(TREASURY);
        vm.expectRevert(IVentureVestingAuthority.InvalidPriceProgram.selector);
        adapter.forward(data, _absoluteProgram(100, 200));
    }

    // ── price program registry (written atomically with the grant) ──

    function test_RegisterAbsolute_StoredAndReadable() public {
        _fundGenesis(_absoluteProgram(100, 200));
        assertTrue(adapter.priceProgramKind(ALLOCATION) == IVentureVestingAuthority.PriceProgramKind.Absolute);
        assertEq(adapter.programLength(ALLOCATION), 2);
        assertEq(adapter.absoluteThresholdAt(ALLOCATION, 0), 100);
        assertEq(adapter.absoluteThresholdAt(ALLOCATION, 1), 200);
        // Absolute thresholds need no venture/auction resolution.
        assertEq(adapter.effectiveThreshold(ALLOCATION, 0), 100);
        assertEq(adapter.effectiveThreshold(ALLOCATION, 1), 200);
    }

    function test_RegisterAbsolute_EmitsEvent() public {
        bytes memory data = _createMetavestCalldata();
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(adapter), 1),
            abi.encode(true)
        );
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector, address(adapter)), abi.encode(uint256(0)));
        _mockAllocationView();

        vm.expectEmit(true, true, false, true);
        emit IVentureVestingAuthority.PriceProgramRegistered(ALLOCATION, TOKEN, 1, 2, new uint48[](0));
        adapter.fundGenesisGrant(TOKEN, 1, data, _absoluteProgram(100, 200));
    }

    function test_RegisterRelative_StoredAndReadable() public {
        _fundGenesis(_relativeProgram(2e6, 3e6));
        assertTrue(adapter.priceProgramKind(ALLOCATION) == IVentureVestingAuthority.PriceProgramKind.Relative);
        assertEq(adapter.programLength(ALLOCATION), 2);
        assertEq(adapter.multipleAt(ALLOCATION, 0), 2e6);
        assertEq(adapter.multipleAt(ALLOCATION, 1), 3e6);
    }

    function test_RegisterRelative_EmitsEvent() public {
        bytes memory data = _createMetavestCalldata();
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(adapter), 1),
            abi.encode(true)
        );
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector, address(adapter)), abi.encode(uint256(0)));
        _mockAllocationView();

        vm.expectEmit(true, true, false, true);
        emit IVentureVestingAuthority.PriceProgramRegistered(ALLOCATION, TOKEN, 2, 2, new uint48[](0));
        adapter.fundGenesisGrant(TOKEN, 1, data, _relativeProgram(2e6, 3e6));
    }

    /// @dev Genesis funds the relative grant pre-bind; the auction anchor only resolves once bound.
    function _fundRelativeThenBind() internal {
        _fundGenesis(_relativeProgram(2e6, 3e6));
        _mockBindDeps();
        adapter.bind(VENTURE_ID);
        _mockVentureAuction();
    }

    function test_EffectiveThreshold_RelativeComputesLive() public {
        _fundRelativeThenBind();
        _mockClearingPrice(1000);
        assertEq(adapter.effectiveThreshold(ALLOCATION, 0), 2000); // 2x * 1000
        assertEq(adapter.effectiveThreshold(ALLOCATION, 1), 3000); // 3x * 1000
    }

    function test_EffectiveThreshold_RelativeTracksClearingPrice() public {
        _fundRelativeThenBind();
        _mockClearingPrice(1500);
        assertEq(adapter.effectiveThreshold(ALLOCATION, 0), 3000); // 2x * 1500
    }

    function test_Revert_EffectiveThreshold_AuctionNotCleared() public {
        _fundRelativeThenBind();
        _mockClearingPrice(0);
        vm.expectRevert(IVentureVestingAuthority.AuctionNotCleared.selector);
        adapter.effectiveThreshold(ALLOCATION, 0);
    }

    function test_Revert_EffectiveThreshold_NotBound() public {
        _fundGenesis(_relativeProgram(2e6, 3e6)); // never bound: no venture to resolve the auction from
        vm.expectRevert(IVentureVestingAuthority.NotBound.selector);
        adapter.effectiveThreshold(ALLOCATION, 0);
    }

    function test_Revert_EffectiveThreshold_Unregistered() public {
        vm.expectRevert(IVentureVestingAuthority.NotRegistered.selector);
        adapter.effectiveThreshold(ALLOCATION, 0);
    }

    function test_Revert_EffectiveThreshold_OutOfRange() public {
        _fundGenesis(_absoluteProgram(100, 200));
        vm.expectRevert(IVentureVestingAuthority.NotRegistered.selector);
        adapter.effectiveThreshold(ALLOCATION, 2);
    }

    function test_Revert_RegisterTwice() public {
        _fundGenesis(_absoluteProgram(100, 200));
        bytes memory data = _createMetavestCalldata();
        vm.expectRevert(IVentureVestingAuthority.ProgramAlreadyRegistered.selector);
        adapter.fundGenesisGrant(TOKEN, 1, data, _relativeProgram(2e6, 3e6));
    }

    function test_Revert_RegisterEmpty() public {
        IVentureVestingAuthority.PriceProgramInput memory p = IVentureVestingAuthority.PriceProgramInput({
            kind: IVentureVestingAuthority.PriceProgramKind.Absolute,
            absoluteThresholds: new uint160[](0),
            multiplesX1e6: new uint256[](0),
            cliffs: new uint48[](0)
        });
        bytes memory data = _createMetavestCalldata();
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(adapter), 1),
            abi.encode(true)
        );
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector, address(adapter)), abi.encode(uint256(0)));
        _mockAllocationView();
        vm.expectRevert(IVentureVestingAuthority.EmptyThresholds.selector);
        adapter.fundGenesisGrant(TOKEN, 1, data, p);
    }

    function test_Revert_RegisterZeroThreshold() public {
        vm.expectRevert(IVentureVestingAuthority.ZeroThreshold.selector);
        _fundGenesis(_absoluteProgram(0, 200));
    }

    function test_Revert_RegisterNonAscending() public {
        vm.expectRevert(IVentureVestingAuthority.ThresholdsNotAscending.selector);
        _fundGenesis(_absoluteProgram(200, 100));
    }

    // ── milestone cliffs (optional per-milestone time gate) ──

    function test_RegisterCliffs_StoredAndReadable() public {
        _fundGenesis(_withCliffs(_absoluteProgram(100, 200), 1000, 2000));
        assertEq(adapter.effectiveCliff(ALLOCATION, 0), 1000);
        assertEq(adapter.effectiveCliff(ALLOCATION, 1), 2000);
    }

    function test_RegisterCliffs_ZeroEntryMeansPriceOnly() public {
        _fundGenesis(_withCliffs(_absoluteProgram(100, 200), 0, 2000));
        assertEq(adapter.effectiveCliff(ALLOCATION, 0), 0);
        assertEq(adapter.effectiveCliff(ALLOCATION, 1), 2000);
    }

    function test_EffectiveCliff_ZeroWhenNoCliffsRegistered() public {
        _fundGenesis(_absoluteProgram(100, 200));
        assertEq(adapter.effectiveCliff(ALLOCATION, 0), 0);
        assertEq(adapter.effectiveCliff(ALLOCATION, 1), 0);
    }

    /// @dev Cliffs are stored verbatim, so a relative program's cliff resolves pre-bind even though
    ///      its threshold cannot (no venture to resolve the auction from yet).
    function test_EffectiveCliff_RelativeNeedsNoAuction() public {
        _fundGenesis(_withCliffs(_relativeProgram(2e6, 3e6), 1000, 2000));
        assertEq(adapter.effectiveCliff(ALLOCATION, 0), 1000);
        vm.expectRevert(IVentureVestingAuthority.NotBound.selector);
        adapter.effectiveThreshold(ALLOCATION, 0);
    }

    function test_RegisterCliffs_EmitsEvent() public {
        bytes memory data = _createMetavestCalldata();
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), address(adapter), 1),
            abi.encode(true)
        );
        vm.mockCall(CONTROLLER, data, abi.encode(ALLOCATION));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector, address(adapter)), abi.encode(uint256(0)));
        _mockAllocationView();

        uint48[] memory cliffs = new uint48[](2);
        cliffs[0] = 1000;
        cliffs[1] = 2000;
        vm.expectEmit(true, true, false, true);
        emit IVentureVestingAuthority.PriceProgramRegistered(ALLOCATION, TOKEN, 1, 2, cliffs);
        adapter.fundGenesisGrant(TOKEN, 1, data, _withCliffs(_absoluteProgram(100, 200), 1000, 2000));
    }

    function test_Revert_RegisterCliffsLengthMismatch() public {
        IVentureVestingAuthority.PriceProgramInput memory p = _absoluteProgram(100, 200);
        p.cliffs = new uint48[](1);
        p.cliffs[0] = 1000;
        vm.expectRevert(IVentureVestingAuthority.CliffsLengthMismatch.selector);
        _fundGenesis(p);
    }

    function test_Revert_EffectiveCliff_Unregistered() public {
        vm.expectRevert(IVentureVestingAuthority.NotRegistered.selector);
        adapter.effectiveCliff(ALLOCATION, 0);
    }

    function test_Revert_EffectiveCliff_OutOfRange() public {
        _fundGenesis(_withCliffs(_absoluteProgram(100, 200), 1000, 2000));
        vm.expectRevert(IVentureVestingAuthority.NotRegistered.selector);
        adapter.effectiveCliff(ALLOCATION, 2);
    }

    /// @dev A `None` program must be empty: arrays alongside `kind == None` are a mis-built input
    ///      and fail fast rather than silently registering nothing.
    function test_Revert_RegisterNoneWithCliffs() public {
        IVentureVestingAuthority.PriceProgramInput memory p = _noProgram();
        p.cliffs = new uint48[](1);
        p.cliffs[0] = 1000;
        vm.expectRevert(IVentureVestingAuthority.InvalidPriceProgram.selector);
        _fundGenesis(p);
    }

    function test_Revert_RegisterNoneWithThresholds() public {
        IVentureVestingAuthority.PriceProgramInput memory p = _noProgram();
        p.absoluteThresholds = new uint160[](1);
        p.absoluteThresholds[0] = 100;
        vm.expectRevert(IVentureVestingAuthority.InvalidPriceProgram.selector);
        _fundGenesis(p);
    }
}
