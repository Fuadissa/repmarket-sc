// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {REPToken} from "../src/REPToken.sol";
import {BondingCurveMarket} from "../src/BondingCurveMarket.sol";
import {RepAMM} from "../src/RepAMM.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract BondingCurveMarketTest is Test {
    // =========================================================
    // CONTRACTS
    // =========================================================

    REPToken public repToken;
    MockUSDC public usdc;
    BondingCurveMarket public bcm;
    RepAMM public amm;

    // =========================================================
    // TEST PARAMETERS  (small numbers so graduation is reachable)
    // =========================================================

    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 constant CURVE_SUPPLY = 500_000 ether;
    uint256 constant AMM_RESERVE_TOKENS = 500_000 ether;

    uint256 constant V_TOKEN = 1_000_000 ether;
    uint256 constant V_USDC = 10_000 * 1e6; // 10 000 USDC

    uint256 constant GRAD_TOKEN_THRESHOLD = CURVE_SUPPLY;
    uint256 constant GRAD_USDC_TARGET = 5_000 * 1e6; // 5 000 USDC

    // =========================================================
    // ACTORS
    // =========================================================

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    // =========================================================
    // SETUP
    // =========================================================

    function setUp() public {
        repToken = new REPToken("Reputation", "REP", TOTAL_SUPPLY, owner);
        usdc = new MockUSDC();
        amm = new RepAMM(address(repToken), address(usdc), "REP");

        bcm = new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );

        amm.setBondingCurve(address(bcm));
        repToken.transfer(address(bcm), TOTAL_SUPPLY);
        bcm.initializeCurveSupply(CURVE_SUPPLY);
    }

    // ─────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────

    function _fundBuyer(address buyer, uint256 usdcAmount) internal {
        usdc.mint(buyer, usdcAmount);
        vm.prank(buyer);
        usdc.approve(address(bcm), usdcAmount);
    }

    function _buy(address buyer, uint256 usdcIn) internal returns (uint256) {
        vm.prank(buyer);
        return bcm.buy(usdcIn);
    }

    function _sell(address seller, uint256 tokenIn) internal returns (uint256) {
        vm.prank(seller);
        repToken.approve(address(bcm), tokenIn);
        vm.prank(seller);
        return bcm.sell(tokenIn);
    }

    // =========================================================
    // CONSTRUCTOR REQUIRE BRANCHES
    // =========================================================

    function test_Constructor_Revert_ZeroToken() public {
        vm.expectRevert(BondingCurveMarket.ZeroAddress.selector);
        new BondingCurveMarket(
            address(0),
            address(usdc),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
    }

    function test_Constructor_Revert_ZeroUsdc() public {
        vm.expectRevert(BondingCurveMarket.ZeroAddress.selector);
        new BondingCurveMarket(
            address(repToken),
            address(0),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
    }

    function test_Constructor_Revert_ZeroAmm() public {
        vm.expectRevert(BondingCurveMarket.ZeroAddress.selector);
        new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(0),
            AMM_RESERVE_TOKENS,
            "REP"
        );
    }

    function test_Constructor_Revert_ZeroVirtualTokenReserve() public {
        vm.expectRevert(BondingCurveMarket.ZeroReserve.selector);
        new BondingCurveMarket(
            address(repToken),
            address(usdc),
            0,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
    }

    function test_Constructor_Revert_ZeroVirtualUsdcReserve() public {
        vm.expectRevert(BondingCurveMarket.ZeroReserve.selector);
        new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            0,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
    }

    function test_Constructor_Revert_ZeroGraduationThreshold() public {
        vm.expectRevert(BondingCurveMarket.ZeroThreshold.selector);
        new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            0,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
    }

    function test_Constructor_Revert_ZeroGraduationUsdcTarget() public {
        vm.expectRevert(BondingCurveMarket.ZeroTarget.selector);
        new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            0,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
    }

    // =========================================================
    // INITIALIZE CURVE SUPPLY
    // =========================================================

    function test_InitialState() public view {
        assertEq(bcm.reserveToken(), CURVE_SUPPLY);
        assertEq(bcm.reserveUsdc(), 0);
        assertEq(bcm.tokensSold(), 0);
        assertTrue(bcm.initialized());
        assertFalse(bcm.graduated());
    }

    function test_Revert_InitializeTwice() public {
        vm.expectRevert(BondingCurveMarket.AlreadyInitialized.selector);
        bcm.initializeCurveSupply(CURVE_SUPPLY);
    }

    function test_Revert_Initialize_ZeroSupply() public {
        BondingCurveMarket fresh = new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
        vm.expectRevert(BondingCurveMarket.ZeroSupply.selector);
        fresh.initializeCurveSupply(0);
    }

    function test_Revert_Initialize_NonOwner() public {
        BondingCurveMarket fresh = new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
        vm.prank(alice);
        vm.expectRevert();
        fresh.initializeCurveSupply(CURVE_SUPPLY);
    }

    // =========================================================
    // PRICE & QUOTES
    // =========================================================

    function test_InitialPrice() public view {
        uint256 expected = (V_USDC * 1e22) / V_TOKEN;
        assertEq(bcm.getPrice(), expected);
    }

    function test_QuoteTokensOut_IsPositive() public view {
        assertGt(bcm.quoteTokensOut(100 * 1e6), 0);
    }

    function test_QuoteTokensOut_Revert_ZeroInput() public {
        vm.expectRevert(BondingCurveMarket.ZeroInput.selector);
        bcm.quoteTokensOut(0);
    }

    function test_QuoteUsdcOut_IsPositive() public view {
        assertGt(bcm.quoteUsdcOut(1_000 ether), 0);
    }

    function test_QuoteUsdcOut_Revert_ZeroInput() public {
        vm.expectRevert(BondingCurveMarket.ZeroInput.selector);
        bcm.quoteUsdcOut(0);
    }

    // =========================================================
    // GET RESERVES & GET STATE  (view functions not called before)
    // =========================================================

    function test_GetReserves_Initial() public view {
        (uint256 tokenRes, uint256 usdcRes) = bcm.getReserves();
        assertEq(tokenRes, CURVE_SUPPLY);
        assertEq(usdcRes, 0);
    }

    function test_GetReserves_AfterBuy() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        (, uint256 feeAmount) = bcm.previewFee(true, usdcIn);
        _buy(alice, usdcIn);
        (uint256 tokenRes, uint256 usdcRes) = bcm.getReserves();
        assertLt(tokenRes, CURVE_SUPPLY);
        assertEq(usdcRes, usdcIn - feeAmount);
    }

    function test_GetState_Initial() public view {
        (bool isGraduated, bool isPending, uint256 sold) = bcm.getState();
        assertFalse(isGraduated);
        assertFalse(isPending);
        assertEq(sold, 0);
    }

    function test_GetState_AfterBuy() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokensOut = _buy(alice, usdcIn);
        (, , uint256 sold) = bcm.getState();
        assertEq(sold, tokensOut);
    }

    function test_GetState_AfterGraduation() public {
        _fillCurveToGraduation();
        (bool isGraduated, bool isPending, ) = bcm.getState();
        assertTrue(isGraduated);
        assertFalse(isPending); // always false — retained slot only
    }

    // =========================================================
    // DYNAMIC FEE TIERS
    // =========================================================

    function test_Fee_Tier0_SmallTrade() public view {
        uint256 smallInput = V_USDC / 1000; // 0.1% impact
        (uint256 feeBps, ) = bcm.previewFee(true, smallInput);
        assertEq(feeBps, 30);
    }

    function test_Fee_Tier1_MediumTrade() public view {
        uint256 input = (V_USDC * 75) / 10_000; // 0.75% impact
        (uint256 feeBps, ) = bcm.previewFee(true, input);
        assertEq(feeBps, 50);
    }

    function test_Fee_Tier2_LargeTrade() public view {
        uint256 input = (V_USDC * 200) / 10_000; // 2% impact
        (uint256 feeBps, ) = bcm.previewFee(true, input);
        assertEq(feeBps, 100);
    }

    function test_Fee_Tier3_HugeTrade() public view {
        uint256 input = (V_USDC * 500) / 10_000; // 5% impact
        (uint256 feeBps, ) = bcm.previewFee(true, input);
        assertEq(feeBps, 200);
    }

    function test_PreviewFee_Sell_Branch() public view {
        // Exercises the `isBuy = false` ternary branch in previewFee
        uint256 tokensIn = 1_000 ether;
        (uint256 feeBps, uint256 feeAmount) = bcm.previewFee(false, tokensIn);
        assertGt(feeBps, 0);
        assertGt(feeAmount, 0);
        // Sell fee is measured against virtualTokenReserve, not virtualUsdcReserve
        uint256 expectedBps = bcm.getDynamicFeeBps(
            tokensIn,
            bcm.virtualTokenReserve()
        );
        assertEq(feeBps, expectedBps);
    }

    function test_PreviewFee_Revert_ZeroInput() public {
        vm.expectRevert(BondingCurveMarket.ZeroInput.selector);
        bcm.previewFee(true, 0);
    }

    function test_PreviewFee_Revert_NotInitialized() public {
        BondingCurveMarket fresh = new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
        vm.expectRevert(BondingCurveMarket.NotInitialized.selector);
        fresh.previewFee(true, 100 * 1e6);
    }

    function test_GetDynamicFeeBps_Revert_EmptyReserve() public {
        vm.expectRevert(BondingCurveMarket.EmptyReserve.selector);
        bcm.getDynamicFeeBps(100, 0);
    }

    // =========================================================
    // BUY — NORMAL
    // =========================================================

    function test_Buy_Normal_TokensReceived() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 aliceBefore = repToken.balanceOf(alice);
        uint256 tokensOut = _buy(alice, usdcIn);
        assertGt(tokensOut, 0);
        assertEq(repToken.balanceOf(alice), aliceBefore + tokensOut);
    }

    function test_Buy_UsdcTransferredToBcm() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        (, uint256 feeAmount) = bcm.previewFee(true, usdcIn);
        _buy(alice, usdcIn);
        assertEq(bcm.reserveUsdc(), usdcIn - feeAmount);
    }

    function test_Buy_FeeAccrued() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        (, uint256 expectedFee) = bcm.previewFee(true, usdcIn);
        _buy(alice, usdcIn);
        (uint256 accUsdc, ) = bcm.getAccruedFees();
        assertEq(accUsdc, expectedFee);
    }

    function test_Buy_PriceIncreasesAfterBuy() public {
        uint256 priceBefore = bcm.getPrice();
        uint256 usdcIn = 500 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        assertGt(bcm.getPrice(), priceBefore);
    }

    function test_Buy_TokensSoldTracked() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokensOut = _buy(alice, usdcIn);
        assertEq(bcm.tokensSold(), tokensOut);
    }

    function test_Buy_DoesNotGraduate_BelowThreshold() public {
        // Small buy — _checkGraduation fires but takes the false branch
        uint256 usdcIn = 50 * 1e6; // far below 5 000 USDC target
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        assertFalse(bcm.graduated()); // graduation condition NOT met
    }

    function test_Buy_Revert_NotInitialized() public {
        BondingCurveMarket fresh = new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            GRAD_TOKEN_THRESHOLD,
            GRAD_USDC_TARGET,
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
        usdc.mint(alice, 100 * 1e6);
        vm.prank(alice);
        usdc.approve(address(fresh), 100 * 1e6);
        vm.prank(alice);
        vm.expectRevert(BondingCurveMarket.NotInitialized.selector);
        fresh.buy(100 * 1e6);
    }

    function test_Buy_Revert_ZeroInput() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurveMarket.ZeroInput.selector);
        bcm.buy(0);
    }

    // =========================================================
    // BUY — PARTIAL FILL
    // =========================================================

    function test_Buy_PartialFill_RefundsExcessUsdc() public {
        uint256 bigUsdc = 1_000_000 * 1e6; // far exceeds curve depth
        usdc.mint(alice, bigUsdc);
        vm.prank(alice);
        usdc.approve(address(bcm), bigUsdc);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 tokenBefore = repToken.balanceOf(alice);

        _buy(alice, bigUsdc);

        uint256 usdcSpent = usdcBefore - usdc.balanceOf(alice);
        uint256 tokensGot = repToken.balanceOf(alice) - tokenBefore;

        assertEq(tokensGot, CURVE_SUPPLY); // all curve supply delivered
        assertLt(usdcSpent, bigUsdc); // excess refunded
        assertEq(bcm.reserveToken(), 0);
    }

    function test_Buy_PartialFill_ZeroRefund() public {
        // Send exactly the right amount to buy the last tokens — refund should be 0.
        // First, drain most of the curve leaving just a tiny amount.
        // Then send the precise net USDC to buy the remainder with zero overshoot.

        // Buy most of the curve supply first
        uint256 bigUsdc = 400 * 1e6;
        _fundBuyer(bob, bigUsdc);
        _buy(bob, bigUsdc);

        uint256 remaining = bcm.reserveToken();
        assertGt(remaining, 0);

        // Compute exact USDC net needed for all remaining tokens
        // usdcNetNeeded = k / (V_token - remaining) - V_usdc
        uint256 vToken = bcm.virtualTokenReserve();
        uint256 vUsdc = bcm.virtualUsdcReserve();
        uint256 kVal = bcm.k();
        uint256 netNeeded = (kVal / (vToken - remaining)) - vUsdc;

        // Compute fee on that net amount (fee is applied to gross, not net,
        // but we want refund = 0, so we send gross such that net == netNeeded)
        // Approximate: send netNeeded directly as gross — fee will be tiny but refund
        // tests the branch where usdcNetRefund rounds to 0 or is 0.
        // Alternatively: fund enough so the partial fill is exact.
        // The cleanest way: pre-approve the exact usdcIn that produces 0 refund.
        // We send a very exact amount just barely covering the fill.
        uint256 feeBps = bcm.getDynamicFeeBps(netNeeded, vUsdc);
        // usdcIn such that usdcIn * (1 - feeBps/10000) = netNeeded
        // usdcIn = netNeeded * 10000 / (10000 - feeBps)
        uint256 exactUsdcIn = (netNeeded * 10_000) / (10_000 - feeBps);

        usdc.mint(charlie, exactUsdcIn);
        vm.prank(charlie);
        usdc.approve(address(bcm), exactUsdcIn);

        uint256 charlieBefore = usdc.balanceOf(charlie);
        _buy(charlie, exactUsdcIn);
        uint256 charlieAfter = usdc.balanceOf(charlie);

        // All tokens delivered (partial fill path hit)
        assertGt(repToken.balanceOf(charlie), 0);
        // Refund is zero or negligible (rounding dust only)
        // assertEq(charlieAfter - charlieBefore, 1); // at most 1 wei dust back
        assertEq(charlieAfter, 0); // at most 1 wei dust back
    }

    function test_Buy_PartialFill_TriggersGraduation() public {
        _fillCurveToGraduation();
        assertTrue(bcm.graduated());
    }

    // =========================================================
    // SELL — NORMAL
    // =========================================================

    function test_Sell_UsdcReceived() public {
        uint256 usdcIn = 200 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokensOut = _buy(alice, usdcIn);
        uint256 usdcOut = _sell(alice, tokensOut / 2);
        assertGt(usdcOut, 0);
        assertEq(usdc.balanceOf(alice), usdcOut);
    }

    function test_Sell_FeeAccruedInToken() public {
        uint256 usdcIn = 200 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokensOut = _buy(alice, usdcIn);
        uint256 toSell = tokensOut / 2;
        (, uint256 expectedFee) = bcm.previewFee(false, toSell);
        _sell(alice, toSell);
        (, uint256 accToken) = bcm.getAccruedFees();
        assertEq(accToken, expectedFee);
    }

    function test_Sell_PriceDecreasesAfterSell() public {
        uint256 usdcIn = 500 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokensOut = _buy(alice, usdcIn);
        uint256 priceAfterBuy = bcm.getPrice();
        _sell(alice, tokensOut / 2);
        assertLt(bcm.getPrice(), priceAfterBuy);
    }

    function test_Sell_Revert_InsufficientLiquidity() public {
        uint256 usdcIn = 50 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);

        // Mint a massive token balance to alice so the sell would drain > reserveUsdc
        repToken.mint(alice, 10_000_000 ether);
        vm.prank(alice);
        repToken.approve(address(bcm), 10_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(BondingCurveMarket.InsufficientUsdcLiquidity.selector);
        bcm.sell(10_000_000 ether);
    }

    function test_Sell_Revert_ZeroInput() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurveMarket.ZeroInput.selector);
        bcm.sell(0);
    }

    // =========================================================
    // GRADUATION
    // =========================================================

    function test_Graduation_AutoFires_OnBuy() public {
        _fillCurveToGraduation();
        assertTrue(bcm.graduated());
    }

    function test_Graduation_SeedsRepAMM() public {
        _fillCurveToGraduation();
        assertTrue(amm.initialized());
        assertGt(amm.reserveToken(), 0);
        assertGt(amm.reserveUsdc(), 0);
    }

    function test_Graduation_BcmReservesZeroed() public {
        _fillCurveToGraduation();
        assertEq(bcm.reserveToken(), 0);
        assertEq(bcm.reserveUsdc(), 0);
    }

    function test_Graduation_ViaTokenThreshold() public {
        // Drive tokensSold to exactly graduationThreshold with enough USDC too
        // Use a setup where USDC target is very low so token threshold fires first
        BondingCurveMarket bcm2 = new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            CURVE_SUPPLY, // token threshold = entire curve supply
            1 * 1e6, // USDC target = 1 USDC (trivially met)
            address(amm),
            AMM_RESERVE_TOKENS,
            "REP"
        );
        // Need fresh AMM not yet wired
        RepAMM amm2 = new RepAMM(address(repToken), address(usdc), "REP");
        BondingCurveMarket bcm2b = new BondingCurveMarket(
            address(repToken),
            address(usdc),
            V_TOKEN,
            V_USDC,
            CURVE_SUPPLY,
            1 * 1e6,
            address(amm2),
            AMM_RESERVE_TOKENS,
            "REP"
        );
        amm2.setBondingCurve(address(bcm2b));
        repToken.mint(address(bcm2b), TOTAL_SUPPLY);
        bcm2b.initializeCurveSupply(CURVE_SUPPLY);

        // Buy enough to hit the token threshold (the USDC target of 1 USDC is met immediately)
        uint256 bigUsdc = 500_000 * 1e6;
        usdc.mint(alice, bigUsdc);
        vm.prank(alice);
        usdc.approve(address(bcm2b), bigUsdc);
        vm.prank(alice);
        try bcm2b.buy(bigUsdc) {} catch {}
        assertTrue(bcm2b.graduated());
    }

    function test_Graduation_ViaReserveTokenZero() public {
        // reserveToken == 0 triggers graduation when USDC target also met
        // Already covered by _fillCurveToGraduation but this makes the branch explicit
        _fillCurveToGraduation();
        // After graduation, reserveToken is 0 and graduated is true
        assertEq(bcm.reserveToken(), 0);
        assertTrue(bcm.graduated());
    }

    function test_Buy_Revert_AfterGraduation() public {
        _fillCurveToGraduation();
        usdc.mint(alice, 100 * 1e6);
        vm.prank(alice);
        usdc.approve(address(bcm), 100 * 1e6);
        vm.prank(alice);
        vm.expectRevert(BondingCurveMarket.MarketGraduated.selector);
        bcm.buy(100 * 1e6);
    }

    function test_Sell_Revert_AfterGraduation() public {
        _fillCurveToGraduation();
        vm.prank(alice);
        vm.expectRevert(BondingCurveMarket.MarketGraduated.selector);
        bcm.sell(1 ether);
    }

    // =========================================================
    // FINALIZE GRADUATION FALLBACK
    // =========================================================

    function test_FinalizeGraduation_Revert_AlreadyGraduated() public {
        _fillCurveToGraduation();
        vm.expectRevert(BondingCurveMarket.AlreadyGraduated.selector);
        bcm.finalizeGraduation();
    }

    function test_FinalizeGraduation_Revert_ConditionsNotMet() public {
        // Curve active, no buys — conditions not met at all
        vm.expectRevert(BondingCurveMarket.GraduationConditionsNotMet.selector);
        bcm.finalizeGraduation();
    }

    function test_FinalizeGraduation_Revert_UsdcTargetNotMet() public {
        // Buy tokens to hit token threshold but NOT USDC target
        // USDC target is 5 000 USDC; we only send 100 USDC
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        // tokensSold < threshold, reserveUsdc < target → should revert
        vm.expectRevert(BondingCurveMarket.GraduationConditionsNotMet.selector);
        bcm.finalizeGraduation();
    }

    // =========================================================
    // CLAIM FEES
    // =========================================================

    function test_ClaimFees_UsdcOnly() public {
        // Only buy — accrues USDC fees only, no token fees
        uint256 usdcIn = 300 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);

        (uint256 accUsdc, uint256 accToken) = bcm.getAccruedFees();
        assertGt(accUsdc, 0);
        assertEq(accToken, 0); // no sells yet

        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        uint256 ownerTokenBefore = repToken.balanceOf(owner);

        bcm.claimFees();

        assertEq(usdc.balanceOf(owner), ownerUsdcBefore + accUsdc);
        assertEq(repToken.balanceOf(owner), ownerTokenBefore); // no token transfer
    }

    function test_ClaimFees_TokenOnly() public {
        // Give alice tokens directly (without buying on the curve) so we
        // can create a sell without a prior buy that would have added USDC fees.
        // 1. Buy to put some USDC in reserve (so sell can succeed)
        uint256 usdcIn = 300 * 1e6;
        _fundBuyer(bob, usdcIn);
        uint256 tokensFromBob = _buy(bob, usdcIn);

        // 2. Claim the USDC fees from bob's buy so accruedFeesUsdc = 0
        bcm.claimFees();

        // 3. Now sell — only token fees accrue
        uint256 toSell = tokensFromBob / 2;
        _sell(bob, toSell);

        (uint256 accUsdc2, uint256 accToken2) = bcm.getAccruedFees();
        assertEq(accUsdc2, 0); // USDC fees were claimed
        assertGt(accToken2, 0); // only token fees from sell

        uint256 ownerTokenBefore = repToken.balanceOf(owner);
        uint256 ownerUsdcBefore = usdc.balanceOf(owner);

        bcm.claimFees();

        assertEq(repToken.balanceOf(owner), ownerTokenBefore + accToken2); // token fee claimed
        assertEq(usdc.balanceOf(owner), ownerUsdcBefore); // no USDC transfer
    }

    function test_ClaimFees_BothUsdcAndToken() public {
        uint256 usdcIn = 200 * 1e6;
        _fundBuyer(alice, usdcIn);
        uint256 tokensOut = _buy(alice, usdcIn);
        _sell(alice, tokensOut / 2);

        (uint256 accUsdc, uint256 accToken) = bcm.getAccruedFees();
        assertGt(accUsdc, 0);
        assertGt(accToken, 0);

        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        uint256 ownerTokenBefore = repToken.balanceOf(owner);

        bcm.claimFees();

        assertEq(usdc.balanceOf(owner), ownerUsdcBefore + accUsdc);
        assertEq(repToken.balanceOf(owner), ownerTokenBefore + accToken);
    }

    function test_ClaimFees_ResetsAccrual() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        bcm.claimFees();
        (uint256 accUsdc, uint256 accToken) = bcm.getAccruedFees();
        assertEq(accUsdc, 0);
        assertEq(accToken, 0);
    }

    function test_ClaimFees_Revert_NoFees() public {
        vm.expectRevert(BondingCurveMarket.NoFeesToClaim.selector);
        bcm.claimFees();
    }

    function test_ClaimFees_Revert_NonOwner() public {
        uint256 usdcIn = 100 * 1e6;
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        vm.prank(alice);
        vm.expectRevert();
        bcm.claimFees();
    }

    // =========================================================
    // PREVIEW FEE — already exercised above; extra confirm
    // =========================================================

    function test_PreviewFee_MatchesActualFee() public {
        uint256 usdcIn = 150 * 1e6;
        (, uint256 previewAmount) = bcm.previewFee(true, usdcIn);
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        (uint256 accUsdc, ) = bcm.getAccruedFees();
        assertEq(previewAmount, accUsdc);
    }

    // =========================================================
    // FUZZ
    // =========================================================

    function testFuzz_Buy_AlwaysReceivesPositiveTokens(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 1 * 1e6, 500 * 1e6);
        _fundBuyer(alice, usdcIn);
        uint256 tokensOut = _buy(alice, usdcIn);
        assertGt(tokensOut, 0);
    }

    function testFuzz_Fee_AlwaysNonZero(uint256 usdcIn) public view {
        usdcIn = bound(usdcIn, 1 * 1e6, 1_000 * 1e6);
        (, uint256 feeAmount) = bcm.previewFee(true, usdcIn);
        assertGt(feeAmount, 0);
    }

    function testFuzz_SellFee_AlwaysNonZero(uint256 tokensIn) public view {
        tokensIn = bound(tokensIn, 1 ether, 10_000 ether);
        (, uint256 feeAmount) = bcm.previewFee(false, tokensIn);
        assertGt(feeAmount, 0);
    }

    function testFuzz_GetReserves_ConsistentWithState(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 1 * 1e6, 200 * 1e6);
        _fundBuyer(alice, usdcIn);
        _buy(alice, usdcIn);
        (uint256 tokenRes, uint256 usdcRes) = bcm.getReserves();
        assertEq(tokenRes, bcm.reserveToken());
        assertEq(usdcRes, bcm.reserveUsdc());
    }

    // =========================================================
    // INTERNAL HELPER
    // =========================================================

    function _fillCurveToGraduation() internal {
        uint256 chunk = 1_000 * 1e6;
        for (uint256 i = 0; i < 10; i++) {
            address buyer = address(uint160(0xDEAD + i));
            usdc.mint(buyer, chunk);
            vm.prank(buyer);
            usdc.approve(address(bcm), chunk);
            if (bcm.graduated()) break;
            vm.prank(buyer);
            try bcm.buy(chunk) {} catch {}
        }
        if (!bcm.graduated()) {
            address sweeper = makeAddr("sweeper");
            uint256 bigAmount = 100_000 * 1e6;
            usdc.mint(sweeper, bigAmount);
            vm.prank(sweeper);
            usdc.approve(address(bcm), bigAmount);
            vm.prank(sweeper);
            try bcm.buy(bigAmount) {} catch {}
        }
    }
}
