// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal USDC mock — 6 decimals, free mint for tests.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint any amount to any address — test use only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
