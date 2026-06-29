// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {REPToken} from "../src/REPToken.sol";

contract REPTokenTest is Test {
    // =========================================================
    // STATE
    // =========================================================

    REPToken public repToken;

    address public treasury = makeAddr("treasury");
    address public user = makeAddr("user");
    address public stranger = makeAddr("stranger");

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    // =========================================================
    // SETUP
    // =========================================================

    function setUp() public {
        repToken = new REPToken(
            "Reputation Token",
            "REP",
            TOTAL_SUPPLY,
            treasury
        );
    }

    // =========================================================
    // DEPLOYMENT
    // =========================================================

    function test_Name() public view {
        assertEq(repToken.name(), "Reputation Token");
    }

    function test_Symbol() public view {
        assertEq(repToken.symbol(), "REP");
    }

    function test_Decimals() public view {
        assertEq(repToken.decimals(), 18);
    }

    function test_TotalSupplyMintedToTreasury() public view {
        assertEq(repToken.totalSupply(), TOTAL_SUPPLY);
        assertEq(repToken.balanceOf(treasury), TOTAL_SUPPLY);
    }

    function test_OwnerIsDeployer() public view {
        // The deployer of this test contract becomes the owner
        assertEq(repToken.owner(), address(this));
    }

    // =========================================================
    // MINT
    // =========================================================

    function test_Mint_OwnerCanMint() public {
        uint256 amount = 1_000 ether;
        repToken.mint(user, amount);
        assertEq(repToken.balanceOf(user), amount);
        assertEq(repToken.totalSupply(), TOTAL_SUPPLY + amount);
    }

    function test_Revert_Mint_NonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        repToken.mint(user, 1_000 ether);
    }

    function test_Mint_ToZeroAddress_Reverts() public {
        vm.expectRevert();
        repToken.mint(address(0), 1_000 ether);
    }

    // =========================================================
    // BURN
    // =========================================================

    function test_Burn_OwnerCanBurn() public {
        uint256 burnAmount = 500_000 ether;
        repToken.burn(treasury, burnAmount);
        assertEq(repToken.balanceOf(treasury), TOTAL_SUPPLY - burnAmount);
        assertEq(repToken.totalSupply(), TOTAL_SUPPLY - burnAmount);
    }

    function test_Revert_Burn_NonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        repToken.burn(treasury, 1_000 ether);
    }

    function test_Burn_MoreThanBalance_Reverts() public {
        vm.expectRevert();
        repToken.burn(user, 1 ether); // user has 0 balance
    }

    // =========================================================
    // ERC20 STANDARD BEHAVIOUR
    // =========================================================

    function test_Transfer() public {
        uint256 amount = 100 ether;
        vm.prank(treasury);
        repToken.transfer(user, amount);
        assertEq(repToken.balanceOf(user), amount);
        assertEq(repToken.balanceOf(treasury), TOTAL_SUPPLY - amount);
    }

    function test_Approve_And_TransferFrom() public {
        uint256 amount = 200 ether;
        vm.prank(treasury);
        repToken.approve(user, amount);

        vm.prank(user);
        repToken.transferFrom(treasury, stranger, amount);

        assertEq(repToken.balanceOf(stranger), amount);
    }

    // =========================================================
    // FUZZ
    // =========================================================

    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount < type(uint128).max); // prevent totalSupply overflow

        // 1. Snapshot the wallet's starting balance (0 for strangers, 1B for treasury)
        uint256 balanceBefore = repToken.balanceOf(to);

        repToken.mint(to, amount);

        // 2. Check that the balance increased by exactly the minted amount
        assertEq(repToken.balanceOf(to), balanceBefore + amount);
    }
}
