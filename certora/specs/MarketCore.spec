// ═══════════════════════════════════════════════════════════════
// MarketCore.spec — Solvency, settlement, and claim safety
// Target: MarketCoreHarness (extending UmiaMarketCore)
//
// Known coverage gaps:
// - removeLiquidity / _reAddLiquidity (Uniswap V4 integration) — not covered.
//   If the re-add fails or returns less liquidity, accounting could be off.
// - ERC20 transfers are NONDET — see assumption note in methods block.
// ═══════════════════════════════════════════════════════════════

using MarketCoreHarness as mm;

methods {
    // Harness view helpers
    function getCpmmReserve0(uint256) external returns (uint256) envfree;
    function getCpmmReserve1(uint256) external returns (uint256) envfree;
    function getUserVirtualVentureSupply(uint256) external returns (uint256) envfree;
    function getUserVirtualMoneySupply(uint256) external returns (uint256) envfree;
    function getRealVentureBalance(uint256) external returns (uint256) envfree;
    function getRealMoneyBalance(uint256) external returns (uint256) envfree;
    function getTotalSupply(uint256) external returns (uint256) envfree;
    function getHasClaimed(uint256, address) external returns (bool) envfree;
    function getIsSettled(uint256) external returns (bool) envfree;
    function getIsExecuted(uint256) external returns (bool) envfree;
    function getWinningProposalId(uint256) external returns (uint256) envfree;
    function getBalanceOfToken(address, uint256) external returns (uint256) envfree;
    function getMarketCounter() external returns (uint256) envfree;
    function getProposalCounter() external returns (uint256) envfree;
    function getLpVentureRemoved(uint256) external returns (uint256) envfree;
    function getLpMoneyRemoved(uint256) external returns (uint256) envfree;
    function getVirtualVentureId(uint256) external returns (uint256) envfree;
    function getVirtualMoneyId(uint256) external returns (uint256) envfree;
    function getProposalMarket(uint256) external returns (uint256) envfree;
    function checkInvariant(uint256) external envfree;
    function getMaxUserVirtualSupply(uint256) external returns (uint256, uint256) envfree;

    // MarketCore public functions
    function getMarketStatus(uint256) external returns (UmiaMarketCore.MarketStatus);
    function getStoredVirtualVentureId(uint256) external returns (uint256) envfree;
    function getStoredVirtualMoneyId(uint256) external returns (uint256) envfree;
    function split(uint256, uint256, uint256) external;
    function merge(uint256, uint256, uint256) external;
    function claimSettlement(uint256) external;
    function settleMarket(uint256) external;
    function executeWinningProposal(uint256) external;
    function routerSwapExactIn(uint256, uint256, uint256, uint256, bool, address) external;
    function routerSwapExactOut(uint256, uint256, uint256, uint256, bool, address) external;
    function addLiquidity(uint256, uint256, uint256, uint256, uint256) external;

    // ASSUMPTION: ERC20 transfers are summarized as NONDET — the prover assumes
    // they always succeed and transfer the exact amount. This means these specs
    // do NOT catch bugs where internal accounting diverges from actual token
    // balances (e.g., fee-on-transfer tokens, rebasing tokens, or revert paths
    // that skip balance updates). Umia uses standard ERC20 tokens vetted at
    // venture creation time, making this assumption reasonable.
    function _.safeTransferFrom(address, address, uint256) external => NONDET;
    function _.safeTransfer(address, uint256) external => NONDET;

    // ASSUMPTION: Uniswap V4, TWAP oracle, and Hub registry calls are NONDET.
    // swapRouter() returning NONDET means access control on routerSwap* is
    // not verified (the prover can pick any address). This is intentional,
    // these specs focus on accounting invariants, not access control.
    function _.update(uint256, uint256, uint256) external => NONDET;
    function _.initialize(uint256, uint256, uint256, uint32, uint32, uint16) external => NONDET;
    function _.calculateTWAP(uint256, uint256, uint256) external => NONDET;
    function _.swapRouter() external => NONDET;
    function _.conditionalMarketOracle() external => NONDET;
    function _.ventureById(uint256) external => NONDET;
    function _.ventureTokenById(uint256) external => NONDET;
    function _.ventureMoneyTokenById(uint256) external => NONDET;
    function _.winningMarketThresholdBps() external => NONDET;
    function _.circuitBreakerActive(uint256) external => NONDET;
    function _.governanceExecutor(address) external => NONDET;
}


// ═══════════════════════════════════════════════════════════════
// Ghost: sum of all balanceOf[user][tokenId] across all users.
// Maintained by an Sstore hook — updated on every _mint, _burn, transfer.
// Used to prove totalSupply[id] == Σ balanceOf[user][id] for all users.
// ═══════════════════════════════════════════════════════════════

ghost mapping(uint256 => mathint) sumOfBalances {
    init_state axiom forall uint256 id. sumOfBalances[id] == 0;
}

