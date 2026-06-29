// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {RepFactory} from "../src/RepFactory.sol";

contract Deploy is Script {
    RepFactory public factory;

    // =========================================================
    // MAIN ENTRY POINT
    // =========================================================

    function run(address usdcAddress) public {
        require(usdcAddress != address(0), "Deploy: zero USDC address");

        address deployer = msg.sender;

        console2.log("=================================================");
        console2.log("  Rep Market System Deployment");
        console2.log("=================================================");
        console2.log("Deployer :", deployer);
        console2.log("USDC     :", usdcAddress);
        console2.log("Chain ID :", block.chainid);
        console2.log("-------------------------------------------------");

        // Open a single clean broadcasting window
        vm.startBroadcast();

        // 1. Deploy RepFactory
        factory = new RepFactory();
        console2.log("RepFactory deployed  :", address(factory));

        vm.stopBroadcast();

        console2.log("=================================================");
        console2.log("  Deployment Completed Successfully!");
        console2.log("=================================================");
    }

    // =========================================================
    // DEPLOY MOCK USDC (testnet only helper)
    // =========================================================

    function runWithMockUsdc() external {
        // 1. Open broadcast to deploy Mock USDC
        vm.startBroadcast();

        MockUSDCDeploy mockUsdc = new MockUSDCDeploy();
        console2.log("MockUSDC deployed     :", address(mockUsdc));

        // 2. Close broadcast before handing off execution
        vm.stopBroadcast();

        // 3. Forward the newly deployed Mock USDC address to the main deploy sequence
        run(address(mockUsdc));
    }
}

// =========================================================
// MINIMAL MOCK USDC — included directly for testnet convenience
// =========================================================

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDCDeploy is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
