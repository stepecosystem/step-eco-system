// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

/// @notice Test-only stand-in for StepClub. Implements the full surface that the
///         DEX and StepNet invoke on the club treasury so value/sync paths don't
///         revert in unit tests. NOT deployed to mainnet.
contract MockClub {
    uint256 public totalNotified;   // from DEX buys
    uint256 public totalReceived;   // from StepNet activations
    mapping(address => bool) public members;

    // ── called by StepDex ────────────────────────────────────────────────────
    function notifyStepClubDeposit(uint256 amount) external { totalNotified += amount; }

    // ── called by StepNet (IStepClub) ────────────────────────────────────────
    function receiveForPool(uint256 amount) external { totalReceived += amount; }
    function addMember(address ua) external { members[ua] = true; }
    function transferMembership(address, address) external {}
    function importMember(address, uint256, uint256) external {}
    function exitForUser(address ua) external { members[ua] = false; }
    function isMember(address ua) external view returns (bool) { return members[ua]; }
    function setClubHistory(address, uint256, uint256) external {}
}
