// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

/// @notice Test-only stand-in for StepNet/StepNetView as seen by StepRegistry
///         (the IStepNetDAO surface). Lets unit tests drive the governance
///         flow — box-0 counts, vote weights, eligibility, start timestamps —
///         without deploying the full StepNet + libraries. NOT for mainnet.
contract MockDAO {
    uint256 public activeBox0Count;
    mapping(address => uint256) public weakerSide;
    mapping(address => uint256) public totalWeaker;
    mapping(address => bool) public box0;
    mapping(address => bool) public box5;
    mapping(address => uint256) public startTs;

    // ── IStepNetDAO ──────────────────────────────────────────────────────────
    function getActiveBox0Count() external view returns (uint256) {
        return activeBox0Count;
    }

    function getBox0WeakerSide(address u) external view returns (uint256) {
        return weakerSide[u];
    }

    function hasBox0(address u) external view returns (bool) {
        return box0[u];
    }

    function hasBox5(address u) external view returns (bool) {
        return box5[u];
    }

    function getTotalWeakerSide(address u) external view returns (uint256) {
        return totalWeaker[u];
    }

    function getUserStartTimestamp(address u) external view returns (uint256) {
        return startTs[u];
    }

    // ── test setters ───────────────────────────────────────────────────────────
    function setActiveBox0Count(uint256 n) external { activeBox0Count = n; }

    /// @notice Register a voter: box-0 member, a weaker-side weight, and a start
    ///         timestamp (must predate proposal creation to be eligible).
    function setVoter(address u, uint256 weaker, uint256 ts) external {
        box0[u] = true;
        weakerSide[u] = weaker;
        startTs[u] = ts;
    }

    function setBox5(address u, bool v) external { box5[u] = v; }
    function setBox0(address u, bool v) external { box0[u] = v; }
}
