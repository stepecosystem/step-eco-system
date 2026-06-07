// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStepRegistry {
    function get(bytes32 key) external view returns (address);
    function KEY_STEP_COIN()     external view returns (bytes32);
    function KEY_STEP_NET()      external view returns (bytes32);
    function KEY_NFT_TREASURY()  external view returns (bytes32);
    function KEY_STEP_DEX()      external view returns (bytes32);
}

interface IStepCoin is IERC20 {
    function burn(uint256 amount) external;
}

interface IStepDex {
    function getPrice() external view returns (uint256);
}

interface IStepNet {
    function addStepReceivedFromClub(address ua, uint256 amount) external;
    function addStepBurnedFromClub(address ua, uint256 amount) external;
    function setUserInClub(address ua, bool value) external;
    function getUserClubData(address ua) external view returns (
        uint256, uint256, uint256, uint256, bool, uint256
    );
}

interface IStepSubscription {
    /// @notice Grant subscription months funded by a member's forfeited club
    ///         cap-gap (DAI, 1e18). No payment. Returns the months granted.
    function grantFromClubExit(address user, uint256 gapDai) external returns (uint32);
}

/**
 * @title  StepClub
 * @notice Loyalty rewards module of the Step Ecosystem. Every Box-2-and-above
 *         subscriber is automatically enrolled in the Club. Membership lasts
 *         until the subscriber's cumulative earnings (boxes + club) reach
 *         their cap (`totalPaidAllBoxes`), at which point the contract
 *         auto-exits them.
 *
 *         Distribution is a two-phase, snapshot-based, resumable routine:
 *           Phase 0 — burn any expired pending claims (post-deadline).
 *           Phase 1 — allocate the current round's STEP pool evenly to all
 *                     pre-snapshot members; over-cap users are routed to
 *                     the deferred removal queue and their share returned
 *                     to the pool for the next round.
 *
 *         Engineered for safety under concurrent state changes:
 *           • `memberList.length` is snapshotted at phase start so newcomers
 *             arriving mid-distribution cannot be paid out of the current
 *             round; they sit in `pendingJoinQueue` until finalize.
 *           • Removals during distribution are deferred to
 *             `pendingRemovalQueue` to keep the iteration cursor valid.
 *           • Voluntary `exit()` virtually credits the gap to the cap so
 *             a subscriber cannot game by exit-and-rejoin to extract more
 *             than their lifetime entitlement.
 */
