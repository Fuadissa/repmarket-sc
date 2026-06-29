// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {REPToken} from "../src/REPToken.sol";
import {RepAMM} from "../src/RepAMM.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract RepAMMTest is Test {
    // =========================================================
    // CONTRACTS
    // =========================================================

    REPToken public repToken;
    MockUSDC public usdc;
    RepAMM public amm;

    // =========================================================
    // SEED AMOUNTS
    // =========================================================

    uint256 constant SEED_TOKENS = 750_000 ether;
    uint256 constant SEED_USDC = 5_000 * 1e6;

    // =========================================================
    // ACTORS
    // =========================================================

    address owner = address(this);
    address bcmMock = makeAddr("bondingCurveMock");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    // =========================================================
    // SETUP
    // =========================================================

    function setUp() public {
        repToken = new REPToken("Reputation", "REP", 2_000_000 ether, owner);
        usdc = new MockUSDC();
        amm = new RepAMM(address(repToken), address(usdc), "REP");
        amm.setBondingCurve(bcmMock);
        _seedAmm();
    }

    // ─────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────

    function _seedAmm() internal {
        repToken.transfer(bcmMock, SEED_TOKENS);
        usdc.mint(bcmMock, SEED_USDC);
        vm.startPrank(bcmMock);
        repToken.approve(address(amm), SEED_TOKENS);
        usdc.approve(address(amm), SEED_USDC);
        amm.seedLiquidity(SEED_TOKENS, SEED_USDC);
        vm.stopPrank();
    }

    function _fundBuyer(address buyer, uint256 usdcAmount) internal {
        usdc.mint(buyer, usdcAmount);
        vm.prank(buyer);
        usdc.approve(address(amm), usdcAmount);
    }

    function _buy(address buyer, uint256 usdcIn) internal returns (uint256) {
        vm.prank(buyer);
        return amm.buy(usdcIn);
    }

    function _sell(address seller, uint256 tokenIn) internal returns (uint256) {
        vm.prank(seller);
        repToken.approve(address(amm), tokenIn);
        vm.prank(seller);
        return amm.sell(tokenIn);
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    function test_Constructor_Revert_ZeroToken() public {
        vm.expectRevert(RepAMM.ZeroAddress.selector);
        new RepAMM(address(0), address(usdc), "REP");
    }

    function test_Constructor_Revert_ZeroUsdc() public {
        vm.expectRevert(RepAMM.ZeroAddress.selector);
        new RepAMM(address(repToken), address(0), "REP");
    }

    // =========================================================
    // SET BONDING CURVE
    // =========================================================

    function test_SetBondingCurve_OnlyOwner() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        vm.prank(stranger);
        vm.expectRevert(RepAMM.NotOwner.selector);
        fresh.setBondingCurve(address(0x1234));
    }

    function test_SetBondingCurve_Revert_AlreadySet() public {
        vm.expectRevert(RepAMM.AlreadySet.selector);
        amm.setBondingCurve(address(0x9999));
    }

    function test_SetBondingCurve_Revert_ZeroAddress() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        vm.expectRevert(RepAMM.ZeroAddress.selector);
        fresh.setBondingCurve(address(0));
    }

    // =========================================================
    // SEED LIQUIDITY
    // =========================================================

    function test_SeedLiquidity_ReservesSet() public view {
        assertEq(amm.reserveToken(), SEED_TOKENS);
        assertEq(amm.reserveUsdc(), SEED_USDC);
        assertTrue(amm.initialized());
    }

    function test_SeedLiquidity_Revert_NotBondingCurve() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.prank(stranger);
        vm.expectRevert(RepAMM.OnlyBondingCurve.selector);
        fresh.seedLiquidity(SEED_TOKENS, SEED_USDC);
    }

    function test_SeedLiquidity_Revert_AlreadySeeded() public {
        repToken.transfer(bcmMock, SEED_TOKENS);
        usdc.mint(bcmMock, SEED_USDC);
        vm.startPrank(bcmMock);
        repToken.approve(address(amm), SEED_TOKENS);
        usdc.approve(address(amm), SEED_USDC);
        vm.expectRevert(RepAMM.AlreadySeeded.selector);
        amm.seedLiquidity(SEED_TOKENS, SEED_USDC);
        vm.stopPrank();
    }

    function test_SeedLiquidity_Revert_ZeroTokenAmount() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.prank(bcmMock);
        vm.expectRevert(RepAMM.ZeroAmount.selector);
        fresh.seedLiquidity(0, SEED_USDC);
    }

    function test_SeedLiquidity_Revert_ZeroUsdcAmount() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.prank(bcmMock);
        vm.expectRevert(RepAMM.ZeroAmount.selector);
        fresh.seedLiquidity(SEED_TOKENS, 0);
    }

    // =========================================================
    // GET RESERVES  (view function not exercised in old tests)
    // =========================================================

    function test_GetReserves_MatchesState() public view {
        (uint256 tokenRes, uint256 usdcRes) = amm.getReserves();
        assertEq(tokenRes, SEED_TOKENS);
        assertEq(usdcRes, SEED_USDC);
    }

    function test_GetReserves_UpdatesAfterBuy() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        (uint256 tokenRes, uint256 usdcRes) = amm.getReserves();
        assertEq(tokenRes, amm.reserveToken());
        assertEq(usdcRes, amm.reserveUsdc());
    }

    // =========================================================
    // ADD LIQUIDITY
    // =========================================================

    function test_AddLiquidity_ReservesIncrease() public {
        uint256 addToken = 10_000 ether;
        uint256 addUsdc = 100 * 1e6;
        repToken.approve(address(amm), addToken);
        usdc.mint(owner, addUsdc);
        usdc.approve(address(amm), addUsdc);
        amm.addLiquidity(addToken, addUsdc);
        assertEq(amm.reserveToken(), SEED_TOKENS + addToken);
        assertEq(amm.reserveUsdc(), SEED_USDC + addUsdc);
    }

    function test_AddLiquidity_Revert_ZeroTokenAmount() public {
        usdc.mint(owner, 100 * 1e6);
        usdc.approve(address(amm), 100 * 1e6);
        vm.expectRevert(RepAMM.ZeroAmount.selector);
        amm.addLiquidity(0, 100 * 1e6);
    }

    function test_AddLiquidity_Revert_ZeroUsdcAmount() public {
        repToken.approve(address(amm), 1 ether);
        vm.expectRevert(RepAMM.ZeroAmount.selector);
        amm.addLiquidity(1 ether, 0);
    }

    function test_AddLiquidity_Revert_NonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(RepAMM.NotOwner.selector);
        amm.addLiquidity(1 ether, 1);
    }

    function test_AddLiquidity_Revert_NotSeeded() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.expectRevert(RepAMM.PoolNotSeeded.selector);
        fresh.addLiquidity(1 ether, 1);
    }

    // =========================================================
    // REMOVE LIQUIDITY
    // =========================================================

    function test_RemoveLiquidity_ExactTenPercent() public {
        uint256 maxAllowed = (SEED_USDC * 1_000) / 10_000; // exactly 10%
        (uint256 usdcOut, uint256 tokenOut) = amm.removeLiquidity(maxAllowed);
        assertEq(usdcOut, maxAllowed);
        assertGt(tokenOut, 0);
        assertEq(amm.reserveUsdc(), SEED_USDC - usdcOut);
        assertEq(amm.reserveToken(), SEED_TOKENS - tokenOut);
    }

    function test_RemoveLiquidity_BelowTenPercent_NoCapApplied() public {
        // Request 5% — should get exactly what was requested (no cap needed)
        uint256 request = (SEED_USDC * 500) / 10_000; // 5%
        (uint256 usdcOut, ) = amm.removeLiquidity(request);
        // The ternary false branch: usdcRequested <= maxUsdc → usdcOut = usdcRequested
        assertEq(usdcOut, request);
    }

    function test_RemoveLiquidity_AutoCapsAtTenPercent() public {
        uint256 overRequest = SEED_USDC; // request 100%, should get only 10%
        (uint256 usdcOut, ) = amm.removeLiquidity(overRequest);
        uint256 expectedMax = (SEED_USDC * 1_000) / 10_000;
        assertEq(usdcOut, expectedMax);
    }

    function test_RemoveLiquidity_ProportionalTokens() public {
        uint256 usdcRequest = (SEED_USDC * 500) / 10_000; // 5%
        (uint256 usdcOut, uint256 tokenOut) = amm.removeLiquidity(usdcRequest);
        uint256 expectedToken = (SEED_TOKENS * usdcOut) / SEED_USDC;
        assertEq(tokenOut, expectedToken);
    }

    function test_RemoveLiquidity_Revert_ZeroAmount() public {
        vm.expectRevert(RepAMM.ZeroAmount.selector);
        amm.removeLiquidity(0);
    }

    function test_RemoveLiquidity_Revert_NonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(RepAMM.NotOwner.selector);
        amm.removeLiquidity(1);
    }

    function test_RemoveLiquidity_Revert_NotSeeded() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.expectRevert(RepAMM.PoolNotSeeded.selector);
        fresh.removeLiquidity(100);
    }

    function test_RemoveLiquidity_Revert_ReserveTooSmall() public {
        // Drain reserveUsdc to 0 via sells, then try to remove
        // Easier: deploy a fresh pool with tiny reserves
        RepAMM tiny = new RepAMM(address(repToken), address(usdc), "REP");
        address tinyCurve = makeAddr("tinyCurve");
        tiny.setBondingCurve(tinyCurve);

        // Seed with 1 token and 1 USDC-unit (so 10% rounds to 0)
        repToken.mint(tinyCurve, 1);
        usdc.mint(tinyCurve, 1);
        vm.startPrank(tinyCurve);
        repToken.approve(address(tiny), 1);
        usdc.approve(address(tiny), 1);
        tiny.seedLiquidity(1, 1); // reserveUsdc = 1 → 10% = 0
        vm.stopPrank();

        // Transfer ownership so we can call removeLiquidity
        // (tiny was deployed by this address which is owner)
        vm.expectRevert(RepAMM.ReserveTooSmall.selector);
        tiny.removeLiquidity(1);
    }

    // =========================================================
    // PRICE
    // =========================================================

    function test_GetPrice_MatchesReserveRatio() public view {
        uint256 expected = (SEED_USDC * 1e22) / SEED_TOKENS;
        assertEq(amm.getPrice(), expected);
    }

    function test_GetPrice_Revert_NotSeeded() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.expectRevert(RepAMM.PoolNotSeeded.selector);
        fresh.getPrice();
    }

    // =========================================================
    // DYNAMIC FEE
    // =========================================================

    function test_GetDynamicFeeBps_Revert_EmptyReserve() public {
        vm.expectRevert(RepAMM.EmptyReserve.selector);
        amm.getDynamicFeeBps(100, 0);
    }

    function test_GetDynamicFeeBps_AllFourTiers() public view {
        uint256 reserve = 100_000 * 1e6;
        // Tier 0: impact < 0.5% → input < 50 bps of reserve = 50 USDC
        assertEq(amm.getDynamicFeeBps(10 * 1e6, reserve), 30);
        // Tier 1: 0.5% ≤ impact < 1.0%
        assertEq(amm.getDynamicFeeBps(700 * 1e6, reserve), 50);
        // Tier 2: 1.0% ≤ impact < 3.0%
        assertEq(amm.getDynamicFeeBps(2_000 * 1e6, reserve), 100);
        // Tier 3: impact ≥ 3.0%
        assertEq(amm.getDynamicFeeBps(5_000 * 1e6, reserve), 200);
    }

    // =========================================================
    // BUY
    // =========================================================

    function test_Buy_TokensReceived() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokenOut = _buy(alice, usdcIn);
        assertGt(tokenOut, 0);
        assertEq(repToken.balanceOf(alice), tokenOut);
    }

    function test_Buy_UsdcFeeAccrued() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        (uint256 feeBps, ) = amm.previewFee(true, usdcIn);
        uint256 expectFee = (usdcIn * feeBps) / 10_000;
        _buy(alice, usdcIn);
        (uint256 accUsdc, ) = amm.getAccruedFees();
        assertEq(accUsdc, expectFee);
    }

    function test_Buy_ReservesUpdateCorrectly() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 feeBps = amm.getDynamicFeeBps(usdcIn, amm.reserveUsdc());
        uint256 feeAmount = (usdcIn * feeBps) / 10_000;
        uint256 usdcNet = usdcIn - feeAmount;
        uint256 k = amm.reserveToken() * amm.reserveUsdc();
        uint256 newUsdc = amm.reserveUsdc() + usdcNet;
        uint256 newToken = k / newUsdc;
        _buy(alice, usdcIn);
        assertEq(amm.reserveUsdc(), newUsdc);
        assertEq(amm.reserveToken(), newToken);
    }

    function test_Buy_Revert_ZeroInput() public {
        vm.prank(alice);
        vm.expectRevert(RepAMM.ZeroInput.selector);
        amm.buy(0);
    }

    function test_Buy_Revert_NotSeeded() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.prank(alice);
        vm.expectRevert(RepAMM.PoolNotSeeded.selector);
        fresh.buy(100 * 1e6);
    }

    // =========================================================
    // SELL — NORMAL
    // =========================================================

    function test_Sell_UsdcReceived() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokenOut = _buy(alice, usdcIn);
        uint256 usdcOut = _sell(alice, tokenOut / 2);
        assertGt(usdcOut, 0);
    }

    function test_Sell_TokenFeeAccrued() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokenOut = _buy(alice, usdcIn);
        uint256 toSell = tokenOut / 2;
        (uint256 feeBps, ) = amm.previewFee(false, toSell);
        uint256 expectFee = (toSell * feeBps) / 10_000;
        _sell(alice, toSell);
        (, uint256 accToken) = amm.getAccruedFees();
        assertEq(accToken, expectFee);
    }

    function test_Sell_Revert_ZeroInput() public {
        vm.prank(alice);
        vm.expectRevert(RepAMM.ZeroInput.selector);
        amm.sell(0);
    }

    function test_Sell_Revert_NotSeeded() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.prank(alice);
        vm.expectRevert(RepAMM.PoolNotSeeded.selector);
        fresh.sell(1 ether);
    }

    // =========================================================
    // SELL — 10% cap
    // =========================================================

    function test_Sell_10PercentCap_Enforced() public {
        repToken.transfer(alice, 500_000 ether);
        vm.prank(alice);
        repToken.approve(address(amm), 500_000 ether);
        vm.prank(alice);
        vm.expectRevert(RepAMM.SellExceedsCap.selector);
        amm.sell(500_000 ether);
    }

    function test_Sell_SmallAmount_WithinCap() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokenOut = _buy(alice, usdcIn);
        uint256 usdcOut = _sell(alice, tokenOut / 10);
        assertGt(usdcOut, 0);
    }

    // =========================================================
    // CLAIM FEES — all three branches (USDC-only, token-only, both)
    // =========================================================

    function test_ClaimFees_UsdcOnly() public {
        // Buy only — USDC fees accrue, no token fees
        uint256 usdcIn = 200 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);

        (uint256 accUsdc, uint256 accToken) = amm.getAccruedFees();
        assertGt(accUsdc, 0);
        assertEq(accToken, 0);

        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        uint256 ownerTokenBefore = repToken.balanceOf(owner);

        amm.claimFees();

        assertEq(usdc.balanceOf(owner), ownerUsdcBefore + accUsdc); // USDC transferred
        assertEq(repToken.balanceOf(owner), ownerTokenBefore); // no token transfer
    }

    function test_ClaimFees_TokenOnly() public {
        // Buy, then claim to zero out USDC fees, then sell — only token fees remain
        uint256 usdcIn = 200 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokenOut = _buy(alice, usdcIn);

        amm.claimFees(); // zero out USDC fees

        _sell(alice, tokenOut / 4); // now only token fees accrue

        (uint256 accUsdc2, uint256 accToken2) = amm.getAccruedFees();
        assertEq(accUsdc2, 0);
        assertGt(accToken2, 0);

        uint256 ownerTokenBefore = repToken.balanceOf(owner);
        uint256 ownerUsdcBefore = usdc.balanceOf(owner);

        amm.claimFees();

        assertEq(repToken.balanceOf(owner), ownerTokenBefore + accToken2); // token transferred
        assertEq(usdc.balanceOf(owner), ownerUsdcBefore); // no USDC transfer
    }

    function test_ClaimFees_BothUsdcAndToken() public {
        uint256 usdcIn = 200 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokenOut = _buy(alice, usdcIn);
        _sell(alice, tokenOut / 4);

        (uint256 accUsdc, uint256 accToken) = amm.getAccruedFees();
        assertGt(accUsdc, 0);
        assertGt(accToken, 0);

        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        uint256 ownerTokenBefore = repToken.balanceOf(owner);

        amm.claimFees();

        assertEq(usdc.balanceOf(owner), ownerUsdcBefore + accUsdc);
        assertEq(repToken.balanceOf(owner), ownerTokenBefore + accToken);
    }

    function test_ClaimFees_Revert_NoFees() public {
        vm.expectRevert(RepAMM.NoFeesToClaim.selector);
        amm.claimFees();
    }

    function test_ClaimFees_Revert_NonOwner() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        vm.prank(alice);
        vm.expectRevert(RepAMM.NotOwner.selector);
        amm.claimFees();
    }

    function test_ClaimFees_ResetsAccrual() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        amm.claimFees();
        (uint256 accUsdc, uint256 accToken) = amm.getAccruedFees();
        assertEq(accUsdc, 0);
        assertEq(accToken, 0);
    }

    // =========================================================
    // PREVIEW FEE
    // =========================================================

    function test_PreviewFee_Buy_MatchesActual() public {
        uint256 usdcIn = 100 * 1e6;
        (, uint256 feeAmt) = amm.previewFee(true, usdcIn);
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        (uint256 accUsdc, ) = amm.getAccruedFees();
        assertEq(feeAmt, accUsdc);
    }

    function test_PreviewFee_Sell_MatchesActual() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokenOut = _buy(alice, usdcIn);
        uint256 toSell = tokenOut / 2;
        (, uint256 feeAmt) = amm.previewFee(false, toSell);
        _sell(alice, toSell);
        (, uint256 accToken) = amm.getAccruedFees();
        assertEq(feeAmt, accToken);
    }

    function test_PreviewFee_Revert_ZeroInput() public {
        vm.expectRevert(RepAMM.ZeroInput.selector);
        amm.previewFee(true, 0);
    }

    function test_PreviewFee_Revert_NotSeeded() public {
        RepAMM fresh = new RepAMM(address(repToken), address(usdc), "REP");
        fresh.setBondingCurve(bcmMock);
        vm.expectRevert(RepAMM.PoolNotSeeded.selector);
        fresh.previewFee(true, 100);
    }

    // =========================================================
    // FUZZ
    // =========================================================

    function testFuzz_Buy_PositiveOutput(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 1 * 1e6, 100 * 1e6);
        _fundBuyer(alice, usdcIn);
        uint256 tokenOut = _buy(alice, usdcIn);
        assertGt(tokenOut, 0);
    }

    function testFuzz_RemoveLiquidity_NeverExceedsTenPercent(
        uint256 requested
    ) public {
        requested = bound(requested, 1, SEED_USDC * 10);
        uint256 maxAllowed = (amm.reserveUsdc() * 1_000) / 10_000;
        (uint256 usdcOut, ) = amm.removeLiquidity(requested);
        assertLe(usdcOut, maxAllowed);
    }

    function testFuzz_GetReserves_ConsistentWithState(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 1 * 1e6, 50 * 1e6);
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        (uint256 tokenRes, uint256 usdcRes) = amm.getReserves();
        assertEq(tokenRes, amm.reserveToken());
        assertEq(usdcRes, amm.reserveUsdc());
    }

    function testFuzz_RemoveLiquidity_BelowCap_ExactAmount(uint256 pct) public {
        // Any request ≤ 10% of reserve should come back exactly as requested
        pct = bound(pct, 1, 1_000); // 0.01% to 10%
        uint256 requested = (SEED_USDC * pct) / 10_000;
        if (requested == 0) return;
        (uint256 usdcOut, ) = amm.removeLiquidity(requested);
        assertEq(usdcOut, requested); // exact — no cap applied
    }
}
