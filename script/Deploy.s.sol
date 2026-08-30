// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ContinuousClearingAuctionFactory} from "@continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {AuctionStateLens} from "@continuous-clearing-auction/lens/AuctionStateLens.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MetaVesTFactory} from "@metavest/MetaVesTFactory.sol";
import {VestingAllocationFactory} from "@metavest/VestingAllocationFactory.sol";
import {TokenOptionFactory} from "@metavest/TokenOptionFactory.sol";
import {RestrictedTokenFactory} from "@metavest/RestrictedTokenFactory.sol";

import {UmiaHub} from "../src/core/UmiaHub.sol";
import {UmiaMarketCore} from "../src/core/UmiaMarketCore.sol";
import {UmiaMarketStake} from "../src/core/UmiaMarketStake.sol";
import {ConditionalMarketOracle} from "../src/periphery/ConditionalMarketOracle.sol";
import {GovernanceExecutor} from "../src/core/GovernanceExecutor.sol";
import {Venture} from "../src/core/Venture.sol";
import {CCALens} from "@continuous-clearing-auction/lens/CCALens.sol";
import {ProtocolFeeController} from "@liquidity-launcher/periphery/ProtocolFeeController.sol";
import {UmiaLBPFactory} from "../src/launchpad/UmiaLBPFactory.sol";
import {CCAExitHelper} from "../src/periphery/CCAExitHelper.sol";
import {Reclaim} from "../src/reclaim/Reclaim.sol";
import {UmiaHook} from "../src/periphery/UmiaHook.sol";
import {IUmiaHook} from "../src/interfaces/IUmiaHook.sol";
import {UmiaTwapMilestoneCondition} from "../src/periphery/UmiaTwapMilestoneCondition.sol";

address constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
uint160 constant UMIA_HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

