// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  RepAMM
 * @notice Constant-product AMM seeded at graduation from BondingCurveMarket.
 *
 *         ── Dynamic fees ──────────────────────────────────────────────────
 *         Fee is calculated on the INPUT amount before the swap, and kept
 *         inside the contract as protocol revenue (not added to reserves).
 *         The fee tier is determined by the trade's price impact — measured
 *         as (inputAmount / relevantReserve):
 *
 *           impact < 0.5 %   →  0.30 % fee
 *           impact < 1.0 %   →  0.50 % fee
 *           impact < 3.0 %   →  1.00 % fee
 *           impact ≥ 3.0 %   →  2.00 % fee
 *
 *         This makes large trades (higher market impact) pay proportionally
 *         more, protecting liquidity providers from exploitation.
 *
 *         ── Remove liquidity ──────────────────────────────────────────────
 *         Owner may remove up to 10 % of the current USDC reserve per call,
 *         with the equivalent token amount removed proportionally to keep
 *         the pool ratio intact. Only available after the AMM is seeded.
 *
 *         ── Deployment wiring ─────────────────────────────────────────────
 *         1. Factory deploys RepAMM.
 *         2. Factory deploys BondingCurveMarket(repAmm = address(amm)).
 *         3. Factory calls repAmm.setBondingCurve(address(bcm)).
 *         4. On graduation, bcm.finalizeGraduation() calls seedLiquidity().
 */