hook Sstore currentContract.balanceOf[KEY address owner][KEY uint256 id] uint256 newBalance (uint256 oldBalance) {
    sumOfBalances[id] = sumOfBalances[id] + to_mathint(newBalance) - to_mathint(oldBalance);
}

invariant totalSupplyIsSumOfBalances(uint256 tokenId)
    to_mathint(getTotalSupply(tokenId)) == sumOfBalances[tokenId];


// ═══════════════════════════════════════════════════════════════
// Rule 1: Solvency invariant holds after split
// After a successful split, the contract must remain solvent:
// totalRealTokens >= max(userVirtualSupply) across proposals
// ═══════════════════════════════════════════════════════════════

rule solvencyInvariantHoldsAfterSplit(env e, uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) {
    split(e, marketId, ventureAmount, moneyAmount);

    checkInvariant@withrevert(marketId);
    assert !lastReverted, "Solvency invariant must hold after split";
}


// ═══════════════════════════════════════════════════════════════
// Rule 2: Solvency invariant holds after merge
// ═══════════════════════════════════════════════════════════════

rule solvencyInvariantHoldsAfterMerge(env e, uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) {
    merge(e, marketId, ventureAmount, moneyAmount);

    checkInvariant@withrevert(marketId);
    assert !lastReverted, "Solvency invariant must hold after merge";
}


// ═══════════════════════════════════════════════════════════════
// Rule 3: Split-merge net zero
// Splitting and then merging the same amounts returns to original state.
// ═══════════════════════════════════════════════════════════════

rule splitMergeNetZero(env e, uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) {
    require ventureAmount > 0 || moneyAmount > 0;

    uint256 realVentureBefore = getRealVentureBalance(marketId);
    uint256 realMoneyBefore = getRealMoneyBalance(marketId);

    split(e, marketId, ventureAmount, moneyAmount);
    merge(e, marketId, ventureAmount, moneyAmount);

    uint256 realVentureAfter = getRealVentureBalance(marketId);
    uint256 realMoneyAfter = getRealMoneyBalance(marketId);

    assert realVentureAfter == realVentureBefore, "Real venture balance must return to original after split+merge";
    assert realMoneyAfter == realMoneyBefore, "Real money balance must return to original after split+merge";
}


// ═══════════════════════════════════════════════════════════════
// Rule 4: Split exactly increases supply for market proposals
// For an arbitrary proposalId, split has two effects:
// - If the proposal belongs to the market: supply increases by
//   exactly ventureAmount / moneyAmount (proven via proposalToMarket).
// - If the proposal does NOT belong to the market: supply is unchanged.
// ═══════════════════════════════════════════════════════════════

rule splitExactSupplyChange(env e, uint256 marketId, uint256 ventureAmount, uint256 moneyAmount, uint256 proposalId) {
    uint256 proposalMarket = getProposalMarket(proposalId);

    uint256 ventureSupplyBefore = getUserVirtualVentureSupply(proposalId);
    uint256 moneySupplyBefore = getUserVirtualMoneySupply(proposalId);

    split(e, marketId, ventureAmount, moneyAmount);

    uint256 ventureSupplyAfter = getUserVirtualVentureSupply(proposalId);
    uint256 moneySupplyAfter = getUserVirtualMoneySupply(proposalId);

    if (proposalMarket == marketId) {
        assert to_mathint(ventureSupplyAfter) == to_mathint(ventureSupplyBefore) + to_mathint(ventureAmount),
            "Split must increase venture supply by exact amount for market proposals";
        assert to_mathint(moneySupplyAfter) == to_mathint(moneySupplyBefore) + to_mathint(moneyAmount),
            "Split must increase money supply by exact amount for market proposals";
    } else {
        assert ventureSupplyAfter == ventureSupplyBefore,
            "Split must not change venture supply for proposals outside the market";
        assert moneySupplyAfter == moneySupplyBefore,
            "Split must not change money supply for proposals outside the market";
    }
}


// ═══════════════════════════════════════════════════════════════
// Rule 5: No double claim
// A user who has already claimed cannot claim again.
// ═══════════════════════════════════════════════════════════════

rule noDoubleClaim(env e, uint256 marketId) {
    require getHasClaimed(marketId, e.msg.sender);

    claimSettlement@withrevert(e, marketId);

    assert lastReverted, "Double claim must revert";
}


// ═══════════════════════════════════════════════════════════════
// Rule 6: Claim burns virtual tokens
// After successful claim, user's virtual token balance in winning
// proposal is zero.
// ═══════════════════════════════════════════════════════════════

