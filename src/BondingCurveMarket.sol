// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =========================================================
// INTERFACE — avoids a circular import with RepAMM.sol
// =========================================================

interface IRepAMM {
    function seedLiquidity(uint256 tokenAmount, uint256 usdcAmount) external;
}

/**
 * @title  BondingCurveMarket
 * @notice Constant-product virtual-AMM bonding curve.
 *
 *         Invariant:  k = V_token × V_usdc
 *
 *         Spot price (USDC per token, 18-dp):
 *             price = V_usdc × 1e18 / V_token
 *
 *         Buy  quote:  tokensOut = V_token  −  k / (V_usdc  + usdcIn)
 *         Sell quote:  usdcOut   = V_usdc   −  k / (V_token + tokensIn)
 *
 *         Graduation is automatic:
 *           The buy() that crosses the threshold triggers _checkGraduation()
 *           which immediately seeds the RepAMM in the same transaction.
 *           All curve state is zeroed before the external call (checks-effects-
 *           interactions), so there is no reentrancy risk.
 *           A public finalizeGraduation() fallback exists in case the automatic
 *           path ever fails (e.g. temporary RepAMM issue), allowing recovery
 *           without redeploying.
 */
contract BondingCurveMarket is ReentrancyGuard, Ownable {
    // =========================================================
    // ERRORS
    // =========================================================
    error ZeroAddress();
    error ZeroReserve();
    error ZeroThreshold();
    error ZeroTarget();
    error AlreadyInitialized();
    error ZeroSupply();
    error ZeroInput();
    error EmptyReserve();
    error NotInitialized();
    error MarketGraduated();
    error NoFeesToClaim();
    error AlreadyGraduated();
    error GraduationConditionsNotMet();
    error NoTokensToSeed();
    error NoUsdcToSeed();
    error InsufficientUsdcLiquidity();

    // =========================================================
    // TOKENS
    // =========================================================

    IERC20 public immutable token;
    IERC20 public immutable usdc;

    // =========================================================
    // VIRTUAL LIQUIDITY
    // =========================================================

    uint256 public virtualTokenReserve; // updated on every trade
    uint256 public virtualUsdcReserve; // updated on every trade
    uint256 public immutable k; // constant product, fixed at deploy

    // =========================================================
    // REAL STATE
    // =========================================================

    uint256 public reserveToken; // curve tokens still for sale
    uint256 public reserveUsdc; // USDC collected
    uint256 public tokensSold;

    // =========================================================
    // AMM SEED RESERVE  (FIX 7: tokens held back for the AMM pool)
    // =========================================================

    uint256 public immutable ammReserveTokens;

    // =========================================================
    // GRADUATION
    // =========================================================

    uint256 public immutable graduationThreshold;
    uint256 public immutable graduationUsdcTarget;

    bool public graduated;
    bool public pendingGraduation; // retains storage slot; always false after auto-graduation
    bool public initialized;

    IRepAMM public immutable repAmm;

    // =========================================================
    // FEE ACCOUNTING
    // =========================================================

    /// @notice Accumulated protocol fees in USDC (from buys).
    uint256 public accruedFeesUsdc;

    /// @notice Accumulated protocol fees in token (from sells).
    uint256 public accruedFeesToken;

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
    // TOKENS TYPE
    // =========================================================
    string public tokenType;

    // =========================================================
    // EVENTS
    // =========================================================

    event CurveInitialized(uint256 curveSupply);
    event Buy(
        address indexed user,
        uint256 indexed totalToken,
        uint256 indexed totalUsdc,
        uint256 usdcIn,
        uint256 tokensOut,
        uint256 feePaid,
        uint256 feeBps,
        uint256 nowPrice,
        address tokenAddress,
        string tokenType
    );
    event Sell(
        address indexed user,
        uint256 indexed totalToken,
        uint256 indexed totalUsdc,
        uint256 tokensIn,
        uint256 usdcOut,
        uint256 feePaid,
        uint256 feeBps,
        uint256 nowPrice,
        address tokenAddress,
        string tokenType
    );
    event GraduationPending(
        uint256 tokensSold,
        uint256 usdcRaised,
        address tokenAddress
    );
    event Graduated(
        uint256 tokensSold,
        uint256 usdcSeeded,
        uint256 tokensSeeded,
        address tokenAddress
    );
    event FeesClaimed(uint256 usdcFees, uint256 tokenFees);

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(
        address _token,
        address _usdc,
        uint256 _virtualTokenReserve,
        uint256 _virtualUsdcReserve,
        uint256 _graduationThreshold,
        uint256 _graduationUsdcTarget,
        address _repAmm,
        uint256 _ammReserveTokens,
        string memory _tokenType
    ) Ownable(msg.sender) {
        if (
            _token == address(0) || _usdc == address(0) || _repAmm == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_virtualTokenReserve == 0 || _virtualUsdcReserve == 0) {
            revert ZeroReserve();
        }
        if (_graduationThreshold == 0) {
            revert ZeroThreshold();
        }
        if (_graduationUsdcTarget == 0) {
            revert ZeroTarget();
        }

        token = IERC20(_token);
        usdc = IERC20(_usdc);
        repAmm = IRepAMM(_repAmm);

        virtualTokenReserve = _virtualTokenReserve;
        virtualUsdcReserve = _virtualUsdcReserve;
        k = _virtualTokenReserve * _virtualUsdcReserve;

        graduationThreshold = _graduationThreshold;
        graduationUsdcTarget = _graduationUsdcTarget;
        ammReserveTokens = _ammReserveTokens;

        tokenType = _tokenType;
    }

    // =========================================================
    // INITIALIZE CURVE SUPPLY  (onlyOwner, one-shot)
    // =========================================================

    function initializeCurveSupply(uint256 _curveSupply) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        if (_curveSupply == 0) revert ZeroSupply();

        reserveToken = _curveSupply;
        initialized = true;

        emit CurveInitialized(_curveSupply);
    }

    // =========================================================
    // SPOT PRICE
    // =========================================================

    function getPrice() public view returns (uint256) {
        return (virtualUsdcReserve * 1e22) / virtualTokenReserve; // divide by 10_000 * 10_000 to get the actuas usd amount
    }

    // =========================================================
    // QUOTE HELPERS
    // =========================================================

    /// @notice Tokens received for a given usdcIn.
    function quoteTokensOut(uint256 usdcIn) public view returns (uint256) {
        if (usdcIn == 0) revert ZeroInput();
        uint256 newVirtualUsdc = virtualUsdcReserve + usdcIn;
        uint256 newVirtualToken = k / newVirtualUsdc;
        return virtualTokenReserve - newVirtualToken;
    }

    /// @notice USDC received for a given tokensIn.
    function quoteUsdcOut(uint256 tokensIn) public view returns (uint256) {
        if (tokensIn == 0) revert ZeroInput();
        uint256 newVirtualToken = virtualTokenReserve + tokensIn;
        uint256 newVirtualUsdc = k / newVirtualToken;
        return virtualUsdcReserve - newVirtualUsdc;
    }

    // =========================================================
    // DYNAMIC FEE CALCULATION
    // =========================================================

    /**
     * @notice Returns the fee tier in basis points for a trade.
     *         Impact = inputAmount / inputReserve, expressed in bps.
     *         Larger trades pay proportionally more.
     *
     * @param  inputAmount   Raw amount being traded (before fee).
     * @param  inputReserve  Virtual reserve of the input side.
     */
    function getDynamicFeeBps(
        uint256 inputAmount,
        uint256 inputReserve
    ) public pure returns (uint256 feeBps) {
        if (inputReserve == 0) revert EmptyReserve();

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
    // BUY
    // =========================================================

    function buy(
        uint256 usdcIn
    ) external nonReentrant returns (uint256 tokensOut) {
        if (!initialized) revert NotInitialized();
        if (graduated) revert MarketGraduated();
        if (usdcIn == 0) revert ZeroInput();

        usdc.transferFrom(msg.sender, address(this), usdcIn);
        uint256 nowPrice = getPrice();

        // ── Dynamic fee on gross input ────────────────────────
        // Fee is measured against virtualUsdcReserve (the input-side reserve).
        // It is deducted before the AMM formula so the curve sees a smaller
        // input — fee does NOT go into the virtual reserves.
        uint256 feeBps = getDynamicFeeBps(usdcIn, virtualUsdcReserve);
        uint256 feeAmount = (usdcIn * feeBps) / BPS_DENOM;
        uint256 usdcNet = usdcIn - feeAmount;

        accruedFeesUsdc += feeAmount;

        tokensOut = quoteTokensOut(usdcNet);

        // ─────────────────────────────────────────────────────
        // PARTIAL FILL — cap at available curve supply
        // ─────────────────────────────────────────────────────
        if (tokensOut >= reserveToken) {
            uint256 filled = reserveToken;

            // Exact net USDC needed for `filled` tokens via inverse AMM
            uint256 usdcNetNeeded = (k / (virtualTokenReserve - filled)) -
                virtualUsdcReserve;
            uint256 usdcNetRefund = usdcNet - usdcNetNeeded;

            virtualUsdcReserve += usdcNetNeeded;
            virtualTokenReserve -= filled;

            reserveToken = 0;
            reserveUsdc += usdcNetNeeded;
            tokensSold += filled;

            token.transfer(msg.sender, filled);

            // Refund only the unused NET usdc (fee on the used portion is kept)
            if (usdcNetRefund > 0) {
                usdc.transfer(msg.sender, usdcNetRefund);
            }

            emit Buy(
                msg.sender,
                virtualTokenReserve,
                virtualUsdcReserve,
                usdcNetNeeded + feeAmount,
                filled,
                feeAmount,
                feeBps,
                nowPrice,
                address(token),
                tokenType
            );
            _checkGraduation();
            return filled;
        }

        // ─────────────────────────────────────────────────────
        // NORMAL BUY
        // ─────────────────────────────────────────────────────
        virtualUsdcReserve += usdcNet;
        virtualTokenReserve -= tokensOut;

        reserveToken -= tokensOut;
        reserveUsdc += usdcNet;
        tokensSold += tokensOut;

        token.transfer(msg.sender, tokensOut);

        emit Buy(
            msg.sender,
            virtualTokenReserve,
            virtualUsdcReserve,
            usdcIn,
            tokensOut,
            feeAmount,
            feeBps,
            nowPrice,
            address(token),
            tokenType
        );
        _checkGraduation();

        return tokensOut;
    }

    // =========================================================
    // SELL
    // =========================================================

    function sell(
        uint256 tokenIn
    ) external nonReentrant returns (uint256 usdcOut) {
        if (!initialized) revert NotInitialized();
        if (graduated) revert MarketGraduated();
        if (tokenIn == 0) revert ZeroInput();

        token.transferFrom(msg.sender, address(this), tokenIn);
        uint256 nowPrice = getPrice();

        // ── Dynamic fee on gross input ────────────────────────
        // Fee is measured against virtualTokenReserve (the input-side reserve).
        // Deducted before the AMM formula — fee tokens do NOT enter the curve.
        uint256 feeBps = getDynamicFeeBps(tokenIn, virtualTokenReserve);
        uint256 feeAmount = (tokenIn * feeBps) / BPS_DENOM;
        uint256 tokenNet = tokenIn - feeAmount;

        accruedFeesToken += feeAmount;

        usdcOut = quoteUsdcOut(tokenNet);

        if (usdcOut > reserveUsdc) revert InsufficientUsdcLiquidity();

        virtualTokenReserve += tokenNet;
        virtualUsdcReserve -= usdcOut;

        reserveToken += tokenNet;
        reserveUsdc -= usdcOut;
        tokensSold -= tokenNet;

        usdc.transfer(msg.sender, usdcOut);

        emit Sell(
            msg.sender,
            virtualTokenReserve,
            virtualUsdcReserve,
            tokenIn,
            usdcOut,
            feeAmount,
            feeBps,
            nowPrice,
            address(token),
            tokenType
        );
    }

    // =========================================================
    // GRADUATION — automatic, fires inside the triggering buy()
    // =========================================================

    /**
     * @dev  Called at the end of every buy().
     *       If graduation conditions are met, seeds the RepAMM immediately
     *       in the same transaction — no manual follow-up needed.
     *
     *       Safety order (checks-effects-interactions):
     *         1. Condition check     — read-only
     *         2. graduated = true    — state update
     *         3. reserves zeroed     — state update
     *         4. approve + seed      — external calls (after all state is safe)
     */
    function _checkGraduation() internal {
        if (
            !graduated &&
            (tokensSold >= graduationThreshold || reserveToken == 0) &&
            reserveUsdc >= graduationUsdcTarget
        ) {
            _executeGraduation();
        }
    }

    function _executeGraduation() internal {
        uint256 tokenToSeed = reserveToken + ammReserveTokens;
        uint256 usdcToSeed = reserveUsdc;

        if (tokenToSeed == 0) revert NoTokensToSeed();
        if (usdcToSeed == 0) revert NoUsdcToSeed();

        // ── Zero state BEFORE any external call ──────────────
        graduated = true;
        pendingGraduation = false;
        reserveToken = 0;
        reserveUsdc = 0;

        // ── Approve then seed ─────────────────────────────────
        token.approve(address(repAmm), tokenToSeed);
        usdc.approve(address(repAmm), usdcToSeed);

        repAmm.seedLiquidity(tokenToSeed, usdcToSeed);

        emit Graduated(tokensSold, usdcToSeed, tokenToSeed, address(token));
    }

    // =========================================================
    // GRADUATION FALLBACK — public safety hatch
    // =========================================================

    /**
     * @notice Manual fallback in case _checkGraduation() somehow did not fire
     *         (e.g. the RepAMM was temporarily broken and the auto-path
     *         reverted inside buy()). Callable by anyone.
     *
     *         Under normal operation this function is never needed.
     */
    function finalizeGraduation() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (
            (tokensSold < graduationThreshold && reserveToken != 0) ||
            reserveUsdc < graduationUsdcTarget
        ) {
            revert GraduationConditionsNotMet();
        }

        _executeGraduation();
    }

    // =========================================================
    // CLAIM FEES  (owner only)
    // =========================================================

    /**
     * @notice Withdraws all accumulated protocol fees to the owner.
     *         USDC fees come from buys; token fees come from sells.
     */
    function claimFees() external onlyOwner nonReentrant {
        uint256 usdcFees = accruedFeesUsdc;
        uint256 tokenFees = accruedFeesToken;

        if (usdcFees == 0 && tokenFees == 0) revert NoFeesToClaim();

        accruedFeesUsdc = 0;
        accruedFeesToken = 0;

        if (usdcFees > 0) usdc.transfer(msg.sender, usdcFees);
        if (tokenFees > 0) token.transfer(msg.sender, tokenFees);

        emit FeesClaimed(usdcFees, tokenFees);
    }

    // =========================================================
    // VIEW HELPERS
    // =========================================================

    function getReserves()
        external
        view
        returns (uint256 tokenReserve, uint256 usdcReserve)
    {
        return (reserveToken, reserveUsdc);
    }

    function getState()
        external
        view
        returns (bool isGraduated, bool isPending, uint256 sold)
    {
        return (graduated, pendingGraduation, tokensSold);
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
    ) external view returns (uint256 feeBps, uint256 feeAmount) {
        if (!initialized) revert NotInitialized();
        if (inputAmount == 0) revert ZeroInput();
        uint256 inputReserve = isBuy ? virtualUsdcReserve : virtualTokenReserve;
        feeBps = getDynamicFeeBps(inputAmount, inputReserve);
        feeAmount = (inputAmount * feeBps) / BPS_DENOM;
    }
}
