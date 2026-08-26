// ═══════════════════════════════════════════════════════════════
// StateMachine.spec — Market lifecycle transition verification
// Target: MarketCoreHarness (extending UmiaMarketCore)
// ═══════════════════════════════════════════════════════════════

using MarketCoreHarness as mm;

methods {
    // Harness helpers
    function getMarketCounter() external returns (uint256) envfree;
    function getProposalCounter() external returns (uint256) envfree;
    function getIsSettled(uint256) external returns (bool) envfree;
    function getIsExecuted(uint256) external returns (bool) envfree;
    function getHasClaimed(uint256, address) external returns (bool) envfree;
    function getWinningProposalId(uint256) external returns (uint256) envfree;

    // MarketCore public functions
    function getMarketStatus(uint256) external returns (UmiaMarketCore.MarketStatus);
    function split(uint256, uint256, uint256) external;
    function merge(uint256, uint256, uint256) external;
    function claimSettlement(uint256) external;
    function settleMarket(uint256) external;
    function executeWinningProposal(uint256) external;
    function routerSwapExactIn(uint256, uint256, uint256, uint256, bool, address) external;
    function routerSwapExactOut(uint256, uint256, uint256, uint256, bool, address) external;
    function addLiquidity(uint256, uint256, uint256, uint256, uint256) external;

    // ASSUMPTION: ERC20 transfers and external dependencies are NONDET.
    // See MarketCore.spec for detailed rationale.
    function _.safeTransferFrom(address, address, uint256) external => NONDET;
    function _.safeTransfer(address, uint256) external => NONDET;
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
// Rule 1: Split only when OPEN
// split() must revert when market is not in OPEN status.
// MarketStatus: PENDING=0, OPEN=1, ENDED=2
// ═══════════════════════════════════════════════════════════════

rule splitOnlyWhenOpen(env e, uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) {
    UmiaMarketCore.MarketStatus status = getMarketStatus(e, marketId);
    require status != UmiaMarketCore.MarketStatus.OPEN;

    split@withrevert(e, marketId, ventureAmount, moneyAmount);

    assert lastReverted, "Split must revert when market is not OPEN";
}


// ═══════════════════════════════════════════════════════════════
// Rule 2: Merge only when OPEN
// ═══════════════════════════════════════════════════════════════

rule mergeOnlyWhenOpen(env e, uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) {
    UmiaMarketCore.MarketStatus status = getMarketStatus(e, marketId);
    require status != UmiaMarketCore.MarketStatus.OPEN;

    merge@withrevert(e, marketId, ventureAmount, moneyAmount);

    assert lastReverted, "Merge must revert when market is not OPEN";
}


// ═══════════════════════════════════════════════════════════════
// Rule 3: Settlement only when ENDED
// settleMarket() must revert when market is not ENDED.
// ═══════════════════════════════════════════════════════════════

rule settlementOnlyWhenEnded(env e, uint256 marketId) {
    UmiaMarketCore.MarketStatus status = getMarketStatus(e, marketId);
    require status != UmiaMarketCore.MarketStatus.ENDED;

    settleMarket@withrevert(e, marketId);

    assert lastReverted, "Settlement must revert when market is not ENDED";
}


// ═══════════════════════════════════════════════════════════════
// Rule 4: Claim only when settled
// claimSettlement() must revert when market has not been settled.
// ═══════════════════════════════════════════════════════════════

rule claimOnlyWhenSettled(env e, uint256 marketId) {
    require !getIsSettled(marketId);

    claimSettlement@withrevert(e, marketId);

    assert lastReverted, "Claim must revert when market is not settled";
}


// ═══════════════════════════════════════════════════════════════
// Rule 5: Market counter only increases
// No function can decrease the market counter.
// ═══════════════════════════════════════════════════════════════

rule marketCounterMonotonic(method f, env e, calldataarg args) {
    uint256 counterBefore = getMarketCounter();

    f(e, args);

    uint256 counterAfter = getMarketCounter();

    assert counterAfter >= counterBefore, "Market counter must never decrease";
}


// ═══════════════════════════════════════════════════════════════
// Rule 6: Proposal counter only increases
// ═══════════════════════════════════════════════════════════════

rule proposalCounterMonotonic(method f, env e, calldataarg args) {
    uint256 counterBefore = getProposalCounter();

    f(e, args);

    uint256 counterAfter = getProposalCounter();

    assert counterAfter >= counterBefore, "Proposal counter must never decrease";
}


// ═══════════════════════════════════════════════════════════════
// Rule 7: hasClaimed is monotonic (once true, always true)
// No function can reset hasClaimed from true back to false.
// ═══════════════════════════════════════════════════════════════

rule hasClaimedMonotonic(method f, env e, calldataarg args, uint256 marketId, address user) {
    require getHasClaimed(marketId, user);

    f(e, args);

    assert getHasClaimed(marketId, user), "hasClaimed must never go from true to false";
}


// ═══════════════════════════════════════════════════════════════
// Rule 8: marketExecuted is monotonic (once true, always true)
// ═══════════════════════════════════════════════════════════════

rule marketExecutedMonotonic(method f, env e, calldataarg args, uint256 marketId) {
    require getIsExecuted(marketId);

    f(e, args);

    assert getIsExecuted(marketId), "marketExecuted must never go from true to false";
}


// ═══════════════════════════════════════════════════════════════
// Rule 9: Settlement is monotonic (once settled, always settled)
// The winning proposal ID, once set, cannot change.
// ═══════════════════════════════════════════════════════════════

rule settlementMonotonic(method f, env e, calldataarg args, uint256 marketId) {
    uint256 winnerBefore = getWinningProposalId(marketId);
    require winnerBefore != 0; // already settled

    f(e, args);

    uint256 winnerAfter = getWinningProposalId(marketId);

    assert winnerAfter == winnerBefore, "Winning proposal must never change once set";
}


// ═══════════════════════════════════════════════════════════════
// Rule 10: Addliquidity only when OPEN
// ═══════════════════════════════════════════════════════════════

rule addLiquidityOnlyWhenOpen(env e, uint256 proposalId, uint256 amount0, uint256 amount1, uint256 priceX96, uint256 slippageBps) {
    // Get the market for this proposal
    // proposalToMarket is public, use it
    uint256 marketId = mm.proposalToMarket(e, proposalId);
    require marketId != 0;

    UmiaMarketCore.MarketStatus status = getMarketStatus(e, marketId);
    require status != UmiaMarketCore.MarketStatus.OPEN;

    addLiquidity@withrevert(e, proposalId, amount0, amount1, priceX96, slippageBps);

    assert lastReverted, "addLiquidity must revert when market is not OPEN";
}