/// @title Deploy
/// @notice Deploys Umia contracts. All external addresses must be provided via environment variables.
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address marketSigner = _resolveMarketSigner(deployer);

        // Resolve every deliberate-choice gate *before* opening the broadcast. These reads are pure
        // configuration validation; leaving them inside the broadcast meant a forgotten export was
        // only caught after the hub, market core, hook and factories had already been deployed and
        // paid for, leaving a half-configured protocol on-chain that the next run cannot reuse.
        address vestingAdmin = _requireRoleDecision("VESTING_ADMIN", "no key can terminate or reissue vesting grants.");
        address vetoGuardian =
            _requireRoleDecision("VETO_GUARDIAN", "only the owner can trip decision-market circuit breakers.");

        console.log("Deploying Umia contracts...");
        console.log("Deployer:", deployer);
        console.log("Market Signer:", marketSigner);

        vm.startBroadcast(deployerPrivateKey);

        address poolManager = vm.envAddress("POOL_MANAGER");

        // Deploy Hub (implementation + proxy)
        UmiaHub hubImpl = new UmiaHub();
        UmiaHub hub =
            UmiaHub(address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(UmiaHub.initialize, (deployer)))));
        console.log("UmiaHub implementation:", address(hubImpl));
        console.log("UmiaHub proxy:", address(hub));

        // Deploy Conditional Market Oracle
        ConditionalMarketOracle conditionalMarketOracle = new ConditionalMarketOracle(address(hub));
        console.log("ConditionalMarketOracle deployed at:", address(conditionalMarketOracle));

        // Deploy MarketCore (implementation + proxy). Forge auto-deploys + links the external
        // libraries MarketCreationLib / SettlementLib.
        UmiaMarketCore mmImpl = new UmiaMarketCore();
        UmiaMarketCore mm = UmiaMarketCore(
            address(new ERC1967Proxy(address(mmImpl), abi.encodeCall(UmiaMarketCore.initialize, (address(hub)))))
        );
        console.log("UmiaMarketCore implementation:", address(mmImpl));
        console.log("UmiaMarketCore proxy:", address(mm));

        // Deploy GovernanceExecutor
        GovernanceExecutor executor = new GovernanceExecutor(address(hub));
        console.log("GovernanceExecutor deployed at:", address(executor));

        // Deploy MarketStake
        UmiaMarketStake marketStake = new UmiaMarketStake(address(hub));
        console.log("UmiaMarketStake deployed at:", address(marketStake));

        // Deploy CCA Factory (skip if CCA_FACTORY env points at an existing one).
        // Skippable so we can reuse the canonical multi-chain factory
        // (0xCCccCcCAE7503...) rather than redeploying it on every stack rebuild.
        address existingCcaFactory = vm.envOr("CCA_FACTORY", address(0));
        ContinuousClearingAuctionFactory ccaFactory;
        if (existingCcaFactory != address(0)) {
            require(existingCcaFactory.code.length > 0, "CCA_FACTORY has no bytecode on this chain");
            ccaFactory = ContinuousClearingAuctionFactory(existingCcaFactory);
            console.log("ContinuousClearingAuctionFactory (existing):", existingCcaFactory);
        } else {
            // Zero-fee controller preserves current economics; enabling a real fee and deciding
            // controller ownership is a separate product decision (see #1389). globalProtocolFeePips
            // defaults to 0, so no further configuration is required.
            address existingFeeController = vm.envOr("PROTOCOL_FEE_CONTROLLER", address(0));
            address feeController;
            if (existingFeeController != address(0)) {
                require(existingFeeController.code.length > 0, "PROTOCOL_FEE_CONTROLLER has no bytecode on this chain");
                feeController = existingFeeController;
                console.log("ProtocolFeeController (existing):", existingFeeController);
            } else {
                feeController = address(new ProtocolFeeController(deployer));
                console.log("ProtocolFeeController deployed at:", feeController);
            }
            ccaFactory = new ContinuousClearingAuctionFactory(feeController);
            console.log("ContinuousClearingAuctionFactory deployed at:", address(ccaFactory));
        }

        // Deploy Auction State Lens (skip if AUCTION_STATE_LENS_ADDRESS env points at an existing one).
        address existingAuctionStateLens = vm.envOr("AUCTION_STATE_LENS_ADDRESS", address(0));
        AuctionStateLens auctionStateLens;
        if (existingAuctionStateLens != address(0)) {
            require(
                existingAuctionStateLens.code.length > 0, "AUCTION_STATE_LENS_ADDRESS has no bytecode on this chain"
            );
            auctionStateLens = AuctionStateLens(existingAuctionStateLens);
            console.log("AuctionStateLens (existing):", existingAuctionStateLens);
        } else {
            auctionStateLens = new AuctionStateLens();
            console.log("AuctionStateLens deployed at:", address(auctionStateLens));
        }

        // Deploy the CCA v2 read lens (skippable; address surfaces to contracts.json for the hub UI + cron).
        // CCALens inherits AuctionStateLens + TickDataLens, so it serves both clearing-price and tick reads.
        address existingCcaLens = vm.envOr("CCA_LENS_ADDRESS", address(0));
        CCALens ccaLens;
        if (existingCcaLens != address(0)) {
            require(existingCcaLens.code.length > 0, "CCA_LENS_ADDRESS has no bytecode on this chain");
            ccaLens = CCALens(existingCcaLens);
            console.log("CCALens (existing):", existingCcaLens);
        } else {
            ccaLens = new CCALens();
            console.log("CCALens deployed at:", address(ccaLens));
        }

        _deployCcaExitHelper();

        // Deploy the singleton UmiaHook via CreateX. The hook constructor takes only INITIAL_OWNER
        // (the deployer EOA), so init code is byte-identical across chains and CREATE2 with the same
        // salt + CreateX address yields the same UmiaHook address on every target chain.
        //
        // CreateX's _guard for our `0xDead00...DD00` salt prefix (SenderBytes.Random,
        // RedeployFlag.False) hashes the salt before passing it to CREATE2:
        //     guardedSalt = keccak256(salt)
        // so the predicted address must use the hashed salt. We still pass the RAW salt to
        // CreateX; CreateX applies _guard internally. MineUmiaHookSalt.s.sol mirrors this
        // transformation when mining, so the address it predicts matches what CreateX deploys.
        address deployerEOA = vm.envAddress("UMIA_HOOK_DEPLOYER");
        bytes32 hookSalt = vm.envBytes32("UMIA_HOOK_SALT");
        // CreateX is a pre-deployed singleton, not something this script deploys. On a chain that has
        // not been seeded with it, the raw `.call` below hits an EOA-shaped address: the call
        // *succeeds* with empty returndata, `abi.decode` then reverts with a bare panic, and the
        // failure reads like a mining/salt bug instead of a missing dependency.
        require(CREATE_X.code.length > 0, "Deploy: CreateX not deployed on this chain");
        bytes32 hookGuardedSalt = keccak256(abi.encodePacked(hookSalt));
        bytes memory hookCreationCode = abi.encodePacked(type(UmiaHook).creationCode, abi.encode(deployerEOA));
        address predictedHook = HookMiner.computeAddress(CREATE_X, uint256(hookGuardedSalt), hookCreationCode);
        require(
            uint160(predictedHook) & 0x3FFF == UMIA_HOOK_FLAGS,
            "Deploy: predicted UmiaHook address missing required permission bits"
        );
        console.log("UmiaHook will deploy at:", predictedHook);

        // Note: previously asserted tx.origin == deployerEOA here as a fast-fail. Removed
        // because tx.origin breaks under Safe/relay/HW-wallet flows, and the address-match
        // check below (`umiaHookAddr == predictedHook`) is the actual guarantee: a wrong
        // INITIAL_OWNER produces a different init code hash and therefore a different
        // predicted address, which would cause that require to revert.
        if (tx.origin != deployerEOA) {
            console.log("Note: tx.origin differs from UMIA_HOOK_DEPLOYER; relying on address-match guard.");
        }

        // Deploy via CreateX. The selector is deployCreate2(bytes32 salt, bytes memory initCode).
        (bool ok, bytes memory ret) =
            CREATE_X.call(abi.encodeWithSignature("deployCreate2(bytes32,bytes)", hookSalt, hookCreationCode));
        require(ok, "Deploy: CreateX UmiaHook deploy failed");
        address umiaHookAddr = abi.decode(ret, (address));
        require(umiaHookAddr == predictedHook, "Deploy: actual UmiaHook address differs from predicted");
        UmiaHook umiaHook = UmiaHook(umiaHookAddr);
        console.log("UmiaHook deployed at:", umiaHookAddr);

        // Deploy the factory with the canonical hook address.
        UmiaLBPFactory lbpFactory = new UmiaLBPFactory(IPoolManager(poolManager), umiaHookAddr, address(hub));
        console.log("UmiaLBPFactory deployed at:", address(lbpFactory));

        // Initialize the hook with the factory + PoolManager.
        // Must be called by the deployer EOA so the hook's INITIAL_OWNER check passes.
        umiaHook.initialize(address(lbpFactory), IPoolManager(poolManager));
        console.log("UmiaHook initialized");

        // Deploy Reclaim verifier (skip if RECLAIM_ADDRESS env points at an existing one).
        address existingReclaim = vm.envOr("RECLAIM_ADDRESS", address(0));
        Reclaim reclaim;
        if (existingReclaim != address(0)) {
            require(existingReclaim.code.length > 0, "RECLAIM_ADDRESS has no bytecode on this chain");
            reclaim = Reclaim(existingReclaim);
            console.log("Reclaim (existing):", existingReclaim);
        } else {
            reclaim = new Reclaim();
            console.log("Reclaim deployed at:", address(reclaim));
        }

        // Deploy the per-chain MetaVesT singletons (#1053). Same deploy-or-reuse-via-env
        // contract as CCA_FACTORY / RECLAIM_ADDRESS above: devnet redeploys fresh on every
        // anvil reset, persistent chains pin the canonical once-deployed singletons. The
        // per-venture controller + adapter are created later by launch-with-vesting, not here.
        _deployMetaVest();

        // Deploy Venture beacon (shared implementation for all Venture proxies)
        Venture ventureImpl = new Venture();
        UpgradeableBeacon ventureBeacon = new UpgradeableBeacon(address(ventureImpl), deployer);
        console.log("Venture implementation:", address(ventureImpl));
        console.log("Venture beacon:", address(ventureBeacon));

        // Configure Hub
        hub.setVentureBeacon(address(ventureBeacon));
        hub.setUmiaMarketCore(address(mm));
        hub.setDefaultGovernanceExecutor(address(executor));
        hub.setUmiaMarketStake(address(marketStake));
        hub.setConditionalMarketOracle(address(conditionalMarketOracle));
        hub.setMarketCreationSigner(marketSigner);
        hub.setLbpStrategyFactory(address(lbpFactory));
        hub.setCcaFactory(address(ccaFactory));
        hub.setProtocolFeeRecipient(deployer); // swap fees + protocol cuts default in initialize()
        console.log("Hub configured with all contract addresses");

        _configureOperationalRoles(hub, vestingAdmin, vetoGuardian);

        address usdc = vm.envOr("USDC_ADDRESS", address(0));
        if (usdc != address(0)) {
            hub.setApprovedMoneyToken(usdc, true);
            console.log("USDC approved as money token:", usdc);
        }

        vm.stopBroadcast();

        // Output environment variables for .env file
        console.log("\n--- Copy to .env ---");
        console.log("UMIA_HUB_ADDRESS=", address(hub));
        console.log("UMIA_MARKET_CORE_ADDRESS=", address(mm));
        console.log("UMIA_GOVERNANCE_EXECUTOR_ADDRESS=", address(executor));
        console.log("CONDITIONAL_MARKET_ORACLE_ADDRESS=", address(conditionalMarketOracle));
        console.log("CCA_FACTORY_ADDRESS=", address(ccaFactory));
        console.log("PROTOCOL_FEE_CONTROLLER_ADDRESS=", address(ccaFactory.protocolFeeController()));
        console.log("AUCTION_STATE_LENS_ADDRESS=", address(auctionStateLens));
        console.log("CCA_LENS_ADDRESS=", address(ccaLens));
        console.log("UMIA_HOOK_ADDRESS=", umiaHookAddr);
        console.log("LBP_FACTORY_ADDRESS=", address(lbpFactory));
        console.log("RECLAIM_ADDRESS=", address(reclaim));
        console.log("UMIA_MARKET_STAKE_ADDRESS=", address(marketStake));

        // Output block number for indexer start_block config
        console.log("\n--- Indexer config (services/indexer/config.yaml) ---");
        console.log("start_block:", block.number);
    }

    /// @dev Runs inside run()'s broadcast window. Logs each address in the "<Name> deployed at:
    ///      0x.." form the devnet deploy harness greps into contracts.json[env][chain].umia.
    ///      Kept in a helper so the `new` locals stay off run()'s already-deep stack. Set
    ///      METAVEST_FACTORY (plus the other four addresses) to reuse existing singletons on a
    ///      persistent chain; leaving them unset deploys fresh (the devnet path).
    /// @dev Wires the Hub's operational roles. Both are deliberately distinct from the owner so an
    ///      ops key is never the upgrade key, and both are `address(0)` after `initialize`, which
    ///      silently means "capability off". That is a safe default but rarely the intended one, so
    ///      a deployment has to state what it wants instead of inheriting it by omission. The
    ///      decisions themselves are resolved in `run()` before the broadcast opens; this only
    ///      applies them.
    function _configureOperationalRoles(UmiaHub hub, address vestingAdmin, address vetoGuardian) internal {
        if (vestingAdmin != address(0)) {
            hub.setVestingAdmin(vestingAdmin);
            console.log("Vesting admin set:", vestingAdmin);
        }

        if (vetoGuardian != address(0)) {
            hub.setVetoGuardian(vetoGuardian);
            console.log("Veto guardian set:", vetoGuardian);
        }
    }

    /// @dev Resolves the hub's market-creation signer. Prefer `MARKET_CREATION_SIGNER`, an address:
    ///      the hub only ever compares recovered signatures against it, so the deploy process has no
    ///      need for the private key and should not be handed one. `MARKET_CREATION_SIGNER_KEY`
    ///      remains supported for existing runbooks, but putting a live signing key in the deploy
    ///      environment widens its exposure to every shell, CI log and process that run sees.
    function _resolveMarketSigner(address deployer) internal view returns (address marketSigner) {
        marketSigner = vm.envOr("MARKET_CREATION_SIGNER", address(0));
        if (marketSigner != address(0)) return marketSigner;

        uint256 marketSignerKey = vm.envOr("MARKET_CREATION_SIGNER_KEY", uint256(0));
        if (marketSignerKey != 0) {
            console.log("MARKET_CREATION_SIGNER_KEY is set; prefer MARKET_CREATION_SIGNER (address only).");
            return vm.addr(marketSignerKey);
        }
        return deployer;
    }

    /// @dev Reads an operational role from `envKey`. Leaving it unset is allowed but must be
    ///      deliberate: the deploy halts unless `<envKey>_UNSET_OK=true` records that choice, so a
    ///      forgotten export can never quietly ship a protocol with the capability disabled.
    /// @param consequence What an unset role means on-chain, surfaced in both the revert and the log.
    function _requireRoleDecision(string memory envKey, string memory consequence)
        internal
        view
        returns (address role)
    {
        role = vm.envOr(envKey, address(0));
        if (role != address(0)) return role;

        require(
            vm.envOr(string.concat(envKey, "_UNSET_OK"), false),
            string.concat(envKey, " unset: ", consequence, " Set it, or set ", envKey, "_UNSET_OK=true.")
        );
        console.log(string.concat(envKey, " deliberately UNSET: "), consequence);
    }

    /// @dev Deploy or reuse the stateless CCAExitHelper — a periphery singleton that collapses a
    ///      live out-bid CCA exit into one tx (issue #1645). It has no constructor args or deps and
    ///      nothing on-chain calls it, so it needs no hub setter. Set CCA_EXIT_HELPER_ADDRESS to
    ///      reuse an existing one on a persistent chain; leaving it unset deploys fresh (the devnet
    ///      path). In a helper so its locals stay off run()'s already-deep stack, and logged in the
    ///      "<Name> deployed at: 0x.." / "(existing):" form the devnet harness greps into
    ///      contracts.json[env][chain].umia.
    function _deployCcaExitHelper() private {
        address existing = vm.envOr("CCA_EXIT_HELPER_ADDRESS", address(0));
        if (existing != address(0)) {
            require(existing.code.length > 0, "CCA_EXIT_HELPER_ADDRESS has no bytecode on this chain");
            console.log("CCAExitHelper (existing):", existing);
        } else {
            console.log("CCAExitHelper deployed at:", address(new CCAExitHelper()));
        }
    }

    function _deployMetaVest() private {
        address existing = vm.envOr("METAVEST_FACTORY", address(0));
        if (existing != address(0)) {
            require(existing.code.length > 0, "METAVEST_FACTORY has no bytecode on this chain");
            console.log("MetaVesTFactory (existing):", existing);
            console.log("VestingAllocationFactory (existing):", vm.envAddress("VESTING_ALLOCATION_FACTORY"));
            console.log("TokenOptionFactory (existing):", vm.envAddress("TOKEN_OPTION_FACTORY"));
            console.log("RestrictedTokenFactory (existing):", vm.envAddress("RESTRICTED_TOKEN_FACTORY"));
            console.log("UmiaTwapMilestoneCondition (existing):", vm.envAddress("TWAP_MILESTONE_CONDITION"));
            return;
        }
        // Required, no default: a forgotten TWAP_WINDOW would silently ship a 30-minute
        // condition that only ever reads the per-block ring.
        uint32 twapWindow = uint32(vm.envUint("TWAP_WINDOW"));
        console.log("TWAP window (s):", twapWindow);
        console.log("MetaVesTFactory deployed at:", address(new MetaVesTFactory()));
        console.log("VestingAllocationFactory deployed at:", address(new VestingAllocationFactory()));
        console.log("TokenOptionFactory deployed at:", address(new TokenOptionFactory()));
        console.log("RestrictedTokenFactory deployed at:", address(new RestrictedTokenFactory()));
        console.log("UmiaTwapMilestoneCondition deployed at:", address(new UmiaTwapMilestoneCondition(twapWindow)));
    }
}
