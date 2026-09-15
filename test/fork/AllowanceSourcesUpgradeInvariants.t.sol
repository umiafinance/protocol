// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {ProtocolState} from "../../script/ProtocolState.sol";
import {UpgradeBase} from "../../script/UpgradeBase.s.sol";
import {UpgradeVentureBeacon} from "../../script/UpgradeVentureBeacon.s.sol";
import {SwapGovernanceExecutor} from "../../script/SwapGovernanceExecutor.s.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IGovernanceExecutor} from "../../src/interfaces/IGovernanceExecutor.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CalendarLib} from "../../src/libraries/CalendarLib.sol";

/// @title AllowanceSourcesUpgradeInvariants
/// @notice Drives the real upgrade scripts (venture beacon, then executor swap) against a fork of
///         a live deployment and checks what must hold for every venture before, between and
///         after the two owner transactions, plus the rollback. Skipped unless FORK_RPC_URL is set;
///         UMIA_ENV / UMIA_CHAIN default to mainnet / base.
contract AllowanceSourcesUpgradeInvariantsForkTest is Test {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant FIRST_GAP_SLOT = 13;
    uint256 internal constant LAST_GAP_SLOT = 61;
    uint256 internal constant SOURCES_SLOT = 12;

    struct VentureView {
        address token;
        address moneyToken;
        address hub;
        address lbp;
        uint256 minMarketStake;
        uint256 documentCount;
        uint256 tradingPauseDuration;
        uint256 tradingPauseDeadline;
        bool liquidationActive;
        address authorizedLiquidator;
        uint256 allowanceAmount;
        uint256 allowanceSpent;
        uint256 allowanceMonth;
        bytes32[12] slots;
    }

    IUmiaHub internal hub;
    UpgradeableBeacon internal beacon;
    address internal liveExecutor;
    address internal liveImpl;
    address internal marketCore;
    address[] internal ventures;
    uint256 internal proposalId;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        hub = ProtocolState.hubFromContractsJson(
            vm.envOr("UMIA_ENV", string("mainnet")), vm.envOr("UMIA_CHAIN", string("base"))
        );
        beacon = UpgradeableBeacon(hub.ventureBeacon());
        liveExecutor = hub.defaultGovernanceExecutor();
        liveImpl = beacon.implementation();
        marketCore = hub.umiaMarketCore();
        for (uint256 id = 1;; id++) {
            IUmiaHub.VentureInfo memory info = hub.ventureById(id);
            if (info.venture == address(0)) break;
            ventures.push(info.venture);
        }
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    /// @dev Tests that need at least one live venture skip on a fresh chain when the empty
    ///      registry is explicitly allowed, and still fail closed otherwise.
    modifier needsVentures() {
        vm.skip(ventures.length == 0 && vm.envOr("ALLOW_EMPTY_REGISTRY", false));
        _;
    }

    // ─────────────────────────────────────────────────────────
    // Preconditions on the live deployment
    // ─────────────────────────────────────────────────────────

    function test_fork_everyVentureFollowsTheBeacon() public onFork {
        assertTrue(ventures.length > 0 || vm.envOr("ALLOW_EMPTY_REGISTRY", false), "hub registry is empty");
        for (uint256 i = 0; i < ventures.length; i++) {
            assertEq(ProtocolState.implementationOf(ventures[i]), address(0), "venture opted out of the beacon");
            assertEq(IVenture(ventures[i]).HUB(), address(hub));
        }
    }

    function test_fork_noVentureHasAnExecutorOverride() public onFork {
        for (uint256 i = 0; i < ventures.length; i++) {
            assertEq(hub.governanceExecutorByVenture(ventures[i]), address(0), "per-venture executor override");
            assertEq(hub.governanceExecutor(ventures[i]), liveExecutor);
        }
    }

    function test_fork_appendedSlotsAreUntouchedOnEveryVenture() public onFork {
        for (uint256 i = 0; i < ventures.length; i++) {
            for (uint256 slot = SOURCES_SLOT; slot <= LAST_GAP_SLOT; slot++) {
                assertEq(vm.load(ventures[i], bytes32(slot)), bytes32(0), "appended or gap slot already written");
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // The two owner transactions
    // ─────────────────────────────────────────────────────────

    function test_fork_beaconUpgradeKeepsEveryVentureReadable() public onFork {
        VentureView[] memory before = _snapshotAll();

        UpgradeBase.Plan memory plan = new UpgradeVentureBeacon().upgrade(_takeOverBeacon());
        assertEq(beacon.implementation(), plan.newImpl);
        assertTrue(plan.executed);

        VentureView[] memory after_ = _snapshotAll();
        for (uint256 i = 0; i < ventures.length; i++) {
            _assertSameView(before[i], after_[i], i);
            IVenture v = IVenture(ventures[i]);
            (address underlying, IVenture.AllowanceSourceKind kind,,) = v.allowanceSources(before[i].moneyToken);
            assertEq(underlying, address(0));
            assertEq(uint8(kind), 0);
            uint256 spent = before[i].allowanceMonth == _currentMonth() ? before[i].allowanceSpent : 0;
            uint256 expectedRemaining = before[i].allowanceAmount > spent ? before[i].allowanceAmount - spent : 0;
            assertEq(v.allowanceRemaining(before[i].moneyToken), expectedRemaining, "allowanceRemaining");
            for (uint256 slot = SOURCES_SLOT; slot <= LAST_GAP_SLOT; slot++) {
                assertEq(vm.load(ventures[i], bytes32(slot)), bytes32(0));
            }
        }
    }

    function test_fork_executorSwapKeepsPendingPayloadsValidAndRetiresTheOldExecutor() public onFork needsVentures {
        SwapGovernanceExecutor.Plan memory plan = new SwapGovernanceExecutor().swap(_takeOverHub());
        assertTrue(plan.executed);
        assertEq(plan.ventures, ventures.length);
        assertEq(hub.defaultGovernanceExecutor(), plan.newExecutor);
        console.log("unexecuted proposals re-validated:", plan.pendingProposals);

        vm.prank(marketCore);
        vm.expectRevert(IGovernanceExecutor.InvalidExecutor.selector);
        IGovernanceExecutor(liveExecutor).executeProposal(ventures[0], 1, 1, hex"");
    }

    function test_fork_executorBeforeBeaconCannotExecuteTheNewActionButBreaksNothing() public onFork needsVentures {
        SwapGovernanceExecutor.Plan memory plan = new SwapGovernanceExecutor().swap(_takeOverHub());
        address venture = ventures[ventures.length - 1];
        VentureView memory before = _snapshot(venture);
        bytes memory payload = _sourcePayload(venture);

        vm.prank(marketCore);
        vm.expectRevert();
        IGovernanceExecutor(plan.newExecutor).executeProposal(venture, 999, 1, payload);

        _assertSameView(before, _snapshot(venture), ventures.length - 1);

        new UpgradeVentureBeacon().upgrade(_takeOverBeacon());
        vm.prank(marketCore);
        vm.expectRevert(IVenture.InvalidAllowanceSource.selector);
        IGovernanceExecutor(plan.newExecutor).executeProposal(venture, 999, 2, payload);
    }

    function test_fork_rollbackRestoresTheLiveBehaviour() public onFork needsVentures {
        VentureView[] memory before = _snapshotAll();
        UpgradeBase.Plan memory beaconPlan = new UpgradeVentureBeacon().upgrade(_takeOverBeacon());
        SwapGovernanceExecutor.Plan memory swapPlan = new SwapGovernanceExecutor().swap(_takeOverHub());

        address owner = vm.addr(OWNER_KEY);
        vm.startPrank(owner);
        beacon.upgradeTo(beaconPlan.previousImpl);
        hub.setDefaultGovernanceExecutor(swapPlan.previousExecutor);
        vm.stopPrank();

        assertEq(beacon.implementation(), liveImpl);
        assertEq(hub.defaultGovernanceExecutor(), liveExecutor);
        VentureView[] memory after_ = _snapshotAll();
        for (uint256 i = 0; i < ventures.length; i++) {
            _assertSameView(before[i], after_[i], i);
            (bool ok,) = ventures[i].staticcall(abi.encodeCall(IVenture.allowanceRemaining, (before[i].moneyToken)));
            assertFalse(ok, "old implementation must not expose the new views");
        }

        vm.prank(marketCore);
        IGovernanceExecutor(liveExecutor).executeProposal(ventures[ventures.length - 1], 999, 1, _teamMemberPayload());
    }

    /// @dev The whole point of the upgrade, exercised against real chain state: after both owner
    ///      transactions a governance plan can register a source on a live venture and a team member
    ///      can spend the underlying budget out of it.
    function test_fork_afterBothStepsAVentureCanRegisterASourceAndSpendFromIt() public onFork needsVentures {
        new UpgradeVentureBeacon().upgrade(_takeOverBeacon());
        SwapGovernanceExecutor.Plan memory swapPlan = new SwapGovernanceExecutor().swap(_takeOverHub());
        address executor = swapPlan.newExecutor;

        address venture = ventures[ventures.length - 1];
        address underlying = IVenture(venture).moneyToken();
        uint8 decimals = IERC20Metadata(underlying).decimals();
        uint256 cap = 1_000 * 10 ** decimals;

        MockERC20 pegged = new MockERC20("Pegged Test", "pTEST", decimals);
        pegged.mint(venture, cap * 10);

        _governance(
            executor,
            venture,
            GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER,
            abi.encode(GovernanceTypes.UpdateTeamMember({member: address(this), approved: true}))
        );
        _governance(
            executor,
            venture,
            GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE,
            abi.encode(GovernanceTypes.UpdateMonthlyAllowance({token: underlying, amount: cap}))
        );
        _governance(
            executor,
            venture,
            GovernanceTypes.ActionType.SET_ALLOWANCE_SOURCE,
            abi.encode(
                GovernanceTypes.SetAllowanceSource({source: address(pegged), underlying: underlying, sourceKind: 1})
            )
        );

        assertEq(IVenture(venture).allowanceSourceCount(underlying), 1);
        assertEq(IVenture(venture).allowanceRemaining(underlying), cap);

        address recipient = makeAddr("ops");
        uint256 spend = cap / 4;
        IVenture(venture).withdrawMonthlyAllowanceFrom(address(pegged), recipient, spend);

        assertEq(pegged.balanceOf(recipient), spend, "recipient received the pegged token");
        assertEq(IVenture(venture).allowanceRemaining(underlying), cap - spend, "budget debited");

        console.log("end to end: registered a source and spent from it on venture", venture);
    }

    // ─────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────

    function _governance(address executor, address venture, GovernanceTypes.ActionType actionType, bytes memory data)
        internal
    {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({actionType: actionType, actionVersion: 1, data: data});
        proposalId++;
        vm.prank(marketCore);
        IGovernanceExecutor(executor)
            .executeProposal(
                venture, 999, proposalId, abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}))
            );
    }

    function _takeOverBeacon() internal returns (UpgradeBase.UpgradeConfig memory) {
        address owner = vm.addr(OWNER_KEY);
        vm.prank(beacon.owner());
        beacon.transferOwnership(owner);
        return UpgradeBase.UpgradeConfig({deployerKey: OWNER_KEY, hub: hub, initData: "", execute: true});
    }

    function _takeOverHub() internal returns (SwapGovernanceExecutor.SwapConfig memory) {
        address owner = vm.addr(OWNER_KEY);
        if (hub.owner() != owner) {
            vm.prank(hub.owner());
            Ownable(address(hub)).transferOwnership(owner);
        }
        return SwapGovernanceExecutor.SwapConfig({deployerKey: OWNER_KEY, hub: hub, execute: true});
    }

    function _snapshotAll() internal view returns (VentureView[] memory views) {
        views = new VentureView[](ventures.length);
        for (uint256 i = 0; i < ventures.length; i++) {
            views[i] = _snapshot(ventures[i]);
        }
    }

    function _snapshot(address ventureAddr) internal view returns (VentureView memory s) {
        IVenture v = IVenture(ventureAddr);
        s.token = v.token();
        s.moneyToken = v.moneyToken();
        s.hub = v.HUB();
        s.lbp = v.lbp();
        s.minMarketStake = v.minMarketStake();
        s.documentCount = v.documentCount();
        s.tradingPauseDuration = v.tradingPauseDuration();
        s.tradingPauseDeadline = v.tradingPauseDeadline();
        s.liquidationActive = v.liquidationActive();
        s.authorizedLiquidator = v.authorizedLiquidator();
        (s.allowanceAmount, s.allowanceSpent, s.allowanceMonth) = v.monthlyAllowance(s.moneyToken);
        for (uint256 slot = 0; slot < 12; slot++) {
            s.slots[slot] = vm.load(ventureAddr, bytes32(slot));
        }
    }

    function _assertSameView(VentureView memory a, VentureView memory b, uint256 i) internal pure {
        string memory tag = string.concat("venture #", vm.toString(i + 1));
        assertEq(a.token, b.token, tag);
        assertEq(a.moneyToken, b.moneyToken, tag);
        assertEq(a.hub, b.hub, tag);
        assertEq(a.lbp, b.lbp, tag);
        assertEq(a.minMarketStake, b.minMarketStake, tag);
        assertEq(a.documentCount, b.documentCount, tag);
        assertEq(a.tradingPauseDuration, b.tradingPauseDuration, tag);
        assertEq(a.tradingPauseDeadline, b.tradingPauseDeadline, tag);
        assertEq(a.liquidationActive, b.liquidationActive, tag);
        assertEq(a.authorizedLiquidator, b.authorizedLiquidator, tag);
        assertEq(a.allowanceAmount, b.allowanceAmount, tag);
        assertEq(a.allowanceSpent, b.allowanceSpent, tag);
        assertEq(a.allowanceMonth, b.allowanceMonth, tag);
        for (uint256 slot = 0; slot < 12; slot++) {
            assertEq(a.slots[slot], b.slots[slot], string.concat(tag, " slot ", vm.toString(slot)));
        }
    }

    function _currentMonth() internal view returns (uint256) {
        return CalendarLib.timestampToMonth(vm.getBlockTimestamp());
    }

    function _sourcePayload(address venture) internal view returns (bytes memory) {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.SET_ALLOWANCE_SOURCE,
            actionVersion: 1,
            data: abi.encode(
                GovernanceTypes.SetAllowanceSource({
                    source: address(0xDEADBEEF), underlying: IVenture(venture).moneyToken(), sourceKind: 1
                })
            )
        });
        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
    }

    function _teamMemberPayload() internal pure returns (bytes memory) {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.UpdateTeamMember({member: address(0xBEEF), approved: true}))
        });
        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
    }
}
