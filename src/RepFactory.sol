// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =========================================================
// IMPORTS
// =========================================================

import {REPToken} from "./REPToken.sol";
import {RepAMM} from "./RepAMM.sol";
import {BondingCurveMarket} from "./BondingCurveMarket.sol";

/**
 * @title  RepFactory
 * @notice Deploys a (REPToken → BondingCurveMarket → RepAMM) stack in one
 *         transaction and wires all three contracts together.
 *
 *         Deployment order per market
 *         ────────────────────────────
 *         1. Deploy REPToken (mints totalSupply to factory).
 *         2. Deploy RepAMM   (token + usdc; not live yet).
 *         3. Deploy BondingCurveMarket (repAmm address baked in).
 *         4. repAmm.setBondingCurve(address(bcm))  — wires the pair.
 *         5. Transfer totalSupply tokens to BondingCurveMarket
 *            (= curveSupply for sale  +  ammReserveTokens held back).
 *         6. bcm.initializeCurveSupply(curveSupply) — activates the curve.
 */
contract RepFactory {
    // =========================================================
    // ERROR
    // =========================================================
    error NotOwner();

    // =========================================================
    // STATE
    // =========================================================

    address public owner;

    enum TokenType {
        REP,
        CRED
    }

    struct MarketInfo {
        address token;
        address market;
        address amm; // RepAMM address
        // string name;
        // string symbol;
        TokenType tokenType;
        uint256 createdAt;
    }

    MarketInfo[] public allMarkets;

    mapping(address => MarketInfo) public marketByToken;

    address[] public repTokens;
    address[] public credTokens;
    address[] public repMarkets;
    address[] public credMarkets;

    // =========================================================
    // EVENTS
    // =========================================================

    event MarketCreated(
        address indexed token,
        address indexed market,
        address indexed amm,
        string marketType,
        string name,
        string symbol
    );

    // =========================================================
    // MODIFIERS
    // =========================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor() {
        owner = msg.sender;
    }

    // =========================================================
    // CREATE REP MARKET
    // =========================================================

    function createRepToken(
        string memory name,
        string memory symbol,
        address usdcToken
    )
        external
        onlyOwner
        returns (address tokenAddr, address poolAddr, address ammAddr)
    {
        // ── 1. Deploy REP token ───────────────────────────────
        REPToken rep = new REPToken(
            name,
            symbol,
            1_000_000_000 ether,
            address(this)
        );

        // ── 2. Deploy AMM ─────────────────────────────────────
        RepAMM amm = new RepAMM(address(rep), usdcToken, "REP");

        // ── 3. Deploy Bonding Curve ───────────────────────────
        BondingCurveMarket bcm = new BondingCurveMarket(
            address(rep),
            usdcToken,
            1_103_480_000 ether, // virtualTokenReserve (Your current virtualToken)
            110_348 * 1e6, // virtualUsdcReserve (Your current virtualUsdc)
            765_565_509 ether, // graduationThreshold
            250_000 * 1e6, // graduationUsdTarget ($250,000 USDC)
            address(amm),
            234_434_491 ether, // ammReserveTokens
            "REP"
        );

        // ── 4. Wire ───────────────────────────────────────────
        amm.setBondingCurve(address(bcm));

        // ── 5. Transfer supply ────────────────────────────────
        rep.transfer(address(bcm), 1_000_000_000 ether);

        // ── 6. Activate curve ─────────────────────────────────
        bcm.initializeCurveSupply(765_565_509 ether);

        // ── Store ─────────────────────────────────────────────
        MarketInfo memory info;

        info.token = address(rep);
        info.market = address(bcm);
        info.amm = address(amm);
        // info.name = name;
        // info.symbol = symbol;
        info.tokenType = TokenType.REP;
        info.createdAt = block.timestamp;

        allMarkets.push(info);

        marketByToken[address(rep)] = info;

        repTokens.push(address(rep));
        repMarkets.push(address(bcm));

        emit MarketCreated(
            address(rep),
            address(bcm),
            address(amm),
            "REP",
            name,
            symbol
        );

        return (address(rep), address(bcm), address(amm));
    }

    // =========================================================
    // CREATE CRED MARKET
    // =========================================================

    function createCredToken(
        string memory name,
        string memory symbol,
        address usdcToken
    )
        external
        onlyOwner
        returns (address tokenAddr, address poolAddr, address ammAddr)
    {
        // ── 1. Deploy token ───────────────────────────────────
        REPToken cred = new REPToken(
            name,
            symbol,
            1_000_000_000 ether,
            address(this)
        );

        // ── 2. Deploy AMM ─────────────────────────────────────
        RepAMM amm = new RepAMM(address(cred), usdcToken, "CRED");

        // ── 3. Deploy Bonding Curve ───────────────────────────
        BondingCurveMarket bcm = new BondingCurveMarket(
            address(cred),
            usdcToken,
            1_073_000_000 ether, // virtualTokenReserve (Your current virtualToken)
            4_500 * 1e6, // virtualUsdcReserve (Your current virtualUsdc)
            793_086_957 ether, // graduationThreshold
            12_750 * 1e6, // graduationUsdTarget ($250,000 USDC)
            address(amm),
            206_913_043 ether, // ammReserveTokens
            "CRED"
        );

        // ── 4. Wire ───────────────────────────────────────────
        amm.setBondingCurve(address(bcm));

        // ── 5. Transfer supply ────────────────────────────────
        cred.transfer(address(bcm), 1_000_000_000 ether);

        // ── 6. Activate curve ─────────────────────────────────
        bcm.initializeCurveSupply(793_086_957 ether);

        // ── Store ─────────────────────────────────────────────
        MarketInfo memory info;

        info.token = address(cred);
        info.market = address(bcm);
        info.amm = address(amm);
        // info.name = name;
        // info.symbol = symbol;
        info.tokenType = TokenType.CRED;
        info.createdAt = block.timestamp;

        allMarkets.push(info);

        marketByToken[address(cred)] = info;
        credTokens.push(address(cred));
        credMarkets.push(address(bcm));

        emit MarketCreated(
            address(cred),
            address(bcm),
            address(amm),
            "CRED",
            name,
            symbol
        );

        return (address(cred), address(bcm), address(amm));
    }

    // =========================================================
    // VIEWS
    // =========================================================

    function getAllMarkets() external view returns (MarketInfo[] memory) {
        return allMarkets;
    }
    function getRepMarkets() external view returns (address[] memory) {
        return repMarkets;
    }
    function getCredMarkets() external view returns (address[] memory) {
        return credMarkets;
    }
    function totalMarkets() external view returns (uint256) {
        return allMarkets.length;
    }
    function totalRepMarkets() external view returns (uint256) {
        return repMarkets.length;
    }
    function totalCredMarkets() external view returns (uint256) {
        return credMarkets.length;
    }

    // =========================================================
    // MANUAL GETTERS
    // =========================================================

    function getMarketByToken(
        address token
    ) external view returns (MarketInfo memory) {
        return marketByToken[token];
    }
}
