// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RepFactory} from "../src/RepFactory.sol";
import {REPToken} from "../src/REPToken.sol";
import {BondingCurveMarket} from "../src/BondingCurveMarket.sol";
import {RepAMM} from "../src/RepAMM.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract RepFactoryTest is Test {
    // =========================================================
    // CONTRACTS
    // =========================================================

    RepFactory public factory;
    MockUSDC public usdc;

    // =========================================================
    // ACTORS
    // =========================================================

    address owner = address(this);
    address stranger = makeAddr("stranger");

    // =========================================================
    // SETUP
    // =========================================================

    function setUp() public {
        usdc = new MockUSDC();
        factory = new RepFactory();
    }

    // =========================================================
    // HELPERS
    // =========================================================

    function _createRepMarket()
        internal
        returns (address tokenAddr, address poolAddr, address ammAddr)
    {
        return factory.createRepToken("Kanye West", "KANYE", address(usdc));
    }

    function _createCredMarket()
        internal
        returns (address tokenAddr, address poolAddr, address ammAddr)
    {
        return
            factory.createCredToken("Lagos Hustle Cred", "LHC", address(usdc));
    }

    // =========================================================
    // ACCESS CONTROL
    // =========================================================

    function test_CreateRepToken_Revert_NonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(RepFactory.NotOwner.selector);
        factory.createRepToken("X", "X", address(usdc));
    }

    function test_CreateCredToken_Revert_NonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(RepFactory.NotOwner.selector);
        factory.createCredToken("Y", "Y", address(usdc));
    }

    // =========================================================
    // REP MARKET DEPLOYMENT
    // =========================================================

    function test_CreateRepToken_ReturnsNonZeroAddresses() public {
        (address t, address p, address a) = _createRepMarket();
        assertTrue(t != address(0));
        assertTrue(p != address(0));
        assertTrue(a != address(0));
    }

    function test_CreateRepToken_ThreeDistinctAddresses() public {
        (address t, address p, address a) = _createRepMarket();
        assertTrue(t != p);
        assertTrue(t != a);
        assertTrue(p != a);
    }

    function test_CreateRepToken_TokenHasCorrectName() public {
        (address t, , ) = _createRepMarket();
        assertEq(REPToken(t).name(), "Kanye West");
        assertEq(REPToken(t).symbol(), "KANYE");
    }

    function test_CreateRepToken_BcmHoldsFullSupply() public {
        (address t, address p, ) = _createRepMarket();
        uint256 totalSupply = REPToken(t).totalSupply();
        assertEq(REPToken(t).balanceOf(p), totalSupply);
    }

    function test_CreateRepToken_BcmInitialized() public {
        (, address p, ) = _createRepMarket();
        assertTrue(BondingCurveMarket(p).initialized());
    }

    function test_CreateRepToken_CurveSupplySet() public {
        (, address p, ) = _createRepMarket();
        // curveSupply = 750_000_000 ether
        assertEq(BondingCurveMarket(p).reserveToken(), 765_565_509 ether);
    }

    function test_CreateRepToken_AmmWiredToBcm() public {
        (, address p, address a) = _createRepMarket();
        // RepAMM.bondingCurve should point to the BCM
        assertEq(RepAMM(a).bondingCurve(), p);
        assertTrue(RepAMM(a).bondingCurveSet());
    }

    function test_CreateRepToken_AmmNotYetInitialized() public {
        (, , address a) = _createRepMarket();
        // AMM should NOT be seeded yet — only after graduation
        assertFalse(RepAMM(a).initialized());
    }

    function test_CreateRepToken_BcmRepAmmAddressCorrect() public {
        (, address p, address a) = _createRepMarket();
        // BCM's repAmm must equal the deployed RepAMM
        assertEq(address(BondingCurveMarket(p).repAmm()), a);
    }

    function test_CreateRepToken_GraduationThresholdSet() public {
        (, address p, ) = _createRepMarket();
        uint256 threshold = BondingCurveMarket(p).graduationThreshold();
        assertEq(threshold, 765_565_509 ether); // == curveSupply
    }

    function test_CreateRepToken_GraduationUsdcTargetSet() public {
        (, address p, ) = _createRepMarket();
        uint256 target = BondingCurveMarket(p).graduationUsdcTarget();
        assertEq(target, 250_000 * 1e6);
    }

    // =========================================================
    // CRED MARKET DEPLOYMENT
    // =========================================================

    function test_CreateCredToken_ReturnsNonZeroAddresses() public {
        (address t, address p, address a) = _createCredMarket();
        assertTrue(t != address(0));
        assertTrue(p != address(0));
        assertTrue(a != address(0));
    }

    function test_CreateCredToken_CurveSupplyCorrect() public {
        (, address p, ) = _createCredMarket();
        assertEq(BondingCurveMarket(p).reserveToken(), 793_086_957 ether);
    }

    function test_CreateCredToken_GraduationUsdcTargetCorrect() public {
        (, address p, ) = _createCredMarket();
        assertEq(BondingCurveMarket(p).graduationUsdcTarget(), 12_750 * 1e6);
    }

    function test_CreateCredToken_AmmWiredCorrectly() public {
        (, address p, address a) = _createCredMarket();
        assertEq(RepAMM(a).bondingCurve(), p);
    }

    // =========================================================
    // MARKET REGISTRY
    // =========================================================

    function test_Registry_MarketCountIncreases() public {
        assertEq(factory.totalMarkets(), 0);
        _createRepMarket();
        assertEq(factory.totalMarkets(), 1);
        _createCredMarket();
        assertEq(factory.totalMarkets(), 2);
    }

    function test_Registry_RepMarketCountTracked() public {
        _createRepMarket();
        _createRepMarket();
        assertEq(factory.totalRepMarkets(), 2);
        assertEq(factory.totalCredMarkets(), 0);
    }

    function test_Registry_CredMarketCountTracked() public {
        _createCredMarket();
        assertEq(factory.totalCredMarkets(), 1);
        assertEq(factory.totalRepMarkets(), 0);
    }

    function test_Registry_GetAllMarkets() public {
        _createRepMarket();
        _createCredMarket();
        RepFactory.MarketInfo[] memory markets = factory.getAllMarkets();
        assertEq(markets.length, 2);
    }

    function test_Registry_MarketByToken() public {
        (address t, address p, address a) = _createRepMarket();
        RepFactory.MarketInfo memory info = factory.getMarketByToken(t);
        assertEq(info.token, t);
        assertEq(info.market, p);
        assertEq(info.amm, a);
        // assertEq(info.name, "Kanye West");
        // assertEq(info.symbol, "KANYE");
    }

    function test_Registry_RepTokenType() public {
        (address t, , ) = _createRepMarket();
        RepFactory.MarketInfo memory info = factory.getMarketByToken(t);
        assertEq(uint256(info.tokenType), uint256(RepFactory.TokenType.REP));
    }

    function test_Registry_CredTokenType() public {
        (address t, , ) = _createCredMarket();
        RepFactory.MarketInfo memory info = factory.getMarketByToken(t);
        assertEq(uint256(info.tokenType), uint256(RepFactory.TokenType.CRED));
    }

    function test_Registry_CreatedAtIsBlockTimestamp() public {
        uint256 ts = block.timestamp;
        (address t, , ) = _createRepMarket();
        RepFactory.MarketInfo memory info = factory.getMarketByToken(t);
        assertEq(info.createdAt, ts);
    }

    function test_Registry_GetRepMarkets() public {
        (, address p1, ) = _createRepMarket();
        (, address p2, ) = _createRepMarket();
        address[] memory markets = factory.getRepMarkets();
        assertEq(markets.length, 2);
        assertEq(markets[0], p1);
        assertEq(markets[1], p2);
    }

    function test_Registry_GetCredMarkets() public {
        (, address p, ) = _createCredMarket();
        address[] memory markets = factory.getCredMarkets();
        assertEq(markets.length, 1);
        assertEq(markets[0], p);
    }

    // =========================================================
    // EVENTS
    // =========================================================

    function test_Event_MarketCreated_EmittedForRep() public {
        vm.expectEmit(false, false, false, false); // just check it fires
        emit RepFactory.MarketCreated(
            address(0),
            address(0),
            address(0),
            "REP",
            "Kanye West",
            "KANYE"
        );
        _createRepMarket();
    }

    // =========================================================
    // INTEGRATION: BUY ON NEWLY DEPLOYED REP MARKET
    // =========================================================

    function test_Integration_BuyOnRepMarket() public {
        (, address p, ) = _createRepMarket();
        BondingCurveMarket bcm = BondingCurveMarket(p);
        address buyer = makeAddr("buyer");
        uint256 usdcIn = 100 * 1e6;

        usdc.mint(buyer, usdcIn);
        vm.prank(buyer);
        usdc.approve(p, usdcIn);
        vm.prank(buyer);
        uint256 tokensOut = bcm.buy(usdcIn);

        assertGt(tokensOut, 0);
        assertEq(REPToken(address(bcm.token())).balanceOf(buyer), tokensOut);
    }

    function test_Integration_BuyOnCredMarket() public {
        (, address p, ) = _createCredMarket();
        BondingCurveMarket bcm = BondingCurveMarket(p);
        address buyer = makeAddr("buyer");
        uint256 usdcIn = 50 * 1e6;

        usdc.mint(buyer, usdcIn);
        vm.prank(buyer);
        usdc.approve(p, usdcIn);
        vm.prank(buyer);
        uint256 tokensOut = bcm.buy(usdcIn);

        assertGt(tokensOut, 0);
    }

    // =========================================================
    // MULTIPLE MARKETS INDEPENDENCE
    // =========================================================

    function test_TwoRepMarkets_AreIndependent() public {
        (, address p1, ) = _createRepMarket();
        (, address p2, ) = factory.createRepToken(
            "Taylor Swift",
            "TAYLOR",
            address(usdc)
        );

        address buyer = makeAddr("buyer");
        usdc.mint(buyer, 200 * 1e6);
        vm.prank(buyer);
        usdc.approve(p1, 100 * 1e6);
        vm.prank(buyer);
        usdc.approve(p2, 100 * 1e6);

        vm.prank(buyer);
        uint256 out1 = BondingCurveMarket(p1).buy(100 * 1e6);
        vm.prank(buyer);
        uint256 out2 = BondingCurveMarket(p2).buy(100 * 1e6);

        // Both should give tokens; state of one doesn't affect the other
        assertGt(out1, 0);
        assertGt(out2, 0);
        assertEq(BondingCurveMarket(p1).tokensSold(), out1);
        assertEq(BondingCurveMarket(p2).tokensSold(), out2);
    }
}
