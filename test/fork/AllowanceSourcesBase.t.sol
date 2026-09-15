// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Venture} from "../../src/core/Venture.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IGovernanceExecutor} from "../../src/interfaces/IGovernanceExecutor.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {CalendarLib} from "../../src/libraries/CalendarLib.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/// @dev Base mainnet rehearsal of the allowance-sources upgrade against the live Umia venture,
///      Aave v3, DAI and the Steakhouse USDC Morpho vault. Runs only with FORK_RPC_URL set.
contract AllowanceSourcesBaseForkTest is Test {
    address internal constant VENTURE = 0x57fbe5581A16bf5384e5195f3DD8c8A876f4FB05;
    address internal constant BEACON = 0x61279d5548a52514528f05864A4739247dC8280a;
    address internal constant HUB = 0x120dbCDd58Bb787309573e29159fE6D37A1983F6;
    address internal constant LIVE_EXECUTOR = 0x80BA46801923564c1518fFD38d5a425B3a242bf4;
    address internal constant MARKET_CORE = 0x55975E430Cc54C63dff03B1E6d27Be574Ce229F6;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant ABAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address internal constant DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address internal constant STEAK_USDC = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;

    uint256 internal constant CAP = 120_000e6;
    uint256 internal constant PARK = 1_000_000e6;

    address internal team = makeAddr("team");
    address internal ops = makeAddr("ops");

    Venture internal venture = Venture(payable(VENTURE));
    address internal executor;
    uint256 internal proposalId;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        Venture upgraded = new Venture();
        vm.prank(UpgradeableBeacon(BEACON).owner());
        UpgradeableBeacon(BEACON).upgradeTo(address(upgraded));

        assertEq(IUmiaHub(HUB).governanceExecutor(VENTURE), LIVE_EXECUTOR);
        executor = address(new GovernanceExecutor(HUB));
        vm.prank(Ownable(HUB).owner());
        IUmiaHub(HUB).setDefaultGovernanceExecutor(executor);

        deal(DAI, VENTURE, 100_000e18);
    }

    function _action(GovernanceTypes.ActionType actionType, bytes memory data)
        internal
        pure
        returns (GovernanceTypes.ActionV1 memory)
    {
        return GovernanceTypes.ActionV1({actionType: actionType, actionVersion: 1, data: data});
    }

    function _execute(GovernanceTypes.ActionV1[] memory actions) internal {
        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
        proposalId++;
        vm.prank(MARKET_CORE);
        IGovernanceExecutor(executor).executeProposal(VENTURE, 999, proposalId, payload);
    }

    function _one(GovernanceTypes.ActionType actionType, bytes memory data) internal {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = _action(actionType, data);
        _execute(actions);
    }

    function _source(address source, IVenture.AllowanceSourceKind kind) internal {
        _one(
            GovernanceTypes.ActionType.SET_ALLOWANCE_SOURCE,
            abi.encode(GovernanceTypes.SetAllowanceSource({source: source, underlying: USDC, sourceKind: uint8(kind)}))
        );
    }

    function _park(address target, bytes memory depositCall) internal {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](3);
        actions[0] = _action(
            GovernanceTypes.ActionType.SET_ALLOWANCE,
            abi.encode(GovernanceTypes.SetAllowance({token: USDC, spender: target, amount: PARK}))
        );
        actions[1] = _action(
            GovernanceTypes.ActionType.CALL,
            abi.encode(GovernanceTypes.Call({target: target, value: 0, data: depositCall}))
        );
        actions[2] = _action(
            GovernanceTypes.ActionType.SET_ALLOWANCE,
            abi.encode(GovernanceTypes.SetAllowance({token: USDC, spender: target, amount: 0}))
        );
        _execute(actions);
    }

    function test_fork_parkInAaveAndMorphoThenSpendAcrossFourSources() public {
        _one(
            GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER,
            abi.encode(GovernanceTypes.UpdateTeamMember({member: team, approved: true}))
        );
        _one(
            GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE,
            abi.encode(GovernanceTypes.UpdateMonthlyAllowance({token: USDC, amount: CAP}))
        );
        vm.warp(vm.getBlockTimestamp() + 32 days);
        assertEq(venture.allowanceRemaining(USDC), CAP);

        uint256 liquidBefore = IERC20(USDC).balanceOf(VENTURE);
        _park(AAVE_POOL, abi.encodeCall(IAavePool.supply, (USDC, PARK, VENTURE, 0)));
        _park(STEAK_USDC, abi.encodeCall(IERC4626.deposit, (PARK, VENTURE)));
        assertEq(IERC20(USDC).balanceOf(VENTURE), liquidBefore - 2 * PARK);
        assertApproxEqAbs(IERC20(ABAS_USDC).balanceOf(VENTURE), PARK, 10);
        assertApproxEqAbs(IERC4626(STEAK_USDC).convertToAssets(IERC20(STEAK_USDC).balanceOf(VENTURE)), PARK, 2);
        assertEq(IERC20(USDC).allowance(VENTURE, AAVE_POOL), 0);
        assertEq(IERC20(USDC).allowance(VENTURE, STEAK_USDC), 0);

        _source(ABAS_USDC, IVenture.AllowanceSourceKind.PEGGED);
        _source(DAI, IVenture.AllowanceSourceKind.PEGGED);
        _source(STEAK_USDC, IVenture.AllowanceSourceKind.ERC4626);

        vm.startPrank(team);
        venture.withdrawMonthlyAllowance(USDC, ops, 50_000e6);
        venture.withdrawMonthlyAllowanceFrom(ABAS_USDC, ops, 30_000e6);
        venture.withdrawMonthlyAllowanceFrom(DAI, ops, 10_000e6);
        venture.withdrawMonthlyAllowanceFrom(STEAK_USDC, ops, 30_000e6);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(ops), 80_000e6);
        assertApproxEqAbs(IERC20(ABAS_USDC).balanceOf(ops), 30_000e6, 10);
        assertEq(IERC20(DAI).balanceOf(ops), 10_000e18);
        assertEq(venture.allowanceRemaining(USDC), 0);

        vm.prank(team);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowanceFrom(STEAK_USDC, ops, 1);
        vm.prank(team);
        vm.expectRevert(IVenture.AllowanceExceeded.selector);
        venture.withdrawMonthlyAllowance(USDC, ops, 1);
    }

    function test_fork_legacyAllowanceUntouchedBeforeAnySource() public {
        _one(
            GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER,
            abi.encode(GovernanceTypes.UpdateTeamMember({member: team, approved: true}))
        );
        (uint256 amount, uint256 spent, uint256 month) = venture.monthlyAllowance(USDC);
        uint256 effective = month == CalendarLib.timestampToMonth(vm.getBlockTimestamp()) ? spent : 0;
        assertEq(venture.allowanceRemaining(USDC), amount > effective ? amount - effective : 0);

        vm.warp(vm.getBlockTimestamp() + 32 days);
        assertEq(venture.allowanceRemaining(USDC), amount);

        vm.prank(team);
        venture.withdrawMonthlyAllowance(USDC, ops, 1e6);
        assertEq(venture.allowanceRemaining(USDC), amount - 1e6);
        assertEq(IERC20(USDC).balanceOf(ops), 1e6);
    }
}
