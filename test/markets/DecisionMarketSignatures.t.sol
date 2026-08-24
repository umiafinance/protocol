// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {UmiaMarketStake} from "../../src/core/UmiaMarketStake.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {Venture} from "../../src/core/Venture.sol";
import {UmiaLBPFactory} from "../../src/launchpad/UmiaLBPFactory.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract LegacyGovernanceExecutor {
    function executeProposal(address, uint256, uint256, bytes calldata) external {}
}

/// @title DecisionMarketSignaturesTest
/// @notice Tests for permit-based trading and market creation signatures
contract DecisionMarketSignaturesTest is DecisionMarketBase {
    function test_swapExactInWithPermit() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        Market memory market = _marketById(marketId);
        uint256 proposalId = market.proposalIds[1];

        uint256 bobPrivateKey = 0xB0B;
        address bobAddr = vm.addr(bobPrivateKey);

        uint256 virtualMoneyId = mm.getVirtualMoneyId(proposalId);

        vm.prank(bob);
        mm.transfer(bobAddr, virtualMoneyId, 500e6);

        vm.prank(bobAddr);

        uint256 amountIn = 100e6;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = mm.swapNonces(bobAddr);

        IUmiaMarketCore.SwapExactInPermit memory permit = IUmiaMarketCore.SwapExactInPermit({
            proposalId: proposalId,
            amountIn: amountIn,
            amountOutMin: 0,
            maxPriceImpactBps: 5000,
            zeroForOne: false,
            nonce: nonce,
            deadline: deadline
        });

        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_IN_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountIn,
                permit.amountOutMin,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = mm.balanceOf(bobAddr, mm.getVirtualVentureId(proposalId));

        vm.prank(charlie);
        uint256 amountOut = mm.swapExactInWithPermit(permit, bobAddr, signature);

        assertGt(amountOut, 0, "Should receive output tokens");
        assertEq(
            mm.balanceOf(bobAddr, mm.getVirtualVentureId(proposalId)),
            balanceBefore + amountOut,
            "Bob should receive output tokens"
        );
        assertEq(mm.swapNonces(bobAddr), nonce + 1, "Nonce should increment");
    }

    function test_swapExactOutWithPermit() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        Market memory market = _marketById(marketId);
        uint256 proposalId = market.proposalIds[1];

        uint256 bobPrivateKey = 0xB0B;
        address bobAddr = vm.addr(bobPrivateKey);

        uint256 virtualMoneyId = mm.getVirtualMoneyId(proposalId);

        vm.prank(bob);
        mm.transfer(bobAddr, virtualMoneyId, 500e6);

        vm.prank(bobAddr);

        uint256 amountOut = 10e6;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = mm.swapNonces(bobAddr);

        IUmiaMarketCore.SwapExactOutPermit memory permit = IUmiaMarketCore.SwapExactOutPermit({
            proposalId: proposalId,
            amountOut: amountOut,
            amountInMax: type(uint256).max,
            maxPriceImpactBps: 10000,
            zeroForOne: false,
            nonce: nonce,
            deadline: deadline
        });

        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_OUT_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountOut,
                permit.amountInMax,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = mm.balanceOf(bobAddr, mm.getVirtualVentureId(proposalId));

        vm.prank(charlie);
        uint256 amountIn = mm.swapExactOutWithPermit(permit, bobAddr, signature);

        assertGt(amountIn, 0, "Should spend input tokens");
        assertEq(
            mm.balanceOf(bobAddr, mm.getVirtualVentureId(proposalId)),
            balanceBefore + amountOut,
            "Bob should receive exact output tokens"
        );
    }

    function test_permitExpired() public {
        _createVentureAndMarket();

        vm.warp(block.timestamp + 1 days + 1);

        uint256 bobPrivateKey = 0xB0B;
        address bobAddr = vm.addr(bobPrivateKey);

        uint256 deadline = block.timestamp - 1;

        IUmiaMarketCore.SwapExactInPermit memory permit = IUmiaMarketCore.SwapExactInPermit({
            proposalId: 1,
            amountIn: 100e6,
            amountOutMin: 0,
            maxPriceImpactBps: 5000,
            zeroForOne: false,
            nonce: 0,
            deadline: deadline
        });

        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_IN_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountIn,
                permit.amountOutMin,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IUmiaMarketCore.DeadlineExpired.selector);
        mm.swapExactInWithPermit(permit, bobAddr, signature);
    }

    function test_permitInvalidNonce() public {
        _createVentureAndMarket();

        vm.warp(block.timestamp + 1 days + 1);

        uint256 bobPrivateKey = 0xB0B;
        address bobAddr = vm.addr(bobPrivateKey);

        IUmiaMarketCore.SwapExactInPermit memory permit = IUmiaMarketCore.SwapExactInPermit({
            proposalId: 1,
            amountIn: 100e6,
            amountOutMin: 0,
            maxPriceImpactBps: 5000,
            zeroForOne: false,
            nonce: 999,
            deadline: block.timestamp + 1 hours
        });

        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_IN_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountIn,
                permit.amountOutMin,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        mm.swapExactInWithPermit(permit, bobAddr, signature);
    }

    function test_permitReplayAttack() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        Market memory market = _marketById(marketId);
        uint256 proposalId = market.proposalIds[1];

        uint256 bobPrivateKey = 0xB0B;
        address bobAddr = vm.addr(bobPrivateKey);

        uint256 virtualMoneyId = mm.getVirtualMoneyId(proposalId);

        vm.prank(bob);
        mm.transfer(bobAddr, virtualMoneyId, 500e6);

        vm.prank(bobAddr);

        IUmiaMarketCore.SwapExactInPermit memory permit = IUmiaMarketCore.SwapExactInPermit({
            proposalId: proposalId,
            amountIn: 10e6,
            amountOutMin: 0,
            maxPriceImpactBps: 5000,
            zeroForOne: false,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_IN_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountIn,
                permit.amountOutMin,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        mm.swapExactInWithPermit(permit, bobAddr, signature);

        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        mm.swapExactInWithPermit(permit, bobAddr, signature);
    }

    function test_invalidateNonce() public {
        _createVentureAndMarket();

        vm.warp(block.timestamp + 1 days + 1);

        uint256 bobPrivateKey = 0xB0B;
        address bobAddr = vm.addr(bobPrivateKey);

        assertEq(mm.swapNonces(bobAddr), 0);

        vm.prank(bobAddr);
        mm.invalidateSwapNonce();

        assertEq(mm.swapNonces(bobAddr), 1);

        IUmiaMarketCore.SwapExactInPermit memory permit = IUmiaMarketCore.SwapExactInPermit({
            proposalId: 1,
            amountIn: 100e6,
            amountOutMin: 0,
            maxPriceImpactBps: 5000,
            zeroForOne: false,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_IN_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountIn,
                permit.amountOutMin,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        mm.swapExactInWithPermit(permit, bobAddr, signature);
    }

    function test_invalidSignature() public {
        _createVentureAndMarket();

        vm.warp(block.timestamp + 1 days + 1);

        uint256 bobPrivateKey = 0xB0B;
        address bobAddr = vm.addr(bobPrivateKey);

        uint256 attackerPrivateKey = 0xBAD;

        IUmiaMarketCore.SwapExactInPermit memory permit = IUmiaMarketCore.SwapExactInPermit({
            proposalId: 1,
            amountIn: 100e6,
            amountOutMin: 0,
            maxPriceImpactBps: 5000,
            zeroForOne: false,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 structHash = keccak256(
            abi.encode(
                mm.SWAP_EXACT_IN_PERMIT_TYPEHASH(),
                permit.proposalId,
                permit.amountIn,
                permit.amountOutMin,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        mm.swapExactInWithPermit(permit, bobAddr, signature);
    }

    function _createVentureAndSetupMarketStake(UmiaHub targetHub, UmiaMarketCore)
        internal
        returns (uint256 _ventureId, address payable _venture, address _ventureToken)
    {
        (_ventureId, _venture) = _createVentureWithLBP(targetHub, alice);

        vm.prank(umiaAdmin);
        targetHub.setVentureMinMarketStake(_ventureId, MIN_MARKET_STAKE);

        _ventureToken = Venture(_venture).token();

        _mintVenture(targetHub, _venture, alice, MIN_MARKET_STAKE);

        address stakeContract = targetHub.umiaMarketStake();

        vm.startPrank(alice);
        IERC20(_ventureToken).approve(stakeContract, type(uint256).max);
        UmiaMarketStake(stakeContract).depositMarketStake(_ventureId);
        vm.stopPrank();

        _warmSpotOracle(_venture);
    }

    function test_marketCreation_validSignature() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "Proposal A", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.prank(alice);
        uint256 newMarketId = mm.createMarket(params, alice, nonce, signature);
        assertGt(newMarketId, 0, "Market should be created");

        assertEq(mm.marketCreationNonces(alice), nonce + 1, "Nonce should be incremented");
    }

    function test_marketCreation_invalidSignature_wrongSigner() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "Proposal A", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 attackerPrivateKey = 0xBAD;
        bytes32 proposalsHash = keccak256(abi.encode(params.proposals));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "CreateMarketApproval(address creator,uint256 ventureId,bytes32 titleHash,uint256 startTimestamp,uint256 duration,bytes32 proposalsHash,uint256 nonce)"
                ),
                alice,
                params.ventureId,
                keccak256(bytes(params.title)),
                params.startTimestamp,
                params.duration,
                proposalsHash,
                0
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPrivateKey, digest);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.prank(alice);
        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        mm.createMarket(params, alice, 0, invalidSignature);
    }

    function test_marketCreation_wrongCreator() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "Proposal A", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.prank(bob);
        vm.expectRevert(IUmiaMarketCore.Unauthorized.selector);
        mm.createMarket(params, alice, nonce, signature);
    }

    function test_marketCreation_replayProtection() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "Proposal A", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.startPrank(alice);
        mm.createMarket(params, alice, nonce, signature);

        assertEq(mm.marketCreationNonces(alice), nonce + 1, "Nonce should have been incremented");

        vm.expectRevert(IUmiaMarketCore.InvalidSignature.selector);
        mm.createMarket(params, alice, nonce, signature);

        vm.stopPrank();
    }

    function test_marketCreation_signerNotConfigured() public {
        vm.startPrank(umiaAdmin);
        UmiaHub freshHubImpl = new UmiaHub();
        UmiaHub freshHub =
            UmiaHub(address(new ERC1967Proxy(address(freshHubImpl), abi.encodeCall(UmiaHub.initialize, (umiaAdmin)))));
        UmiaMarketCore freshMmImpl = new UmiaMarketCore();
        UmiaMarketCore freshMm = UmiaMarketCore(
            address(
                new ERC1967Proxy(address(freshMmImpl), abi.encodeCall(UmiaMarketCore.initialize, (address(freshHub))))
            )
        );
        Venture freshVentureImpl = new Venture();
        UpgradeableBeacon freshBeacon = new UpgradeableBeacon(address(freshVentureImpl), umiaAdmin);
        freshHub.setVentureBeacon(address(freshBeacon));
        UmiaMarketStake freshMarketStake = new UmiaMarketStake(address(freshHub));
        freshHub.setUmiaMarketCore(address(freshMm));
        freshHub.setUmiaMarketStake(address(freshMarketStake));
        freshHub.setApprovedMoneyToken(address(usdc), true);
        freshHub.setDefaultGovernanceExecutor(address(new GovernanceExecutor(address(freshHub))));
        vm.stopPrank();
        UmiaLBPFactory freshLbpFactory =
            new UmiaLBPFactory(IPoolManager(address(manager)), address(umiaHook), address(freshHub));
        // Whitelist LBPs deployed by the fresh factory so the singleton UmiaHook accepts registerPool calls.
        vm.mockCall(address(lbpFactory), abi.encodeWithSelector(bytes4(keccak256("isLBP(address)"))), abi.encode(true));
        vm.startPrank(umiaAdmin);
        freshHub.setLbpStrategyFactory(address(freshLbpFactory));
        freshHub.setCcaFactory(address(ccaFactory));
        vm.stopPrank();

        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(freshHub, freshMm);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "Proposal A", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        bytes32 proposalsHash = keccak256(abi.encode(params.proposals));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "CreateMarketApproval(address creator,uint256 ventureId,bytes32 titleHash,uint256 startTimestamp,uint256 duration,bytes32 proposalsHash,uint256 nonce)"
                ),
                alice,
                params.ventureId,
                keccak256(bytes(params.title)),
                params.startTimestamp,
                params.duration,
                proposalsHash,
                0
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", freshMm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(alice);
        vm.expectRevert(IUmiaMarketCore.SignerNotConfigured.selector);
        freshMm.createMarket(params, alice, 0, signature);
    }

    function test_marketCreation_ownerCanCreateOnBehalfOfCreator() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "Proposal A", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.prank(umiaAdmin);
        uint256 newMarketId = mm.createMarket(params, alice, nonce, signature);
        assertGt(newMarketId, 0, "Owner should be able to create market on behalf of creator");

        assertEq(mm.marketCreationNonces(alice), nonce + 1, "Creator's nonce should be incremented");
    }

    function test_marketCreation_allowsValidGovernancePayload() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: alice, amount: 1e18}))
        });

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({
            title: "Proposal A",
            executionPayload: abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}))
        });
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.prank(alice);
        uint256 newMarketId = mm.createMarket(params, alice, nonce, signature);

        assertGt(newMarketId, 0, "market creation should succeed with a valid governance payload");
    }

    function test_marketCreation_revertsOnUnsupportedGovernancePayload() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.UPDATE_PARAMS, actionVersion: 1, data: bytes("")
        });

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({
            title: "Proposal A",
            executionPayload: abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}))
        });
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.prank(alice);
        vm.expectRevert();
        mm.createMarket(params, alice, nonce, signature);
    }

    function test_marketCreation_revertsWhenExecutorNotSetForGovernancePayload() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: alice, amount: 1e18}))
        });

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({
            title: "Proposal A",
            executionPayload: abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}))
        });
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        vm.prank(umiaAdmin);
        hub.setDefaultGovernanceExecutor(address(0));

        vm.prank(alice);
        vm.expectRevert(IUmiaMarketCore.GovernanceExecutorNotSet.selector);
        mm.createMarket(params, alice, nonce, signature);
    }

    function test_marketCreation_revertsWhenExecutorLacksValidatePayload() public {
        (uint256 _ventureId,,) = _createVentureAndSetupMarketStake(hub, mm);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: alice, amount: 1e18}))
        });

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({
            title: "Proposal A",
            executionPayload: abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}))
        });
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Proposal B", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "Test Market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        LegacyGovernanceExecutor legacyExecutor = new LegacyGovernanceExecutor();

        vm.prank(umiaAdmin);
        hub.setDefaultGovernanceExecutor(address(legacyExecutor));

        vm.prank(alice);
        vm.expectRevert();
        mm.createMarket(params, alice, nonce, signature);
    }
}
