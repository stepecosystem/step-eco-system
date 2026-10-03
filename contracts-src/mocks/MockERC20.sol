// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only stand-in for DAI (18 decimals). NOT deployed to mainnet —
///         the production deploy uses canonical Polygon DAI (0x8f3Cf7ad…).
///         Lives under contracts-src/mocks/ so the Hardhat test harness can
///         compile it alongside the real contracts without polluting the
///         production set.
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