contract StepClub is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── ERRORS ──────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error NotAuthorized();
    error Unauthorized();
    error TooEarly();
    error NoPendingReward();
    error NothingToBurn();
    error AlreadyMember();
    error NotMember();
    error DistributionInProgress();
    error ZeroAmount();
    /// @notice Reverted by `processClubDistribution` when a call cannot advance
    ///         the distribution by even one batch (gas supplied is too low).
    ///         Reverting — rather than silently returning — keeps eth_estimateGas
    ///         from settling on the do-nothing path, so wallets/keepers auto-fund
    ///         enough gas and never mine a successful-but-empty distribution tx.
    ///         The economic result of any *completed* round is unaffected.
    error InsufficientGas();
    /// @notice Reverted by `transferMembership` when the destination
    ///         address already has Club history (received/burned STEP or
    ///         pending rewards). Prevents stripping that history via a
    ///         wallet change.
    error NewAddrHasHistory();

    // ─── CONSTANTS ───────────────────────────────────────────────────────────────
    uint256 public constant DISTRIBUTION_INTERVAL  = 30 days;
    uint256 public constant CLAIM_DEADLINE         = 10 days;
    uint256 public constant DIST_BATCH_SIZE        = 500;
    uint256 public constant JOIN_FLUSH_BATCH       = 200;   // bounded flush per finalize

    uint256 private constant STEP_TRANSFER_FEE_PCT = 2;
    uint256 private constant PERCENT_DENOMINATOR   = 100;

    // ─── STATE ───────────────────────────────────────────────────────────────────
    IStepRegistry public immutable REGISTRY;
    /// @notice StepSubscription contract that `exitToSubscription()` grants
    ///         through. Immutable — wired once at deploy, can never be repointed,
    ///         so the conversion path is trustless and needs no admin/setter.
    IStepSubscription public immutable SUBSCRIPTION;

    address[] public memberList;
    mapping(address => uint256) public memberIndex;
    mapping(address => bool)    public isMember;
    mapping(address => uint256) public pendingRewards;
    mapping(address => uint256) public totalReceivedStep;
    mapping(address => uint256) public totalBurnedStep;

    uint256 public memberCount;
    uint256 public roundCount;
    uint256 public livePool;
    uint256 public lastDistributionTime;
    uint256 public pendingBurnDeadline;

    uint256 public totalDonated;
    uint256 public totalPendingStep;

    bool    public distInProgress;
    uint256 public distCursor;
    uint256 public distPhase;
    uint256 public distAmountPerMember;

    /// @dev Snapshot of `memberList.length` at the start of each phase.
    ///      Bounds the iteration so newcomers cannot be over-paid.
    uint256 public distMemberSnapshot;
    /// @dev Newcomers added during an in-flight distribution. Flushed in
    ///      bounded batches when the distribution finalizes.
    address[] public pendingJoinQueue;
    mapping(address => bool) public inJoinQueue;

    /// @dev Removals encountered mid-distribution are queued here so the
    ///      iteration cursor stays valid. Applied at finalize.
    address[] public pendingRemovalQueue;
    mapping(address => bool) public inRemovalQueue;

    /// @dev Members removed at-cap while still holding an unclaimed pending
    ///      reward. Phase 0 only scans `memberList`, so without this queue a
    ///      removed member's leftover claim would be stranded forever — neither
    ///      paid nor burned. Their claim window is the same `pendingBurnDeadline`
    ///      of the round they left in; once it passes, the next distribution's
    ///      Phase 0 burns the leftover with full per-user cap attribution.
    ///      Drained LIFO (pop), so it is inherently resumable and gas-bounded.
    address[] public expiringPending;
    mapping(address => bool) public inExpiring;

    // ─── EVENTS ──────────────────────────────────────────────────────────────────
    event MemberAdded(address indexed ua);
    event MemberRemoved(address indexed ua);
    event MemberQueued(address indexed ua);                 // queued during an in-flight distribution
    event MembershipTransferred(address indexed oldAddr, address indexed newAddr);
    event PoolReceived(uint256 amount);
    event PoolDonated(address indexed donor, uint256 amount);
    event ClubDistributionStarted(uint256 round, uint256 amountPerMember);
    event ClubDistributionFinalized(uint256 round);
    event RewardClaimed(address indexed ua, uint256 amount);
    event RewardBurned(address indexed ua, uint256 amount);
    event AssetsMigrated(address indexed to, uint256 stepAmount);
    /// @notice Emitted when `exit()` virtually fills the caller's remaining
    ///         cap. Provides an on-chain trail of the virtual credit so
    ///         indexers can render correct "earned vs. cap" dashboards.
    event VoluntaryExitCapCredit(address indexed user, uint256 virtualStep, uint256 daiGap);
    /// @notice Emitted when a member voluntarily exits AND converts their whole
    ///         remaining cap-gap into free subscription months via StepSubscription.
    event ExitedToSubscription(address indexed user, uint256 daiGap, uint32 monthsGranted);
    /// @notice Emitted when a distribution call legitimately had nothing to do
    ///         (empty live pool / no members and no expired claims to burn).
    ///         Guarantees every keeper invocation leaves an on-chain trace, so a
    ///         "successful but silent" distribution can never be mistaken for a
    ///         missed round.
    event ClubDistributionSkipped(uint256 livePool, uint256 memberCount);
    /// @notice Emitted when an at-cap-removed member's still-claimable reward is
    ///         queued for the next post-deadline burn so it can never be stranded.
    event ExpiringPendingQueued(address indexed ua, uint256 amount);

    // ─── Constructor ───────────────────────────────────────────────────────
    constructor(address _registry, address _subscription) {
        if (_registry == address(0) || _subscription == address(0)) revert ZeroAddress();
        REGISTRY     = IStepRegistry(_registry);
        SUBSCRIPTION = IStepSubscription(_subscription);
        // `lastDistributionTime` is left at zero. The first
        // `processClubDistribution` call may run at any time after deploy;
        // the timer is then anchored to that first invocation.
    }

    // ─── Internal helpers ──────────────────────────────────────────────────
    function _step() internal view returns (IStepCoin) {
        return IStepCoin(REGISTRY.get(REGISTRY.KEY_STEP_COIN()));
    }
    function _stepNet() internal view returns (address) {
        return REGISTRY.get(REGISTRY.KEY_STEP_NET());
    }
    function _nftTreasury() internal view returns (address) {
        return REGISTRY.get(REGISTRY.KEY_NFT_TREASURY());
    }
    function _stepDex() internal view returns (address) {
        return REGISTRY.get(REGISTRY.KEY_STEP_DEX());
    }

    function _burnPending(address ua) internal {
        uint256 amt = pendingRewards[ua];
        if (amt == 0) return;
        totalPendingStep    -= amt;
        pendingRewards[ua]   = 0;
        totalBurnedStep[ua] += amt;
        _step().burn(amt);
        address snet = _stepNet();
        if (snet != address(0)) {
            IStepNet(snet).addStepBurnedFromClub(ua, amt);
        }
        emit RewardBurned(ua, amt);
    }

    function _burnPendingCached(address ua, IStepCoin step) internal {
        uint256 amt = pendingRewards[ua];
        if (amt == 0) return;
        totalPendingStep    -= amt;
        pendingRewards[ua]   = 0;
        totalBurnedStep[ua] += amt;
        step.burn(amt);
        address snet = _stepNet();
        if (snet != address(0)) {
            IStepNet(snet).addStepBurnedFromClub(ua, amt);
        }
        emit RewardBurned(ua, amt);
    }

    function _removeMemberInternal(address ua) internal {
        if (!isMember[ua]) return;

        // Removals during distribution are deferred so the iteration cursor
        // stays valid. The pending balance is zeroed immediately so the
        // removed subscriber is not double-paid in the same round.
        if (distInProgress) {
            totalPendingStep -= pendingRewards[ua];
            pendingRewards[ua] = 0;
            isMember[ua] = false; // distribute() skips this entry going forward
            if (!inRemovalQueue[ua]) {
                inRemovalQueue[ua] = true;
                pendingRemovalQueue.push(ua);
            }
            // memberCount is decremented in flushRemovalQueue, not here.
            return;
        }

        uint256 idx = memberIndex[ua];
        if (idx == 0) return;

        address lastUa = memberList[memberList.length - 1];
        memberList[idx - 1] = lastUa;
        memberIndex[lastUa] = idx;
        memberList.pop();
        memberIndex[ua] = 0;
        isMember[ua] = false;
        totalPendingStep -= pendingRewards[ua];
        pendingRewards[ua] = 0;
        memberCount--;
    }

    /// @dev Apply deferred removals (called at the end of a distribution,
    ///      or by any external keeper once a distribution has finalized).
    function _flushRemovalQueue() internal {
        uint256 len = pendingRemovalQueue.length;
        if (len == 0) return;
        // Bounded batch to keep this routine within sensible gas envelopes.
        uint256 toFlush = len > 200 ? 200 : len;
        for (uint256 i = 0; i < toFlush;) {
            address ua = pendingRemovalQueue[pendingRemovalQueue.length - 1];
            pendingRemovalQueue.pop();
            inRemovalQueue[ua] = false;

            // Skip if the subscriber re-joined in the meantime.
            if (isMember[ua]) {
                unchecked { ++i; }
                continue;
            }
            uint256 idx = memberIndex[ua];
            if (idx == 0) {
                unchecked { ++i; }
                continue;
            }
            address lastUa = memberList[memberList.length - 1];
            memberList[idx - 1] = lastUa;
            memberIndex[lastUa] = idx;
            memberList.pop();
            memberIndex[ua] = 0;
            memberCount--;
            unchecked { ++i; }
        }
    }

    /// @dev Burn the stranded leftovers of at-cap-removed members, with full
    ///      per-user cap attribution (identical to the in-list Phase-0 burn).
    ///      LIFO pop makes it inherently resumable; the gas guard guarantees it
    ///      never reverts mid-drain. Entries already claimed (pending == 0) pop
    ///      to a cheap no-op. The 1.5M reserve mirrors `_processBatch`, and the
    ///      caller (`processClubDistribution`) floors `safetyGas` above it so a
    ///      call that ENTERS always burns at least one entry — never spins.
    function _drainExpiringPending(IStepCoin step) internal {
        while (expiringPending.length > 0) {
            if (gasleft() < 1_500_000) return;
            address ua = expiringPending[expiringPending.length - 1];
            expiringPending.pop();
            inExpiring[ua] = false;
            _burnPendingCached(ua, step);
        }
    }

    function _claimReward(address ua) internal {
        uint256 amt = pendingRewards[ua];
        if (amt == 0) revert NoPendingReward();

        if (block.timestamp >= pendingBurnDeadline) {
            _burnPending(ua);
            return;
        }

        address snet       = _stepNet();
        uint256 stepToSend = amt;
        uint256 stepToBurn = 0;
        bool    shouldExit = false;

        if (snet != address(0)) {
            (
                uint256 totalPaid,
                /*totalCommDai*/,
                uint256 stepFromClub,
                uint256 stepBurnedClub,
                /* inStepClub */,
                uint256 stepEquivFromBoxes
            ) = IStepNet(snet).getUserClubData(ua);

            uint256 price = 0;
            address dex = _stepDex();
            if (dex != address(0)) {
                try IStepDex(dex).getPrice() returns (uint256 p) { price = p; } catch {}
            }

            if (price > 0 && totalPaid > 0) {
                uint256 clubStepUsd = ((stepFromClub + stepBurnedClub) * price) / 1e18;
                uint256 boxStepUsd  = (stepEquivFromBoxes * price) / 1e18;
                uint256 totalEarned = boxStepUsd + clubStepUsd;

                if (totalEarned >= totalPaid) {
                    _burnPending(ua);
                    _removeMemberInternal(ua);
                    IStepNet(snet).setUserInClub(ua, false);
                    emit MemberRemoved(ua);
                    return;
                }

                uint256 remainingUsd = totalPaid - totalEarned;
                uint256 maxStep = (remainingUsd * 1e18) / price;

                if (amt > maxStep) {
                    stepToSend = maxStep;
                    stepToBurn = amt - maxStep;
                    shouldExit = true;
                }
            }
        }

        IStepCoin step = _step();
        totalPendingStep -= amt;
        pendingRewards[ua] = 0;

        if (stepToSend > 0) {
            totalReceivedStep[ua] += stepToSend;
            if (snet != address(0)) IStepNet(snet).addStepReceivedFromClub(ua, stepToSend);
            SafeERC20.safeTransfer(IERC20(address(step)), ua, stepToSend);
            emit RewardClaimed(ua, stepToSend);
        }

        if (stepToBurn > 0) {
            totalBurnedStep[ua] += stepToBurn;
            step.burn(stepToBurn);
            if (snet != address(0)) IStepNet(snet).addStepBurnedFromClub(ua, stepToBurn);
            emit RewardBurned(ua, stepToBurn);
        }

        if (shouldExit) {
            _removeMemberInternal(ua);
            if (snet != address(0)) IStepNet(snet).setUserInClub(ua, false);
            emit MemberRemoved(ua);
        }
    }

    /// @dev One bounded batch of distribution work. Iterates up to
    ///      `min(distMemberSnapshot, memberList.length)`; per-member work
    ///      depends on the current phase:
    ///        Phase 0 — burn the member's expired pending claim.
    ///        Phase 1 — compute the cap-aware STEP allocation. If the
    ///                  member is already at or over cap, allocate 0 and
    ///                  enqueue for removal; if partially capped, allocate
    ///                  only up to the remaining DAI gap and refund the
    ///                  excess into `livePool` for the next round.
    function _processBatch() internal {
        uint256 start = distCursor;
        uint256 limit = distMemberSnapshot;
        uint256 currentLen = memberList.length;
        if (limit > currentLen) limit = currentLen;

        uint256 end = start + DIST_BATCH_SIZE;
        if (end > limit) end = limit;

        uint256 gasCheckInterval = 10;

        IStepCoin step = _step();

        uint256 cachedPrice = 0;
        address snet = address(0);
        if (distPhase == 1) {
            snet = _stepNet();
            address dex = _stepDex();
            if (dex != address(0)) {
                try IStepDex(dex).getPrice() returns (uint256 p) { cachedPrice = p; } catch {}
            }
        }

        uint256 returnedToPool = 0;

        for (uint256 i = start; i < end;) {
            address ua = memberList[i];
            if (isMember[ua]) {
                if (distPhase == 0) {
                    _burnPendingCached(ua, step);
                } else {
                    uint256 allocation = distAmountPerMember;
                    bool atCap = false;

                    if (cachedPrice > 0 && snet != address(0)) {
                        (
                            uint256 totalPaid,
                            /*totalCommDai*/,
                            uint256 stepFromClub,
                            uint256 stepBurnedClub,
                            /*inStepClub*/,
                            uint256 stepEquivFromBoxes
                        ) = IStepNet(snet).getUserClubData(ua);

                        if (totalPaid > 0) {
                            uint256 clubStepUsd = ((stepFromClub + stepBurnedClub) * cachedPrice) / 1e18;
                            uint256 boxStepUsd  = (stepEquivFromBoxes * cachedPrice) / 1e18;
                            uint256 totalEarned = boxStepUsd + clubStepUsd;

                            if (totalEarned >= totalPaid) {
                                allocation = 0;
                                atCap = true;
                                returnedToPool += distAmountPerMember;
                            } else {
                                uint256 remainingUsd = totalPaid - totalEarned;
                                uint256 maxStep = (remainingUsd * 1e18) / cachedPrice;
                                if (allocation > maxStep) {
                                    returnedToPool += allocation - maxStep;
                                    allocation = maxStep;
                                    atCap = true;
                                }
                            }
                        }
                    }

                    uint256 oldPending = pendingRewards[ua];
                    totalPendingStep = totalPendingStep - oldPending + allocation;
                    pendingRewards[ua] = allocation;

                    if (atCap) {
                        isMember[ua] = false;
                        if (!inRemovalQueue[ua]) {
                            inRemovalQueue[ua] = true;
                            pendingRemovalQueue.push(ua);
                        }
                        // A partially-capped member keeps a final claimable
                        // reward (allocation > 0) but leaves memberList, so a
                        // future Phase 0 — which only scans memberList — could
                        // never burn it if it goes unclaimed. Track it here so
                        // the leftover is always swept and never stranded.
                        if (allocation > 0 && !inExpiring[ua]) {
                            inExpiring[ua] = true;
                            expiringPending.push(ua);
                            emit ExpiringPendingQueued(ua, allocation);
                        }
                        if (snet != address(0)) {
                            try IStepNet(snet).setUserInClub(ua, false) {} catch {}
                        }
                    }
                }
            }
            unchecked { ++i; }

            if (i % gasCheckInterval == 0 && gasleft() < 1_500_000) {
                // Flush over-cap refunds before yielding, otherwise the
                // STEP returned by at-cap members in this partial batch is lost
                // from livePool tracking until a future deposit sweep.
                if (returnedToPool > 0) { livePool += returnedToPool; returnedToPool = 0; }
                distCursor = i;
                return;
            }
        }

        distCursor = end;

        if (returnedToPool > 0) {
            livePool += returnedToPool;
        }
    }

    // ─── MODIFIERS ───────────────────────────────────────────────────────────────
    modifier onlyStepNet() {
        if (msg.sender != _stepNet()) revert Unauthorized();
        _;
    }

    // ─── CLUB MEMBERSHIP MANAGEMENT (only callable by StepNet) ────────────────────

    /**
     * @notice StepNet-only: enrol a subscriber into the Club. If a
     *         distribution is in progress, the new member is buffered into
     *         `pendingJoinQueue` and flushed at finalize so the current
     *         round's allocation cannot be inflated by mid-flight arrivals.
     * @dev    Reject re-pushes for subscribers awaiting removal
     *         (`memberIndex != 0`); the slot is released by the next
     *         `flushRemovalQueue`, after which a normal `addMember` works.
     */
    function addMember(address ua) external onlyStepNet {
        if (isMember[ua]) return;
        if (memberIndex[ua] != 0) return;  // queued for removal — wait for flush

        if (distInProgress) {
            if (!inJoinQueue[ua]) {
                inJoinQueue[ua] = true;
                pendingJoinQueue.push(ua);
                emit MemberQueued(ua);
            }
            return;
        }
        _addMemberNow(ua);
    }

    function _addMemberNow(address ua) internal {
        isMember[ua] = true;
        memberIndex[ua] = memberList.length + 1;
        memberList.push(ua);
        memberCount++;
        emit MemberAdded(ua);
    }

    function removeMember(address ua) external onlyStepNet {
        _removeMemberInternal(ua);
        emit MemberRemoved(ua);
    }

    /**
     * @notice StepNet-only: move a subscriber's Club membership to a new
     *         wallet. Rejects destinations with pre-existing Club history
     *         so the cap accounting cannot be reset by a wallet change.
     */
    function transferMembership(address oldAddr, address newAddr) external onlyStepNet {
        if (!isMember[oldAddr] || isMember[newAddr]) revert Unauthorized();
        if (newAddr == address(0)) revert ZeroAddress();

        if (
            totalReceivedStep[newAddr] != 0 ||
            totalBurnedStep[newAddr]   != 0 ||
            pendingRewards[newAddr]    != 0
        ) revert NewAddrHasHistory();

        uint256 idx = memberIndex[oldAddr];
        memberIndex[newAddr] = idx;
        memberList[idx - 1] = newAddr;
        memberIndex[oldAddr] = 0;

        pendingRewards[newAddr]    = pendingRewards[oldAddr];
        totalReceivedStep[newAddr] = totalReceivedStep[oldAddr];
        totalBurnedStep[newAddr]   = totalBurnedStep[oldAddr];

        isMember[newAddr] = true;
        isMember[oldAddr] = false;
        pendingRewards[oldAddr] = 0;
        // Wipe the old wallet's Club history so it cannot be reused.
        totalReceivedStep[oldAddr] = 0;
        totalBurnedStep[oldAddr]   = 0;

        emit MembershipTransferred(oldAddr, newAddr);
    }

    function importMember(
        address ua,
        uint256 pendingReward,
        uint256 /*joinedAfterDistCount_*/
    ) external onlyStepNet {
        if (!isMember[ua]) {
            isMember[ua] = true;
            memberIndex[ua] = memberList.length + 1;
            memberList.push(ua);
            memberCount++;
            emit MemberAdded(ua);
        }
        totalPendingStep -= pendingRewards[ua];
        pendingRewards[ua] = pendingReward;
        totalPendingStep += pendingReward;
    }

    /// @notice Setter for historical totals (received & burned STEP) during Club upgrade sync.
    ///         Only callable by StepNet. Preserves user's history in the new Club instance.
    function setClubHistory(address ua, uint256 received, uint256 burned) external onlyStepNet {
        totalReceivedStep[ua] = received;
        totalBurnedStep[ua]   = burned;
    }

    // ─── DEPOSIT POOL (called by StepNet/NFT/DEX) ────────────────────────────────
    function receiveForPool(uint256 /*nominalAmount*/) external onlyStepNet {
        uint256 actual = _step().balanceOf(address(this)) - livePool - totalPendingStep;
        if (actual == 0) return;
        livePool += actual;
        emit PoolReceived(actual);
    }

    function notifyStepClubDeposit(uint256 /*nominalAmount*/) external {
        address nft = _nftTreasury();
        address dex = _stepDex();
        if (msg.sender != nft && msg.sender != dex) revert Unauthorized();

        uint256 actual = _step().balanceOf(address(this)) - livePool - totalPendingStep;
        if (actual == 0) return;
        livePool += actual;
        emit PoolReceived(actual);
    }

    // ─── USER-FACING WRITE FUNCTIONS (no platform fee) ───────────────────────────

    /**
     * @notice User-callable donation of STEP into the live pool. Requires
     *         the caller to have approved `amount` on the STEP contract
     *         beforehand. The 2 % deflationary levy applies unless the
     *         caller is whitelisted, so the credited `livePool` increment
     *         is the actually-received amount, not the nominal one.
     */
    function donateToPool(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IStepCoin step = _step();

        uint256 balBefore = step.balanceOf(address(this));
        IERC20(address(step)).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = step.balanceOf(address(this)) - balBefore;

        livePool     += received;
        totalDonated += received;
        emit PoolDonated(msg.sender, received);
        emit PoolReceived(received);
    }

    /**
     * @notice Drive a Club distribution round. Anyone (typically a keeper)
     *         may call. The routine is single-shot for small membership
     *         and gas-resumable for large ones: a gasleft() guard inside
     *         the inner loop persists `distCursor`/`distPhase` and yields
     *         when the safety reserve is reached. A follow-up call resumes
     *         the work seamlessly.
     */
    function processClubDistribution() external nonReentrant {
        if (block.timestamp < lastDistributionTime + DISTRIBUTION_INTERVAL && !distInProgress) revert TooEarly();

        if (!distInProgress) {
            bool needBurn = (pendingBurnDeadline > 0 && block.timestamp >= pendingBurnDeadline);

            if (needBurn) {
                distPhase = 0;
                distMemberSnapshot = memberList.length;
            } else {
                if (livePool == 0 || memberCount == 0) {
                    lastDistributionTime = block.timestamp;
                    emit ClubDistributionSkipped(livePool, memberCount);
                    return;
                }
                distAmountPerMember = livePool / memberCount;
                livePool = 0;
                roundCount++;
                lastDistributionTime = block.timestamp;
                pendingBurnDeadline  = block.timestamp + CLAIM_DEADLINE;
                distPhase = 1;
                distMemberSnapshot = memberList.length;
                emit ClubDistributionStarted(roundCount, distAmountPerMember);
            }

            distInProgress = true;
            distCursor = 0;
        }

        uint256 remaining = distMemberSnapshot > distCursor ? distMemberSnapshot - distCursor : 0;
        uint256 estimatedGasPerMember = 100_000;
        uint256 safetyGas = 400_000 + (remaining * estimatedGasPerMember);

        // Cap LOW so a normal-sized tx can ENTER and make progress; the inner
        // per-member gasleft guard inside _processBatch handles stopping safely.
        if (safetyGas > 2_000_000) safetyGas = 2_000_000;

        // When at-cap leftovers are queued for burning, floor the reserve above
        // _drainExpiringPending's 1.5M guard so a call that ENTERS always burns
        // at least one entry instead of entering, doing nothing, and yielding.
        // Only relevant in Phase 0, where the drain runs.
        if (distPhase == 0 && expiringPending.length > 0 && safetyGas < 1_600_000) {
            safetyGas = 1_600_000;
        }

        bool madeProgress = false;
        while (true) {
            if (gasleft() < safetyGas) {
                // Never silently no-op. If this call has not advanced the
                // distribution at all, revert so the whole tx (including any
                // round-start writes above) rolls back cleanly AND eth_estimateGas
                // is forced up to a gas level that does real work. Once at least
                // one batch has run, return instead — the progress is committed
                // and a later call resumes the remainder (resumable design intact,
                // and the final economic result is unchanged).
                if (!madeProgress) revert InsufficientGas();
                return;
            }

            _processBatch();
            madeProgress = true;

            uint256 effectiveLimit = distMemberSnapshot;
            if (effectiveLimit > memberList.length) effectiveLimit = memberList.length;

            if (distCursor < effectiveLimit) {
                continue;
            }

            // Phase 0: once current members' expired pending is burned, also
            // burn the stranded leftovers of at-cap-removed members. Resumable
            // LIFO drain — if it yields on gas, return so a later call resumes it
            // BEFORE any new round can start. A round therefore never begins
            // while last round's leftovers are still unburned.
            if (distPhase == 0 && expiringPending.length > 0) {
                _drainExpiringPending(_step());
                if (expiringPending.length > 0) {
                    return;
                }
            }

            if (distPhase == 0 && livePool > 0 && memberCount > 0) {
                distAmountPerMember = livePool / memberCount;
                livePool = 0;
                roundCount++;
                lastDistributionTime = block.timestamp;
                pendingBurnDeadline  = block.timestamp + CLAIM_DEADLINE;
                distPhase = 1;
                distCursor = 0;
                distMemberSnapshot = memberList.length;
                emit ClubDistributionStarted(roundCount, distAmountPerMember);
                continue;
            }

            distInProgress      = false;
            distPhase           = 0;
            distCursor          = 0;
            distAmountPerMember = 0;
            distMemberSnapshot  = 0;
            _flushRemovalQueue();
            _flushJoinQueue();
            emit ClubDistributionFinalized(roundCount);
            return;
        }
    }

    /// @notice Public helper to drain the deferred-removal queue after a
    ///         distribution has finalized. Safe to call by anyone; no
    ///         privileged action.
    function flushRemovalQueueManual() external nonReentrant {
        if (distInProgress) revert DistributionInProgress();
        _flushRemovalQueue();
    }

    /// @notice Permissionless safety valve: burn the expired, unclaimed pending
    ///         of the given accounts (typically members removed at-cap who never
    ///         claimed). Only runs once the claim deadline has passed, and only
    ///         touches accounts that actually have pending; each burn is charged
    ///         to that account's cap exactly like the automatic Phase-0 sweep.
    ///         Lets anyone clear stranded balances without waiting for the next
    ///         distribution round. Safe no-op for accounts with nothing pending.
    function sweepExpiredPending(address[] calldata accounts) external nonReentrant {
        if (distInProgress) revert DistributionInProgress();
        if (pendingBurnDeadline == 0 || block.timestamp < pendingBurnDeadline) revert TooEarly();
        IStepCoin step = _step();
        uint256 n = accounts.length;
        for (uint256 i = 0; i < n;) {
            _burnPendingCached(accounts[i], step); // no-op if nothing pending
            unchecked { ++i; }
        }
    }

    /// @notice Number of at-cap-removed members whose stranded leftover is still
    ///         queued for the next post-deadline burn (0 = nothing stranded).
    function expiringPendingLength() external view returns (uint256) {
        return expiringPending.length;
    }

    /// @notice Force-exit any subscriber who has already reached cap.
    ///         Permissionless and safe: only at-cap accounts are removed,
    ///         and any residual pending claim is burned (correct behaviour
    ///         for a capped subscriber).
    function checkAndExitIfAtCap(address ua) external nonReentrant {
        _doCheckAndExitIfAtCap(ua);
    }

    /// @notice Batch variant of `checkAndExitIfAtCap`.
    function checkAndExitIfAtCapBatch(address[] calldata accounts) external nonReentrant {
        uint256 n = accounts.length;
        for (uint256 i = 0; i < n;) {
            _doCheckAndExitIfAtCap(accounts[i]);
            unchecked { ++i; }
        }
    }

    function _doCheckAndExitIfAtCap(address ua) internal {
        if (!isMember[ua]) return;
        address snet = _stepNet();
        if (snet == address(0)) return;

        (
            uint256 totalPaid,
            /*totalCommDai*/,
            uint256 stepFromClub,
            uint256 stepBurnedClub,
            /*inStepClub*/,
            uint256 stepEquivFromBoxes
        ) = IStepNet(snet).getUserClubData(ua);
        if (totalPaid == 0) return;

        address dex = _stepDex();
        if (dex == address(0)) return;
        uint256 price;
        try IStepDex(dex).getPrice() returns (uint256 p) { price = p; } catch { return; }
        if (price == 0) return;

        uint256 clubStepUsd = ((stepFromClub + stepBurnedClub) * price) / 1e18;
        uint256 boxStepUsd  = (stepEquivFromBoxes * price) / 1e18;
        uint256 totalEarned = boxStepUsd + clubStepUsd;

        if (totalEarned < totalPaid) return; // not at cap — no-op

        // At cap — force exit. Any residual pending claim is burned.
        if (pendingRewards[ua] > 0) {
            _burnPending(ua);
        }
        _removeMemberInternal(ua);
        IStepNet(snet).setUserInClub(ua, false);
        emit MemberRemoved(ua);
    }

    /// @dev Bounded LIFO drain of the queued-newcomer list. Any tail beyond
    ///      `JOIN_FLUSH_BATCH` waits for the next distribution finalize.
    function _flushJoinQueue() internal {
        uint256 len = pendingJoinQueue.length;
        if (len == 0) return;
        uint256 toFlush = len > JOIN_FLUSH_BATCH ? JOIN_FLUSH_BATCH : len;
        for (uint256 i = 0; i < toFlush;) {
            address ua = pendingJoinQueue[pendingJoinQueue.length - 1];
            pendingJoinQueue.pop();
            inJoinQueue[ua] = false;
            if (!isMember[ua]) {
                _addMemberNow(ua);
            }
            unchecked { ++i; }
        }
    }

    /// @notice Public helper: anyone can flush remaining queued joins after a
    ///         distribution has finalized. Safe — no privileged action.
    function flushJoinQueueManual() external nonReentrant {
        if (distInProgress) revert DistributionInProgress();
        _flushJoinQueue();
    }

    // ─── CLAIM & EXIT ─────────────────────────────────────────────────────────────

    function claimForUser(address ua) external nonReentrant {
        if (ua != msg.sender) revert Unauthorized();
        _claimReward(ua);
    }

    function claim() external nonReentrant {
        _claimReward(msg.sender);
    }

    /**
     * @notice Voluntary exit from the Club. The exit is treated as full
     *         cap consumption: any gap between the caller's current earned
     *         total and their cap (`totalPaidAllBoxes`) is virtually
     *         credited to their "received-from-club" counter. No physical
     *         STEP is transferred — this is purely cap accounting so the
     *         subscriber cannot game lifetime entitlement via repeated
     *         exit-and-rejoin cycles.
     *
     *         Worked example:
     *           Cap = 200 DAI, prior STEP-equivalent earned = 70 DAI.
     *           Calling exit() credits 130 DAI / price as virtual STEP
     *           into the cap counter. Subsequent re-enrolment (after
     *           buying a higher tier that raises the cap) is then bounded
     *           by the *new* gap only.
     */
    function exit() external nonReentrant {
        if (!isMember[msg.sender]) revert NotMember();

        // Step 1: claim any real pending reward (or burn it if past
        // deadline). If the claim hits cap, the subscriber is auto-removed.
        if (pendingRewards[msg.sender] > 0) {
            _claimReward(msg.sender);
        }

        // Step 2: if still a member (sub-cap), apply the virtual credit
        // and then exit.
        if (isMember[msg.sender]) {
            _virtualCapCredit(msg.sender);
            _removeMemberInternal(msg.sender);
            address snet = _stepNet();
            if (snet != address(0)) IStepNet(snet).setUserInClub(msg.sender, false);
            emit MemberRemoved(msg.sender);
        }
    }

    /**
     * @notice Voluntary exit that converts the member's *entire* remaining
     *         cap-gap — which a plain `exit()` would forfeit — into free dApp
     *         subscription months, then leaves the club. No STEP/DAI payment:
     *         the value granted is exactly the gap the member gives up by
     *         leaving early. All-or-nothing; the user picks no amount.
     *
     * @dev    Fully trustless & single-spend, no admin in the loop: the same
     *         `_virtualCapCredit` a plain exit uses both computes the gap AND
     *         consumes it in the cap accounting, so the gap can never be granted
     *         twice; and `SUBSCRIPTION.grantFromClubExit` only accepts calls from
     *         this contract, so no subscription can be minted without an actual
     *         exit that forfeits the gap. Everything happens in one transaction.
     * @return monthsGranted subscription months added (0 if gap < cheapest plan).
     */
    function exitToSubscription() external nonReentrant returns (uint32 monthsGranted) {
        if (!isMember[msg.sender]) revert NotMember();

        // Step 1: settle any real pending reward first (mirrors exit()).
        if (pendingRewards[msg.sender] > 0) {
            _claimReward(msg.sender);
        }

        // Step 2: if still sub-cap, consume the gap, leave the club, then grant.
        if (isMember[msg.sender]) {
            uint256 gapDai = _virtualCapCredit(msg.sender); // computes AND consumes the gap
            _removeMemberInternal(msg.sender);
            address snet = _stepNet();
            if (snet != address(0)) IStepNet(snet).setUserInClub(msg.sender, false);
            emit MemberRemoved(msg.sender);

            // Interaction last (checks-effects-interactions): the gap is already
            // consumed above, so this external call cannot be replayed for value
            // even under reentrancy (and `nonReentrant` guards the whole tx).
            if (gapDai > 0) {
                monthsGranted = SUBSCRIPTION.grantFromClubExit(msg.sender, gapDai);
            }
            emit ExitedToSubscription(msg.sender, gapDai, monthsGranted);
        }
    }

    /// @dev Compute and apply the virtual cap fill. No tokens move; only
    ///      `totalReceivedStep[ua]` (local display counter) and
    ///      `IStepNet.addStepReceivedFromClub(ua, ...)` (StepNet's cap
    ///      accounting counter) are updated.
    function _virtualCapCredit(address ua) internal returns (uint256 gapDai) {
        address snet = _stepNet();
        if (snet == address(0)) return 0;

        (
            uint256 totalPaid,
            /*totalCommDai*/,
            uint256 stepFromClub,
            uint256 stepBurnedClub,
            /*inStepClub*/,
            uint256 stepEquivFromBoxes
        ) = IStepNet(snet).getUserClubData(ua);
        if (totalPaid == 0) return 0;

        address dex = _stepDex();
        if (dex == address(0)) return 0;

        uint256 price;
        try IStepDex(dex).getPrice() returns (uint256 p) { price = p; } catch { return 0; }
        if (price == 0) return 0;

        uint256 clubStepUsd = ((stepFromClub + stepBurnedClub) * price) / 1e18;
        uint256 boxStepUsd  = (stepEquivFromBoxes * price) / 1e18;
        uint256 totalEarned = boxStepUsd + clubStepUsd;
        if (totalEarned >= totalPaid) return 0; // already at cap — no-op

        gapDai = totalPaid - totalEarned;
        uint256 gapStep = (gapDai * 1e18) / price;
        if (gapStep == 0) return 0;

        // Accounting only — no token transfer.
        totalReceivedStep[ua] += gapStep;
        IStepNet(snet).addStepReceivedFromClub(ua, gapStep);
        emit VoluntaryExitCapCredit(ua, gapStep, gapDai);
    }

    function exitForUser(address ua) external onlyStepNet nonReentrant {
        if (!isMember[ua]) revert NotMember();
        if (pendingRewards[ua] > 0) {
            _burnPending(ua);
        }
        _removeMemberInternal(ua);
        IStepNet(_stepNet()).setUserInClub(ua, false);
        emit MemberRemoved(ua);
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────────────────────
    function getClubDashboard(address ua) external view returns (
        uint256 clubPool,
        bool    isClubMember,
        uint256 totalStepFromClub,
        uint256 totalBurnedFromClub,
        uint256 pendingStep,
        uint256 timeToNextDist,
        uint256 timeToClaimDeadline,
        uint256 clubRoundCount,
        uint256 totalClubMembers
    ) {
        uint256 nextDist     = lastDistributionTime + DISTRIBUTION_INTERVAL;
        uint256 burnDeadline = pendingBurnDeadline;
        return (
            livePool,
            isMember[ua],
            totalReceivedStep[ua],
            totalBurnedStep[ua],
            pendingRewards[ua],
            block.timestamp >= nextDist ? 0 : nextDist - block.timestamp,
            burnDeadline > block.timestamp ? burnDeadline - block.timestamp : 0,
            roundCount,
            memberCount
        );
    }

    function getClubPendingReward(address ua) external view returns (uint256) {
        return pendingRewards[ua];
    }

    function getClubStats() external view returns (
        uint256 _memberCount,
        uint256 _roundCount,
        uint256 _livePool,
        uint256 nextDist,
        uint256 timeLeft
    ) {
        uint256 nd = lastDistributionTime + DISTRIBUTION_INTERVAL;
        timeLeft = block.timestamp >= nd ? 0 : nd - block.timestamp;
        return (memberCount, roundCount, livePool, nd, timeLeft);
    }

    function getClubTimerData(address ua) external view returns (
        uint256 nextClubDist,
        uint256 clubTimeLeft,
        uint256 clubBurnAt,
        uint256 clubBurnLeft,
        uint256 clubPending,
        uint256 clubBurned
    ) {
        uint256 nd   = lastDistributionTime + DISTRIBUTION_INTERVAL;
        nextClubDist = nd;
        clubTimeLeft = block.timestamp >= nd ? 0 : nd - block.timestamp;
        clubBurnAt   = pendingBurnDeadline;
        clubBurnLeft = pendingBurnDeadline > block.timestamp ? pendingBurnDeadline - block.timestamp : 0;
        clubPending  = pendingRewards[ua];
        clubBurned   = totalBurnedStep[ua];
    }

    /// @notice Inspector for the deferred-newcomer queue.
    function getJoinQueueInfo() external view returns (uint256 queueLength, bool flushReady) {
        queueLength = pendingJoinQueue.length;
        flushReady  = !distInProgress && queueLength > 0;
    }

    // ─── MIGRATION (DAO + timelock via Registry) ────────────────────────────────
    function migrateAssetsTo(address newContract) external {
        if (msg.sender != address(REGISTRY)) revert NotAuthorized();
        if (newContract == address(0)) revert ZeroAddress();
        IStepCoin step = _step();
        uint256 bal = step.balanceOf(address(this));
        if (bal > 0) SafeERC20.safeTransfer(IERC20(address(step)), newContract, bal);
        livePool = 0;
        emit AssetsMigrated(newContract, bal);
    }
}
