// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

/// @notice Test-only stand-in for StepNFTTreasury — only the callback StepNet
///         uses during activation (`addToRewardPool`). NOT for mainnet.
contract MockNFT {
    uint256 public rewardPool;

    function addToRewardPool(uint256 amount) external { rewardPool += amount; }
}
