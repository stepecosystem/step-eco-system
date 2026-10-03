// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * A stand-in for the two contracts StepSubscription pays into.
 *
 * StepSubscription's revenue split does not merely `transfer` to the club and the NFT fund — it
 * `forceApprove`s and then calls `donateToPool(uint256)` / `depositSplit(uint256)`, so those two
 * legs only work if the receiver PULLS. A mock that just accepts a transfer would pass a test that
 * the real wiring fails, which is the opposite of useful.
 *
 * So this pulls, exactly as StepClub and StepNFTFund do, and records the amount it actually
 * received — the balance delta, not the number it was asked for. STEP burns a 2% levy on every
 * transfer out of a non-whitelisted sender, so "asked for" and "arrived" are different numbers and
 * the tests need to be able to see both.
 */
contract MockSplitSink {
    using SafeERC20 for IERC20;

    IERC20 public immutable STEP;

    /// @notice Sum of the amounts this sink was ASKED to take.
    uint256 public totalRequested;
    /// @notice Sum of what actually ARRIVED, after the transfer levy.
    uint256 public totalReceived;
    /// @notice How many times it was called, so a silently-skipped leg is visible.
    uint256 public calls;

    constructor(address step_) {
        STEP = IERC20(step_);
    }

    function _pull(uint256 amount) internal {
        uint256 before_ = STEP.balanceOf(address(this));
        STEP.safeTransferFrom(msg.sender, address(this), amount);
        totalRequested += amount;
        totalReceived  += STEP.balanceOf(address(this)) - before_;
        calls          += 1;
    }

    /// @dev StepSubscription's club leg — approve-then-call, so this PULLS.
    function donateToPool(uint256 amount) external { _pull(amount); }

    /// @dev StepSubscription's NFT-fund leg — also a pull.
    function depositSplit(uint256 amount) external { _pull(amount); }

    /**
     * @dev StepDex's club leg, which is a NOTIFICATION, not a pull: the DEX transfers the STEP
     *      first and then tells the club how much arrived. Pulling here would double-charge and,
     *      more usefully for a test, reverting here breaks every buy on the AMM — which is exactly
     *      what happened the first time this mock replaced the club in the registry and only
     *      implemented the two subscription entry points.
     */
    uint256 public totalNotified;
    function notifyStepClubDeposit(uint256 amount) external { totalNotified += amount; }

    /// @dev The other shape StepNet uses to move STEP into the club pool.
    uint256 public totalPooled;
    function receiveForPool(uint256 amount) external { totalPooled += amount; }
}