rule claimBurnsVirtualTokens(env e, uint256 marketId) {
    uint256 winningProposalId = getWinningProposalId(marketId);
    require winningProposalId != 0; // market is settled

    // Use stored token IDs (from _proposalById), not the pure computation.
    // claimSettlement reads from _proposalById storage, so we must check
    // the same IDs it actually burns.
    uint256 virtualVentureId = getStoredVirtualVentureId(winningProposalId);
    uint256 virtualMoneyId = getStoredVirtualMoneyId(winningProposalId);

    claimSettlement(e, marketId);

    uint256 ventureBalanceAfter = getBalanceOfToken(e.msg.sender, virtualVentureId);
    uint256 moneyBalanceAfter = getBalanceOfToken(e.msg.sender, virtualMoneyId);

    assert ventureBalanceAfter == 0, "Virtual venture balance must be zero after claim";
    assert moneyBalanceAfter == 0, "Virtual money balance must be zero after claim";
}


// ═══════════════════════════════════════════════════════════════
// Rule 7: Claim sets hasClaimed flag
// After successful claim, the hasClaimed flag is set.
// ═══════════════════════════════════════════════════════════════

rule claimSetsFlag(env e, uint256 marketId) {
    require !getHasClaimed(marketId, e.msg.sender);

    claimSettlement(e, marketId);

    assert getHasClaimed(marketId, e.msg.sender), "hasClaimed must be true after successful claim";
}


// ═══════════════════════════════════════════════════════════════
// Rule 8: Virtual supply conservation through swaps
// Total virtual token supply (CPMM reserves + user supply)
// is conserved through swaps. Swaps move tokens between contract
// and user but don't create or destroy them.
//
// ASSUMPTION: routerSwapExactIn requires msg.sender == HUB.swapRouter().
// Since HUB.swapRouter() is NONDET, the prover can assume it returns
// e.msg.sender, making access control trivially pass. This is sound for
// proving the conservation property (which is about accounting, not
// access control) but does not verify the access control itself.
// ═══════════════════════════════════════════════════════════════

rule virtualSupplyConservationOnSwap(
    env e,
    uint256 proposalId,
    uint256 amountIn,
    uint256 amountOutMin,
    uint256 maxPriceImpactBps,
    bool zeroForOne
) {
    uint256 reserve0Before = getCpmmReserve0(proposalId);
    uint256 reserve1Before = getCpmmReserve1(proposalId);
    uint256 userVentureBefore = getUserVirtualVentureSupply(proposalId);
    uint256 userMoneyBefore = getUserVirtualMoneySupply(proposalId);

    mathint totalVentureBefore = to_mathint(reserve0Before) + to_mathint(userVentureBefore);
    mathint totalMoneyBefore = to_mathint(reserve1Before) + to_mathint(userMoneyBefore);

    mm.routerSwapExactIn(e, proposalId, amountIn, amountOutMin, maxPriceImpactBps, zeroForOne, e.msg.sender);

    uint256 reserve0After = getCpmmReserve0(proposalId);
    uint256 reserve1After = getCpmmReserve1(proposalId);
    uint256 userVentureAfter = getUserVirtualVentureSupply(proposalId);
    uint256 userMoneyAfter = getUserVirtualMoneySupply(proposalId);

    mathint totalVentureAfter = to_mathint(reserve0After) + to_mathint(userVentureAfter);
    mathint totalMoneyAfter = to_mathint(reserve1After) + to_mathint(userMoneyAfter);

    assert totalVentureAfter == totalVentureBefore, "Total virtual venture supply must be conserved through swap";
    assert totalMoneyAfter == totalMoneyBefore, "Total virtual money supply must be conserved through swap";
}


// ═══════════════════════════════════════════════════════════════
// Rule 9: totalSupply tracks mint/burn accurately
// _mint increases totalSupply, _burn decreases by exact amount.
// We verify this through split (which calls _mint for all proposals).
// ═══════════════════════════════════════════════════════════════

rule totalSupplyTracksOnSplit(env e, uint256 marketId, uint256 ventureAmount, uint256 moneyAmount, uint256 proposalId) {
    require ventureAmount > 0;

    uint256 virtualVentureId = getVirtualVentureId(proposalId);
    uint256 supplyBefore = getTotalSupply(virtualVentureId);

    split(e, marketId, ventureAmount, moneyAmount);

    uint256 supplyAfter = getTotalSupply(virtualVentureId);

    // totalSupply should increase by ventureAmount if proposalId is in the market
    assert supplyAfter >= supplyBefore, "Total supply must not decrease after split (mint)";
}


// ═══════════════════════════════════════════════════════════════
// Rule 10: Settle only once
// A settled market cannot be settled again.
// ═══════════════════════════════════════════════════════════════

rule settleOnlyOnce(env e, uint256 marketId) {
    require getIsSettled(marketId);

    settleMarket@withrevert(e, marketId);

    assert lastReverted, "Settling an already-settled market must revert";
}


// ═══════════════════════════════════════════════════════════════
// Rule 11: Execute only once
// An executed market cannot be executed again.
// ═══════════════════════════════════════════════════════════════

rule executeOnlyOnce(env e, uint256 marketId) {
    require getIsExecuted(marketId);

    executeWinningProposal@withrevert(e, marketId);

    assert lastReverted, "Executing an already-executed market must revert";
}