contract RepAMM is ReentrancyGuard {
    // =========================================================
    // ERRORS
    // =========================================================
    error ZeroAmount();
    error OnlyBondingCurve();
    error AlreadySeeded();
    error AlreadySet();
    error ZeroAddress();
    error NotOwner();
    error PoolNotSeeded();
    error ReserveTooSmall();
    error TokenAmountRoundsToZero();
    error EmptyReserve();
    error ZeroInput();
    error InsufficientOutput();
    error SellExceedsCap();
    error NoFeesToClaim();

    // =========================================================
    // TOKENS
    // =========================================================

    IERC20 public immutable token;
    IERC20 public immutable usdc;

    // =========================================================
    // RESERVES
    // =========================================================

    uint256 public reserveToken;
    uint256 public reserveUsdc;

    // =========================================================
    // FEE ACCOUNTING
    // =========================================================

    /// @notice Accumulated protocol fees in USDC (from buys).
    uint256 public accruedFeesUsdc;

    /// @notice Accumulated protocol fees in token (from sells).
    uint256 public accruedFeesToken;

    // =========================================================
    // TOKENS TYPE
    // =========================================================
    string public tokenType;

    // =========================================================
    // FEE TIERS  (basis points, 1 bp = 0.01%)
    // =========================================================

    uint256 public constant FEE_TIER_0 = 30; // 0.30% — impact < 0.5%
    uint256 public constant FEE_TIER_1 = 50; // 0.50% — impact < 1.0%
    uint256 public constant FEE_TIER_2 = 100; // 1.00% — impact < 3.0%
    uint256 public constant FEE_TIER_3 = 200; // 2.00% — impact >= 3.0%

    // Impact thresholds in basis points (impact = inputAmount / reserve * 10_000)
    uint256 public constant IMPACT_LOW = 50; // 0.50%
    uint256 public constant IMPACT_MED = 100; // 1.00%
    uint256 public constant IMPACT_HIGH = 300; // 3.00%

    uint256 public constant BPS_DENOM = 10_000;

    // =========================================================
    // REMOVE LIQUIDITY CAP
    // =========================================================

    /// @notice Maximum USDC withdrawable per call: 10%
    uint256 public constant MAX_REMOVE_BPS = 1_000;

    // =========================================================
    // ACCESS
    // =========================================================

    address public owner;
    address public bondingCurve;
    bool public bondingCurveSet;
    bool public initialized;

    // =========================================================
    // EVENTS
    // =========================================================

    event LiquiditySeeded(uint256 tokenAmount, uint256 usdcAmount);
    event LiquidityAdded(uint256 tokenAmount, uint256 usdcAmount);
    event LiquidityRemoved(uint256 tokenAmount, uint256 usdcAmount);
    event Swap(
        address indexed user,
        uint256 indexed totalToken,
        uint256 indexed totalUsdc,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feePaid,
        uint256 feeBps,
        uint256 nowPrice,
        string tokenType
    );
    event FeesClaimed(uint256 usdcFees, uint256 tokenFees);

    // =========================================================
    // MODIFIERS
    // =========================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyInitialized() {
        if (!initialized) revert PoolNotSeeded();
        _;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(address _token, address _usdc, string memory _tokenType) {
        if (_token == address(0) || _usdc == address(0)) revert ZeroAddress();
        token = IERC20(_token);
        usdc = IERC20(_usdc);
        owner = msg.sender;
        tokenType = _tokenType;
    }

    // =========================================================
    // WIRE BONDING CURVE  (factory calls once after deploying BCM)
    // =========================================================

    function setBondingCurve(address _bondingCurve) external onlyOwner {
        if (bondingCurveSet) revert AlreadySet();
        if (_bondingCurve == address(0)) revert ZeroAddress();
        bondingCurve = _bondingCurve;
        bondingCurveSet = true;
    }

    // =========================================================
    // SEED FROM GRADUATION  (only BondingCurveMarket may call)
    // =========================================================

    function seedLiquidity(
        uint256 tokenAmount,
        uint256 usdcAmount
    ) external nonReentrant {
        if (msg.sender != bondingCurve) revert OnlyBondingCurve();
        if (initialized) revert AlreadySeeded();
        if (tokenAmount == 0) revert ZeroAmount(); // Reusing ZeroAmount to save space!
        if (usdcAmount == 0) revert ZeroAmount();

        token.transferFrom(bondingCurve, address(this), tokenAmount);
        usdc.transferFrom(bondingCurve, address(this), usdcAmount);

        reserveToken = tokenAmount;
        reserveUsdc = usdcAmount;
        initialized = true;

        emit LiquiditySeeded(tokenAmount, usdcAmount);
    }

    // =========================================================
    // ADD LIQUIDITY  (owner only, post-seed)
    // =========================================================

    function addLiquidity(
        uint256 tokenAmount,
        uint256 usdcAmount
    ) external onlyOwner onlyInitialized nonReentrant {
        if (tokenAmount == 0 || usdcAmount == 0) revert ZeroAmount();

        token.transferFrom(msg.sender, address(this), tokenAmount);
        usdc.transferFrom(msg.sender, address(this), usdcAmount);

        reserveToken += tokenAmount;
        reserveUsdc += usdcAmount;

        emit LiquidityAdded(tokenAmount, usdcAmount);
    }

    // =========================================================
    // REMOVE LIQUIDITY  (owner only, max 10% of reserveUsdc per call)
    // =========================================================

    /**
     * @notice Withdraws up to 10% of the current USDC reserve and the
     *         proportionally equivalent token amount so the pool ratio
     *         remains unchanged after withdrawal.
     *
     *         Formula:
     *           maxUsdc   = reserveUsdc * 10%
     *           usdcOut   = min(usdcRequested, maxUsdc)
     *           tokenOut  = reserveToken * (usdcOut / reserveUsdc)
     *
     * @param  usdcRequested  USDC amount to remove. Automatically capped at 10%.
     * @return usdcOut        Actual USDC sent to the owner.
     * @return tokenOut       Proportional tokens sent to the owner.
     */
    function removeLiquidity(
        uint256 usdcRequested
    )
        external
        onlyOwner
        onlyInitialized
        nonReentrant
        returns (uint256 usdcOut, uint256 tokenOut)
    {
        if (usdcRequested == 0) revert ZeroAmount();

        // Cap at 10% of current reserve
        uint256 maxUsdc = (reserveUsdc * MAX_REMOVE_BPS) / BPS_DENOM;
        if (maxUsdc == 0) revert ReserveTooSmall();

        usdcOut = usdcRequested > maxUsdc ? maxUsdc : usdcRequested;

        // Proportional token amount: keeps price ratio unchanged
        tokenOut = (reserveToken * usdcOut) / reserveUsdc;
        if (tokenOut == 0) revert TokenAmountRoundsToZero();

        // Update state BEFORE external transfers
        reserveUsdc -= usdcOut;
        reserveToken -= tokenOut;

        usdc.transfer(msg.sender, usdcOut);
        token.transfer(msg.sender, tokenOut);

        emit LiquidityRemoved(tokenOut, usdcOut);
    }

    // =========================================================
    // DYNAMIC FEE CALCULATION
    // =========================================================

    /**
     * @notice Returns the fee tier in basis points for a trade.
     *         Impact = inputAmount / inputReserve, expressed in bps.
     *
     * @param  inputAmount   Raw amount being traded (before fee).
     * @param  inputReserve  Pool reserve of the input token.
     */
    function getDynamicFeeBps(
        uint256 inputAmount,
        uint256 inputReserve
    ) public pure returns (uint256 feeBps) {
        if (inputReserve == 0) revert EmptyReserve();

        // impact in bps = inputAmount * 10_000 / inputReserve
        uint256 impactBps = (inputAmount * BPS_DENOM) / inputReserve;

        if (impactBps < IMPACT_LOW)
            return FEE_TIER_0; // < 0.5%  → 0.30%
        else if (impactBps < IMPACT_MED)
            return FEE_TIER_1; // < 1.0%  → 0.50%
        else if (impactBps < IMPACT_HIGH)
            return FEE_TIER_2; // < 3.0%  → 1.00%
        else return FEE_TIER_3; // >= 3.0% → 2.00%
    }

    // =========================================================
    // PRICE
    // =========================================================

    function getPrice() public view onlyInitialized returns (uint256) {
        return (reserveUsdc * 1e22) / reserveToken; // divide by 10_000 * 10_000 to get the actuas usd amount
    }

    // =========================================================
    // BUY  (user sends USDC → receives tokens)
    // =========================================================

    /**
     * @notice Buy tokens with USDC.
     *         The dynamic fee is deducted from usdcIn before the AMM
     *         formula sees it, so the fee is not amplified by price impact.
     *         Fees accumulate in accruedFeesUsdc for owner to claim later.
     *
     * @param  usdcIn   Total USDC the user sends (fee included).
     * @return tokenOut Tokens the user receives.
     */
    function buy(
        uint256 usdcIn
    ) external onlyInitialized nonReentrant returns (uint256 tokenOut) {
        if (usdcIn == 0) revert ZeroInput();

        usdc.transferFrom(msg.sender, address(this), usdcIn);
        uint256 nowPrice = getPrice();

        // Dynamic fee on gross input
        uint256 feeBps = getDynamicFeeBps(usdcIn, reserveUsdc);
        uint256 feeAmount = (usdcIn * feeBps) / BPS_DENOM;
        uint256 usdcNet = usdcIn - feeAmount;

        // Fee stays in contract, NOT added to reserves
        // accruedFeesUsdc += feeAmount;

        accruedFeesUsdc += feeAmount;
        if (feeAmount > 0) usdc.transfer(owner, feeAmount);

        // Constant-product swap on net input
        uint256 newUsdc = reserveUsdc + usdcNet;
        uint256 newToken = (reserveToken * reserveUsdc) / newUsdc;
        tokenOut = reserveToken - newToken;

        if (tokenOut == 0) revert InsufficientOutput();

        reserveUsdc = newUsdc;
        reserveToken = newToken;

        token.transfer(msg.sender, tokenOut);

        emit Swap(
            msg.sender,
            reserveToken,
            reserveUsdc,
            true,
            usdcIn,
            tokenOut,
            feeAmount,
            feeBps,
            nowPrice,
            tokenType // ✅ from state
        );
    }

    // =========================================================
    // SELL  (user sends tokens → receives USDC)
    // =========================================================

    /**
     * @notice Sell tokens for USDC.
     *         The dynamic fee is deducted from tokenIn before the AMM
     *         formula sees it.
     *         Fees accumulate in accruedFeesToken for owner to claim later.
     *
     *         A single sell cannot drain more than 10% of reserveUsdc.
     *         This protects the pool from large coordinated sell-downs.
     *         If the computed usdcOut would exceed that cap the transaction
     *         reverts — the user must split into smaller sells.
     *
     * @param  tokenIn  Total tokens the user sends (fee included).
     * @return usdcOut  USDC the user receives.
     */
    // function sell(
    //     uint256 tokenIn
    // ) external onlyInitialized nonReentrant returns (uint256 usdcOut) {
    //     if (tokenIn == 0) revert ZeroInput();

    //     token.transferFrom(msg.sender, address(this), tokenIn);
    //     uint256 nowPrice = getPrice();

    //     // Dynamic fee on gross input
    //     uint256 feeBps = getDynamicFeeBps(tokenIn, reserveToken);
    //     uint256 feeAmount = (tokenIn * feeBps) / BPS_DENOM;
    //     uint256 tokenNet = tokenIn - feeAmount;

    //     // Fee stays in contract, NOT added to reserves
    //     accruedFeesToken += feeAmount;

    //     // Constant-product swap on net input
    //     uint256 newToken = reserveToken + tokenNet;
    //     uint256 newUsdc = (reserveToken * reserveUsdc) / newToken;
    //     usdcOut = reserveUsdc - newUsdc;

    //     if (usdcOut == 0) revert InsufficientOutput();

    //     // ── 10% sell cap ──────────────────────────────────────
    //     // A single sell may not remove more than 10% of reserveUsdc.
    //     // This is checked AFTER the AMM formula so the cap is exact.
    //     uint256 maxUsdcOut = (reserveUsdc * MAX_REMOVE_BPS) / BPS_DENOM;
    //     if (usdcOut > maxUsdcOut) revert SellExceedsCap();

    //     reserveToken = newToken;
    //     reserveUsdc = newUsdc;

    //     usdc.transfer(msg.sender, usdcOut);

    //     emit Swap(
    //         msg.sender,
    //         reserveToken,
    //         reserveUsdc,
    //         false,
    //         tokenIn,
    //         usdcOut,
    //         feeAmount,
    //         feeBps,
    //         nowPrice,
    //         tokenType // ✅ from state
    //     );
    // }

    function sell(
        uint256 tokenIn
    ) external onlyInitialized nonReentrant returns (uint256 usdcOut) {
        if (tokenIn == 0) revert ZeroInput();

        token.transferFrom(msg.sender, address(this), tokenIn);
        uint256 nowPrice = getPrice();

        // ── Swap the FULL token amount through the pool first ──
        uint256 newToken = reserveToken + tokenIn;
        uint256 newUsdc = (reserveToken * reserveUsdc) / newToken;
        uint256 grossUsdcOut = reserveUsdc - newUsdc;

        // ── 10% cap now applies to the gross drain on the pool ──
        uint256 maxUsdcOut = (reserveUsdc * MAX_REMOVE_BPS) / BPS_DENOM;
        if (grossUsdcOut > maxUsdcOut) revert SellExceedsCap();

        // ── Fee taken on the USDC OUTPUT, not the token input ──
        uint256 feeBps = getDynamicFeeBps(tokenIn, reserveToken);
        uint256 feeAmount = (grossUsdcOut * feeBps) / BPS_DENOM;
        usdcOut = grossUsdcOut - feeAmount;

        if (usdcOut == 0) revert InsufficientOutput();

        accruedFeesUsdc += feeAmount; // fee stays in USDC, not accruedFeesToken

        // accruedFeesUsdc += feeAmount;
        if (feeAmount > 0) usdc.transfer(owner, feeAmount);

        reserveToken = newToken;
        reserveUsdc = newUsdc;

        usdc.transfer(msg.sender, usdcOut);

        emit Swap(
            msg.sender,
            reserveToken,
            reserveUsdc,
            false,
            tokenIn,
            usdcOut,
            feeAmount,
            feeBps,
            nowPrice,
            tokenType
        );
    }

    // =========================================================
    // CLAIM FEES  (owner only)
    // =========================================================

    /**
     * @notice Sends all accumulated protocol fees to the owner.
     *         USDC fees come from buys; token fees come from sells.
     */
    // function claimFees() external onlyOwner nonReentrant {
    //     uint256 usdcFees = accruedFeesUsdc;
    //     uint256 tokenFees = accruedFeesToken;

    //     if (usdcFees == 0 && tokenFees == 0) revert NoFeesToClaim();

    //     // Zero out before transferring
    //     accruedFeesUsdc = 0;
    //     accruedFeesToken = 0;

    //     if (usdcFees > 0) usdc.transfer(msg.sender, usdcFees);
    //     if (tokenFees > 0) token.transfer(msg.sender, tokenFees);

    //     emit FeesClaimed(usdcFees, tokenFees);
    // }

    // =========================================================
    // VIEW HELPERS
    // =========================================================

    function getReserves()
        external
        view
        returns (uint256 tokenRes, uint256 usdcRes)
    {
        return (reserveToken, reserveUsdc);
    }

    function getAccruedFees()
        external
        view
        returns (uint256 usdcFees, uint256 tokenFees)
    {
        return (accruedFeesUsdc, accruedFeesToken);
    }

    /**
     * @notice Preview the fee a trade would incur without executing it.
     *         Useful for front-end quote display.
     *
     * @param  isBuy       true = buying tokens with USDC; false = selling tokens.
     * @param  inputAmount Gross amount the user intends to send.
     * @return feeBps      The fee tier that will apply.
     * @return feeAmount   Exact fee in input-token units.
     */
    function previewFee(
        bool isBuy,
        uint256 inputAmount
    )
        external
        view
        onlyInitialized
        returns (uint256 feeBps, uint256 feeAmount)
    {
        if (inputAmount == 0) revert ZeroInput();
        uint256 inputReserve = isBuy ? reserveUsdc : reserveToken;
        feeBps = getDynamicFeeBps(inputAmount, inputReserve);
        feeAmount = (inputAmount * feeBps) / BPS_DENOM;
    }
}
