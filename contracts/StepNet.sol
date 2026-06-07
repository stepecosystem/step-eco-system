// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./StepNetLib.sol";

/**
 * @title  StepNet
 * @notice Core subscription-and-distribution engine of the StepNet
 *         ecosystem — the on-chain heart of a Web3 wellness super-app built
 *         on a simple promise: Move Real, Earn Real, Build Forever. A fully
 *         on-chain, non-custodial protocol that issues tiered access passes
 *         ("boxes") to the ecosystem's digital and AI-driven services and
 *         routes a deterministic share of every subscription back to active
 *         subscribers through a referral graph.
 *
 *         Each "box" (0..5) represents a paid subscription tier, granting
 *         the holder graduated access to off-chain AI workloads, premium
 *         digital tools, and ecosystem utilities. The contract is the sole
 *         source of truth for tier ownership; off-chain services read this
 *         registry to authenticate subscribers.
 *
 *         The referral graph is a strict binary topology: every subscriber
 *         is the child of exactly one referrer ("upline") and may host at
 *         most two children. Subscription proceeds are split deterministically
 *         between (a) a daily redistribution pool that flows back to active
 *         subscribers in proportion to their team activity, (b) a dev
 *         treasury, (c) the NFT reward pool, (d) the loyalty Club pool, and
 *         (e) a portion converted to STEP via the on-chain AMM. All splits
 *         are immutable constants of the contract.
 *
 *         Security properties of note:
 *           • ReentrancyGuard on every external user entry-point.
 *           • Custom errors (no revert strings) for gas-efficient failure.
 *           • Slippage-protected interactions with the AMM (minStepOut
 *             derived from `estimateBuy` at call time).
 *           • Deterministic, snapshot-based daily distribution that is
 *             resumable across blocks via cursor state — no single transaction
 *             can be forced to the gas limit by a malicious actor.
 *           • All upgrades and treasury moves require DAO vote +
 *             time-lock in the StepRegistry — no privileged backdoor.
 *           • Terms-of-Service acceptance is enforced on every user
 *             entry-point that transfers value.
 *
 * @dev    Storage layout, custom error selectors, and event signatures are
 *         stable. Heavy logic that does not need to remain in this contract's
 *         24,576-byte bytecode footprint is delegated to deployed external
 *         libraries (ReserveLib, WalletLib, PendingLib) via DELEGATECALL,
 *         which leaves storage and events under this address.
 */


interface IStepRegistry {
    function get(bytes32 key) external view returns (address);
    function KEY_STEP_COIN()     external view returns (bytes32);
    function KEY_STEP_DEX()      external view returns (bytes32);
    function KEY_NFT_TREASURY()  external view returns (bytes32);
    function KEY_DEV_TREASURY()  external view returns (bytes32);
    function KEY_CLUB_TREASURY() external view returns (bytes32);
    // Terms-of-Service gate (read-only).
    function hasAcceptedCurrentTerms(address user) external view returns (bool);
}
interface IStepCoin is IERC20 { function burn(uint256 amount) external; }
interface IStepDex {
    function buyStep(uint256 daiAmount, uint256 minStepOut) external;
    function getPrice() external view returns (uint256);
    function donateLiquidity(uint256 daiAmount) external;
    // slippage-protection accounting (sandwich-attack defense)
    function estimateBuy(uint256 daiAmount) external view returns (uint256);
}
interface INFTTreasury { function addToRewardPool(uint256 amount) external; }
interface IStepClub {
    function addMember(address ua) external;
    function transferMembership(address oldAddr, address newAddr) external;
    function importMember(address ua, uint256 pendingReward, uint256 joinedAfterDistCount_) external;
    function receiveForPool(uint256 amount) external;
    function exitForUser(address ua) external; // automatic exit path used by _checkAndExitClub
    // two-way sync of inStepClub / isMember
    function isMember(address ua) external view returns (bool);
    function setClubHistory(address ua, uint256 received, uint256 burned) external;
}

error ZeroAddress();
error OnlyOriginalDeployer();
error AlreadyInitialized();
error UseNewWallet();
error InvalidBox();
error SameWallet();
error NewWalletUsed();
error MaxChanges();
error NotRegistered();
error AllBoxesActivated();
error PreviousRequired();
error AlreadyRegistered();
error InvalidReferrer();
error ReferrerNotRegistered();
error ReferrerFull();
error TooEarly();
error NoReward();
error MintFailed();
error OnlyClub();
error NotRegistry();
error ImportWindowClosed();
error AlreadyInitializedCannotImport();
error BoxAlreadyPurchased();
error ReferrerNotReg();
error BatchSizeInvalid();
error NoPendingUpdates();
error NoExpiredReserves();
error NoPendingUpgrades();
error OnlyImporter();
error ImporterAlreadySet();
/// @notice Caller has not acknowledged the current Terms-of-Service in the
///         registry. Call `StepRegistry.acceptTerms(currentTermsHash)` first.
error TermsNotAccepted();

contract StepNet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20        public immutable DAI;
    IStepRegistry public immutable REGISTRY;
    address       public immutable originalDeployer;
    uint256       public immutable deployedAt;
    bool          public initialized;

    uint256 public  constant BOX_COUNT                   = 6;
    uint256 public  constant BOX_PRICE_0                 = 25 ether;
    uint256 public  constant IMPORT_WINDOW               = 2 days;
    uint256 private constant DAILY_CAP                   = 15;
    uint256 private constant UPGRADE_RESERVE_PCT         = 10;
    uint256 private constant DAILY_DISTRIBUTION_INTERVAL = 24 hours;
    uint256 private constant RESERVE_BURN_INTERVAL       = 90 days;
    uint256 private constant IMMEDIATE_UPDATE_LEVELS     = 70;

    /// @dev Per-call upper bound on reserve tickets processed during the
    ///      daily routine. Prevents any individual subscriber from being able
    ///      to indefinitely stall the distribution by accumulating tickets.
    uint256 private constant MAX_RESERVE_BATCH           = 100;
    /// @dev Slippage floor for every internal AMM buy. 95% means a maximum
    ///      tolerated price drift of 5% between simulation and execution.
    ///      Provides credible defence against sandwich attacks while
    ///      accommodating the small natural drift of the bonding-curve AMM.
    uint256 private constant MIN_STEP_BPS                = 9500;
    uint256 private constant BPS_DENOMINATOR             = 10000;


    function _boxPrice(uint8 id) private pure returns (uint256) {
        if (id == 0) return 25 ether;
        if (id == 1) return 75 ether;
        if (id == 2) return 100 ether;
        if (id == 3) return 300 ether;
        if (id == 4) return 500 ether;
        return 1000 ether;
    }

    /// @dev User struct is defined at file scope in StepNetLib.sol so the
    ///      WalletLib helper can operate on storage refs without redeclaring
    ///      the type. The wallet-change implementation is also delegated to
    ///      WalletLib via DELEGATECALL to keep this bytecode under the
    ///      EIP-170 limit. Storage layout is unchanged.
    using ReserveLib for *;

    mapping(address => ReserveLib.ReserveTicket[]) public reserveTickets;
    mapping(address => uint256)                    public reserveTicketHead;
    address public importer;
    mapping(address => User)            public users;
    mapping(address => string)          public userName;
    mapping(address => uint256)         public walletChangeCount;
    mapping(address => address)         public oldToNewWallet;
    mapping(address => address)         public newToOldWallet;
    mapping(address => mapping(uint256 => uint256)) public pendingBoxDaiRewards;
    mapping(address => mapping(uint256 => uint256)) public boxActivatedAt;

    address[]                   public activeUsers;
    mapping(address => bool)    public processed;
    mapping(address => uint256) public activeUsersIndex;
    uint256                     public activeBox0Count;

    struct BoxPool { uint256 accumulatedDai; uint256 lastDistributionTime; uint256 pointPriceThisCycle; }
    mapping(uint256 => BoxPool) public pools;


    mapping(uint256 => uint256) public dailyPhase;
    mapping(uint256 => uint256) public dailyCursor;
    mapping(uint256 => uint256) public dailyTotalPoints;
    mapping(uint256 => uint256) public cycleStartedAt;   // 0 = no cycle currently running
    mapping(uint256 => uint256) public cycleTotalUsers;  // number of users at cycle start
    mapping(uint256 => uint256) public lastRoundRewardPerBox;
    mapping(uint256 => uint256) public lastRoundBurnedPointsPerBox;

    // ─── Global Cycle State ──────────────────────────────────────────────────
    // globalCycleStep:
    // 0 = ready to start (TooEarly check)
    // 1 = flush pendingUpdates for all boxes
    // 2..7 = process box (globalCycleStep-2) = box 0 through 5
    // 8 = cycle complete
    uint256 public globalCycleStep;
    uint256 public globalCycleStartedAt;   // timestamp the current cycle started
    uint256 public globalCycleTotalUsers;  // snapshot of activeUsers at cycle start
    // STEP price locked for the whole current cycle (anti-MEV + time fairness)
    uint256 public cycleStepPriceSnapshot;
    mapping(address => mapping(uint256 => uint256)) public lastDailyBurnedPointsUser;
    mapping(uint256 => address[])                   public pendingUpdates;
    mapping(address => mapping(uint256 => address)) public lastUpdatedUpline;
    mapping(address => mapping(uint256 => address)) public lastUpdatedChild;
    address[]                public pendingUpgradeList;
    mapping(address => bool) public hasPendingUpgrade;
    /// @dev O(1) reverse-index into pendingUpdates / pendingUpgradeList so
    ///      that removals during wallet migration are constant-time even at
    ///      large user counts. Stored as `index + 1`; a zero value indicates
    ///      "not present".
    mapping(uint256 => mapping(address => uint256)) public pendingUpdateIndex;
    mapping(address => uint256)                     public pendingUpgradeIndex;

    /// @notice Persistent Box-0 subtree counters used by the governance
    ///         module to compute on-chain voting weight.
    ///         `voting weight = 1 + min(box0LeftSubtree, box0RightSubtree)`
    ///         These counters monotonically increase on every Box-0
    ///         activation in the respective subtree and are preserved across
    ///         daily distributions (unlike the day-by-day team counts which
    ///         are intentionally consumed by the points model).
    ///         Internal storage — read externally via `getBox0Subtree`
    ///         (single SLOAD pair) and `getBox0SubtreeWeakerSide` instead of
    ///         a pair of auto-generated getters, which shaves bytecode.
    mapping(address => uint256) internal box0LeftSubtree;
    mapping(address => uint256) internal box0RightSubtree;

    uint256 public reserveBurnCursor;

    // ─── Touched-set distribution (gas: O(affected uplines), not O(allUsers)) ──
    //  `dirtyUsers[boxId]` collects every upline whose box-`boxId` team counter
    //  changed since that tier was last distributed (populated by
    //  PendingLib.propagate / processBatch and by import seeding). The daily
    //  routine iterates ONLY this set, never the full subscriber base. This is
    //  exact, not an approximation: any subscriber NOT in the set has an
    //  unchanged weaker leg — it was consumed to zero on their previous payout,
    //  and only a new downline activation (which re-marks them here) can raise
    //  it again — so they would contribute zero points and zero burn anyway.
    //  `dirtyIndex` is `index + 1` for O(1) dedup; zero means "absent".
    mapping(uint256 => address[])                   internal dirtyUsers;
    mapping(uint256 => mapping(address => uint256)) internal dirtyIndex;

    //  Subscribers that currently hold a non-zero `reservedForUpgrade`. The
    //  Box-0 pass sweeps this set for expired-reserve burning instead of
    //  scanning everyone — a subscriber with no reserve has nothing to expire.
    //  Lazily compacted on sweep when a reserve hits 0.
    address[]                   internal reserveUsers;
    mapping(address => uint256) internal reserveUserIndex; // idx+1; 0 = absent

    event BoxActivated(address indexed user, uint256 boxId, address indexed referrer, uint256 daiAmount);
    event AutoUpgrade(address indexed user, uint256 toBox);
    event PointsClaimed(address indexed user, uint256 boxId, uint256 points, uint256 daiValue);
    event DailyPointsBurned(address indexed user, uint256 indexed boxId, uint256 burnedPoints);
    event DailyPoolDistributed(uint256 indexed boxId, uint256 totalDai, uint256 pointPrice);
    event WalletChanged(address indexed oldWallet, address indexed newWallet);
    event BoxRewardsWithdrawn(address indexed user, uint256 indexed boxId, uint256 stepAmount);
    event ReserveBurned(address indexed user, uint256 daiAmount);
    event DailyCycleComplete(uint256 cycleStartedAt, uint256 totalUsers);
    event ClubHistorySynced(address indexed ua, uint256 received, uint256 burned);
    /// @notice Emitted when a daily cycle iterates over a tier in which no
    ///         subscriber has unredeemed activity. Distinguishes "ran but
    ///         empty" from "did not run", which is helpful for off-chain
    ///         indexers and front-ends.
    event BoxProcessedNoActivity(uint256 indexed boxId, uint256 totalUsers, uint256 accumulatedDaiCarriedOver);
    /// @notice Emitted at the start of every daily distribution cycle with
    ///         the snapshot of total subscribers and the AMM STEP price
    ///         captured for the cycle (used for cap accounting).
    event CycleStarted(uint256 indexed cycleStartedAt, uint256 totalUsers, uint256 stepPriceSnapshot);

    constructor(address _registry, address _dai) {
        if (_registry == address(0) || _dai == address(0)) revert ZeroAddress();
        REGISTRY         = IStepRegistry(_registry);
        DAI              = IERC20(_dai);
        originalDeployer = msg.sender;
        deployedAt       = block.timestamp;
        /// The deployer is seated as the root of the referral graph with a
        /// Box-0 marker so that subsequent activations have a valid root.
        /// No paid amounts are credited — `totalPaid*` remain zero — so
        /// off-chain analytics never misclassify the deployer as a paying
        /// subscriber.
        userName[msg.sender]                   = "Founder";
        users[msg.sender].boxPurchasedCount[0] = 1;
        users[msg.sender].startTimestamp       = block.timestamp;
        /// `pools[*].lastDistributionTime` is intentionally left at zero;
        /// the first `processDaily` call may run at any time after deploy
        /// (since `block.timestamp << 0 + INTERVAL` is always false on any
        /// real chain), and the timer then starts from the completion of
        /// the first cycle.
        activeBox0Count = 1;
        processed[msg.sender]        = true;
        activeUsersIndex[msg.sender] = 1;
        activeUsers.push(msg.sender);
    }

    function _step() internal view returns (IStepCoin)    { return IStepCoin(REGISTRY.get(REGISTRY.KEY_STEP_COIN())); }
    function _dex()  internal view returns (IStepDex)     { return IStepDex(REGISTRY.get(REGISTRY.KEY_STEP_DEX())); }
    function _nft()  internal view returns (INFTTreasury) { return INFTTreasury(REGISTRY.get(REGISTRY.KEY_NFT_TREASURY())); }
    function _dev()  internal view returns (address)      { return REGISTRY.get(REGISTRY.KEY_DEV_TREASURY()); }
    function _club() internal view returns (IStepClub)    { return IStepClub(REGISTRY.get(REGISTRY.KEY_CLUB_TREASURY())); }
    function _weaker(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

    // ─── Dynamic safety-gas helpers ────────────────────────────────────────
    //  Distribution iterates over an unbounded user set; resumable cursor
    //  state lets the routine span multiple transactions if needed. To
    //  decide *when* to checkpoint and return, we compare gasleft() against
    //  a workload-scaled minimum. Hard-coded constants were brittle for
    //  heavy subscribers (deep ticket queues, many emits); these helpers
    //  scale conservatively with actual call-site workload.

    /// @dev Minimum gas reserve before yielding inside the pending-updates
    ///      flush phase. Scaled by how much of the batch is left to process.
    function _dynamicSafetyGasUpdates(uint256 pendingLen, uint256 batchSize)
        internal pure returns (uint256)
    {
        uint256 effective = pendingLen < batchSize ? pendingLen : batchSize;
        uint256 dyn = 120_000 + (effective * 40_000) / batchSize;
        return dyn < 120_000 ? 120_000 : dyn;
    }

    // (phase-0 safety-gas now lives inline in PendingLib.distPhase0)

    /// @dev Minimum gas reserve before yielding inside phase 1 (the reward
    ///      distribution pass — the heaviest pass; touches per-user
    ///      reserve tickets, DEX state, and emits multiple events).
    function _dynamicSafetyGasReward(uint256 remaining)
        internal pure returns (uint256)
    {
        uint256 userAdd = remaining > 30 ? 30 * 3_000 : remaining * 3_000;
        return 160_000 + userAdd;
    }

    /// @dev Registration is gated on Box-0 ownership, not on `totalPaidAllBoxes`,
    ///      so that the constructor-seeded root user is treated as registered
    ///      without inflating any payment-based accounting.
    function _isRegistered(address ua) internal view returns (bool) {
        return users[ua].boxPurchasedCount[0] > 0;
    }

    function _getHighestBox(address ua) internal view returns (uint256) {
        for (uint256 i = 5; i > 0; i--) { if (users[ua].boxPurchasedCount[i] > 0) return i; }
        return 0;
    }

    function _addToClub(address ua) internal {
        User storage user = users[ua];
        if (user.inStepClub) return;
        uint256 price = 0;
        if (initialized) { try _dex().getPrice() returns (uint256 p) { price = p; } catch {} }
        uint256 clubStepUsd = price > 0 ? ((user.stepReceivedFromClub + user.stepBurnedFromClub) * price) / 1e18 : 0;
        uint256 boxStepUsd  = price > 0 ? (user.stepEquivFromBoxes * price) / 1e18 : user.totalCommissionDai;
        uint256 totalEarned = boxStepUsd + clubStepUsd;
        if (totalEarned >= user.totalPaidAllBoxes) return;
        user.inStepClub = true;
        user.clubJoinedTimestamp = block.timestamp;
        _club().addMember(ua);
    }

    /// @dev Auto-exits the subscriber from the loyalty Club when their
    ///      total earned value (boxes + club) has reached the configured
    ///      cap (`totalPaidAllBoxes`). Defensive against state drift between
    ///      this contract and the Club: a `isMember` view check and a
    ///      try/catch wrapper around `exitForUser` guarantee that a stuck
    ///      Club call can never freeze the daily distribution.
    function _checkAndExitClub(address ua) internal {
        User storage u = users[ua];
        if (!u.inStepClub || !initialized) return;

        IStepClub club = _club();
        try club.isMember(ua) returns (bool stillMember) {
            if (!stillMember) {
                u.inStepClub = false;
                return;
            }
        } catch {
            return;
        }

        uint256 price = 0;
        try _dex().getPrice() returns (uint256 p) { price = p; } catch {}
        uint256 clubStepUsd = price > 0 ? ((u.stepReceivedFromClub + u.stepBurnedFromClub) * price) / 1e18 : 0;
        uint256 boxStepUsd  = price > 0 ? (u.stepEquivFromBoxes * price) / 1e18 : u.totalCommissionDai;
        uint256 totalEarned = boxStepUsd + clubStepUsd;
        if (totalEarned >= u.totalPaidAllBoxes) {
            u.inStepClub = false;
            try club.exitForUser(ua) {} catch {}
        }
    }

    /// @dev Internal AMM purchase with slippage protection. The expected
    ///      output is derived from the DEX's `estimateBuy` view; a 5 %
    ///      tolerance is applied so any price drift larger than 5 % between
    ///      simulation and execution reverts the call (anti-MEV).
    function _buyStepWithDaiToken(uint256 daiAmount, IStepCoin step) internal returns (uint256 minted) {
        IStepDex dex = _dex();
        uint256 minOut = _calcMinStepOut(daiAmount, dex);
        DAI.forceApprove(address(dex), daiAmount);
        uint256 before = IERC20(address(step)).balanceOf(address(this));
        dex.buyStep(daiAmount, minOut);
        DAI.forceApprove(address(dex), 0);
        minted = IERC20(address(step)).balanceOf(address(this)) - before;
    }

    /// @dev Returns 95 % of the DEX's estimated STEP output for `daiAmount`.
    ///      Falls through to zero (no floor) if the DEX rejects the call,
    ///      so this remains forward-compatible with any DEX that omits the
    ///      view function.
    function _calcMinStepOut(uint256 daiAmount, IStepDex dex) internal view returns (uint256) {
        if (daiAmount == 0) return 0;
        try dex.estimateBuy(daiAmount) returns (uint256 expected) {
            if (expected == 0) return 0;
            return (expected * MIN_STEP_BPS) / BPS_DENOMINATOR;
        } catch {
            return 0;
        }
    }

    function _donateDaiToLiquidity(uint256 daiAmount, IStepDex dex) internal {
        uint256 bal = DAI.balanceOf(address(this));
        uint256 actual = daiAmount > bal ? bal : daiAmount;
        if (actual == 0) return;
        if (address(dex) == address(0)) dex = _dex();
        DAI.forceApprove(address(dex), actual);
        dex.donateLiquidity(actual);
        DAI.forceApprove(address(dex), 0);
    }

    modifier onlyClub() {
        if (msg.sender != address(_club())) revert OnlyClub();
        _;
    }

function syncClubMembers(uint256 startIdx, uint256 endIdx) external nonReentrant {
    // The one-time club re-mirroring loop runs in ClubSyncLib via DELEGATECALL
    // so this cold path stays off StepNet's bytecode (EIP-170 cap).
    ClubSyncLib.sync(activeUsers, users, IClubSync(address(_club())), startIdx, endIdx);
}

    modifier validWallet() {
        address orig = newToOldWallet[msg.sender];
        if (orig != address(0) && users[orig].totalPaidAllBoxes != 0) revert UseNewWallet();
        _;
    }

    /// @notice Gate that requires the caller (msg.sender) to have on-chain
    ///         acknowledged the current Terms-of-Service hosted by the
    ///         registry. Applied to every user-initiated entry point that
    ///         transfers value or grants subscription access.
    modifier requireTermsAccepted() {
        if (!REGISTRY.hasAcceptedCurrentTerms(msg.sender)) revert TermsNotAccepted();
        _;
    }

    function addStepReceivedFromClub(address ua, uint256 amount) external onlyClub {
        users[ua].stepReceivedFromClub += amount;
    }

    function addStepBurnedFromClub(address ua, uint256 amount) external onlyClub {
        users[ua].stepBurnedFromClub += amount;
        users[ua].totalBurnedByUser  += amount;
    }

    function setUserInClub(address ua, bool value) external onlyClub { 
        users[ua].inStepClub = value; 
    }

    function getUserClubData(address ua) external view returns (
        uint256 totalPaidAllBoxes,
        uint256 totalCommissionDai,
        uint256 stepReceivedFromClub,
        uint256 stepBurnedFromClub,
        bool    inStepClub,
        uint256 stepEquivFromBoxes
    ) {
        User storage u = users[ua];
        totalPaidAllBoxes    = u.totalPaidAllBoxes;
        totalCommissionDai   = u.totalCommissionDai;
        stepReceivedFromClub = u.stepReceivedFromClub;
        stepBurnedFromClub   = u.stepBurnedFromClub;
        inStepClub           = u.inStepClub;
        stepEquivFromBoxes   = u.stepEquivFromBoxes;
    }

    function finalizeSetup() external {
        if (msg.sender != originalDeployer) revert OnlyOriginalDeployer();
        if (initialized) revert AlreadyInitialized();
        if (address(_step()) == address(0) || address(_dex()) == address(0) ||
            address(_nft()) == address(0)  || _dev() == address(0) ||
            address(_club()) == address(0)) revert ZeroAddress();
        initialized = true;
    }


    // ==================== Compact Reserve Tickets (automatic) ====================
    function _compactReserveTickets(address ua) internal {
        // delegated to external ReserveLib — bytecode moved out of StepNet
        ReserveLib.compact(reserveTickets, reserveTicketHead, ua);
    }

    // ─── Touched-set helpers (heavy bodies delegated to PendingLib for size) ──
    /// @dev Dedup-insert of `ua` into the box-`boxId` dirty set. Used by import
    ///      seeding (PendingLib marks the propagation path internally).
    function _markDirty(uint256 boxId, address ua) internal {
        PendingLib.markDirty(dirtyUsers, dirtyIndex, boxId, ua);
    }

    /// @dev Dedup-insert into the active-reserve set.
    function _addReserveUser(address ua) internal {
        PendingLib.addReserveUser(reserveUsers, reserveUserIndex, ua);
    }

    /// @dev Swap-pop removal from the active-reserve set.
    function _removeReserveUserAt(uint256 i, address ua) internal {
        PendingLib.removeReserveUserAt(reserveUsers, reserveUserIndex, i, ua);
    }

    /// @dev Drops the processed window `[0, processedEnd)` from a tier's dirty
    ///      set after its cycle finalizes; mid-cycle additions survive.
    function _clearDirtyBox(uint256 boxId, uint256 processedEnd) internal {
        PendingLib.clearDirtyBox(dirtyUsers, dirtyIndex, boxId, processedEnd);
    }

    /**
     * @notice Migrate the caller's full subscription state — referral
     *         position, accumulated rewards, reserve tickets, club
     *         membership — to a new wallet address. The old wallet is
     *         retired and cannot re-register.
     * @dev    The bulk of the routine lives in WalletLib and is executed
     *         via DELEGATECALL so all storage updates remain under this
     *         contract's address. The permanent Box-0 subtree counters
     *         (used for DAO voting weight) are then moved by this wrapper.
     */
    function changeWallet(address newWallet) external nonReentrant validWallet {
        address oldWallet = msg.sender;
        WalletLib.changeWallet(
            users,
            walletChangeCount,
            oldToNewWallet,
            newToOldWallet,
            pendingBoxDaiRewards,
            boxActivatedAt,
            reserveTickets,
            reserveTicketHead,
            lastDailyBurnedPointsUser,
            lastUpdatedUpline,
            lastUpdatedChild,
            pendingUpdateIndex,
            pendingUpdates,
            hasPendingUpgrade,
            pendingUpgradeIndex,
            pendingUpgradeList,
            processed,
            activeUsersIndex,
            activeUsers,
            userName,
            oldWallet,
            newWallet,
            address(_club())
        );

        // Move the permanent Box-0 subtree counters to the new wallet so
        // the migrating subscriber retains their governance weight.
        uint256 lOld = box0LeftSubtree[oldWallet];
        uint256 rOld = box0RightSubtree[oldWallet];
        if (lOld > 0 || rOld > 0) {
            box0LeftSubtree[newWallet]  = lOld;
            box0RightSubtree[newWallet] = rOld;
            delete box0LeftSubtree[oldWallet];
            delete box0RightSubtree[oldWallet];
        }
    }

    /**
     * @notice Activate the Box-0 subscription tier under a chosen referrer.
     *         Pays the fixed `BOX_PRICE_0` (25 DAI) in DAI and inserts the
     *         caller as a child of `referrer` in the binary referral graph.
     * @param  referrer An already-registered wallet under which the caller
     *                  will be seated. Must have a free left or right slot.
     */
    function activateBox(address referrer) external validWallet requireTermsAccepted nonReentrant {
        if (_isRegistered(msg.sender)) revert AlreadyRegistered();
        /// Once a wallet has executed `changeWallet`, the old address is
        /// permanently retired. Re-registering under a new branch would
        /// duplicate the same identity in the graph.
        if (oldToNewWallet[msg.sender] != address(0)) revert AlreadyRegistered();
        if (referrer == address(0) || referrer == msg.sender) revert InvalidReferrer();
        if (!_isRegistered(referrer)) revert ReferrerNotRegistered();
        if (users[referrer].left != address(0) && users[referrer].right != address(0)) revert ReferrerFull();
        DAI.safeTransferFrom(msg.sender, address(this), BOX_PRICE_0);
        _activateBoxInternal(msg.sender, 0, BOX_PRICE_0, referrer);
    }

    /**
     * @notice Activate the caller's next available subscription tier.
     *         Uses the caller's accumulated upgrade reserve first; any
     *         shortfall is pulled from the caller's DAI balance.
     */
    function activateNextBoxManually() external validWallet requireTermsAccepted nonReentrant {
        if (oldToNewWallet[msg.sender] != address(0)) revert UseNewWallet();
        _doActivateNextBox(msg.sender);
    }

    /**
     * @notice Sponsor a Box-0 activation on behalf of another address. The
     *         sponsor pays the fee; the beneficiary becomes the registered
     *         subscriber under `referrer`.
     */
    function activateBoxFor(address forUser, address referrer) external requireTermsAccepted nonReentrant {
        if (forUser == address(0) || forUser == msg.sender) revert InvalidReferrer();
        if (_isRegistered(forUser) || oldToNewWallet[forUser] != address(0)) revert AlreadyRegistered();
        if (referrer == address(0) || referrer == forUser) revert InvalidReferrer();
        if (!_isRegistered(referrer)) revert ReferrerNotRegistered();
        if (users[referrer].left != address(0) && users[referrer].right != address(0)) revert ReferrerFull();
        DAI.safeTransferFrom(msg.sender, address(this), BOX_PRICE_0);
        _activateBoxInternal(forUser, 0, BOX_PRICE_0, referrer);
    }

    /// @notice Sponsor the next-tier activation for an existing subscriber.
    function activateNextBoxManuallyFor(address forUser) external requireTermsAccepted nonReentrant {
        if (forUser == address(0)) revert ZeroAddress();
        if (oldToNewWallet[forUser] != address(0)) revert UseNewWallet();
        _doActivateNextBox(forUser);
    }

    function _doActivateNextBox(address forUser) internal {
        User storage user = users[forUser];
        if (user.boxPurchasedCount[0] == 0) revert PreviousRequired();
        uint256 nextBoxId = BOX_COUNT;
        for (uint256 i = 0; i < BOX_COUNT; i++) { 
            if (user.boxPurchasedCount[i] == 0) { 
                nextBoxId = i; 
                break; 
            } 
        }
        if (nextBoxId >= BOX_COUNT) revert AllBoxesActivated();
        if (user.boxPurchasedCount[nextBoxId - 1] == 0) revert PreviousRequired();

        _compactReserveTickets(forUser);                    // automatic

        _checkAndBurnExpiredReserve(forUser, user, IStepDex(address(0)));
        uint256 price    = _boxPrice(uint8(nextBoxId));
        uint256 reserved = user.reservedForUpgrade;
        uint256 missing = reserved >= price ? 0 : price - reserved;
        uint256 usedFromReserve = reserved >= price ? price : reserved;
        user.reservedForUpgrade = reserved >= price ? reserved - price : 0;
        if (usedFromReserve > 0) _consumeReserveTickets(forUser, usedFromReserve);
        if (missing > 0) DAI.safeTransferFrom(msg.sender, address(this), missing);
        _activateBoxInternal(forUser, nextBoxId, price, address(0));
    }

    function _activateBoxInternal(address ua, uint256 boxId, uint256 paid, address referrer) internal {
        User storage user = users[ua];
        if (user.boxPurchasedCount[boxId] != 0) revert BoxAlreadyPurchased();
        if (user.startTimestamp == 0) user.startTimestamp = block.timestamp;

        uint256 toUser = paid * 5 / 100; 
        uint256 toDev  = paid * 5 / 100;
        uint256 toNft  = paid * 3 / 100; 
        uint256 toClub = paid * 5 / 100;
        uint256 forStep = toUser + toDev + toNft + toClub;

        if (forStep > 0 && initialized) {
            IStepCoin step     = _step();
            IStepDex  dex      = _dex();
            address   nftAddr  = address(_nft());
            address   devAddr  = _dev();
            address   clubAddr = address(_club());

            // Slippage-protected AMM purchase: see `_calcMinStepOut`.
            uint256 minOut = _calcMinStepOut(forStep, dex);
            DAI.forceApprove(address(dex), forStep);
            uint256 before = IERC20(address(step)).balanceOf(address(this));
            dex.buyStep(forStep, minOut);
            DAI.forceApprove(address(dex), 0);
            uint256 minted = IERC20(address(step)).balanceOf(address(this)) - before;

            if (minted > 0) {
                uint256 aUser = (minted * toUser) / forStep;
                uint256 aNft  = (minted * toNft)  / forStep;
                uint256 aDev  = (minted * toDev)  / forStep;
                uint256 aClub = minted - aUser - aNft - aDev;

                if (aUser > 0) IERC20(address(step)).safeTransfer(ua, aUser);
                if (aNft  > 0) { 
                    IERC20(address(step)).forceApprove(nftAddr, aNft); 
                    INFTTreasury(nftAddr).addToRewardPool(aNft); 
                    IERC20(address(step)).forceApprove(nftAddr, 0); 
                }
                if (aDev  > 0) IERC20(address(step)).safeTransfer(devAddr, aDev);
                if (aClub > 0) { 
                    IERC20(address(step)).safeTransfer(clubAddr, aClub); 
                    IStepClub(clubAddr).receiveForPool(aClub); 
                }
            }
        }

        pools[boxId].accumulatedDai += paid - forStep;
        user.boxPurchasedCount[boxId] = 1;
        boxActivatedAt[ua][boxId] = block.timestamp;
        if (boxId == 0) { unchecked { ++activeBox0Count; } }
        user.totalPaidPerBox[boxId] = paid; 
        user.totalPaidAllBoxes += paid;

        if (boxId >= 2) _addToClub(ua);

        if (referrer != address(0) && referrer != ua && user.upline == address(0)) {
            if (!_isRegistered(referrer)) revert ReferrerNotReg();
            user.upline = referrer;
            if (users[referrer].left == address(0)) users[referrer].left = ua; 
            else users[referrer].right = ua;
        }

        if (user.upline != address(0)) {
            // `propagate` advances both the per-day team counts and — for
            // Box-0 activations — the permanent DAO voting counters along the
            // same walk. Both reach the tree root: the immediate window is
            // covered here, and any remainder is drained by the shared
            // pendingUpdates / processBatch continuation.
            PendingLib.propagate(
                users, pendingUpdates, pendingUpdateIndex,
                lastUpdatedUpline, lastUpdatedChild,
                dirtyUsers, dirtyIndex,
                box0LeftSubtree, box0RightSubtree,
                ua, ua, boxId
            );
        }

        if (!processed[ua]) { 
            processed[ua]=true; 
            activeUsersIndex[ua]=activeUsers.length+1; 
            activeUsers.push(ua); 
        }

        emit BoxActivated(ua, boxId, referrer, paid);
    }

    /// @dev Burns any reserve tickets whose lifetime has elapsed, returning
    ///      their DAI value to liquidity. Bounded per call by
    ///      `MAX_RESERVE_BATCH` so a subscriber with a deep ticket queue
    ///      cannot block the daily routine.
    function _checkAndBurnExpiredReserve(address ua, User storage u, IStepDex dex) internal {
        // Accounting (ticket scan + counter debits + compaction) lives in
        // ReserveLib to keep this contract under the EIP-170 cap; the
        // DEX-touching donate + event stay here, unchanged.
        uint256 toBurn = ReserveLib.burnExpired(reserveTickets, reserveTicketHead, u, ua);
        if (toBurn > 0 && initialized) {
            _donateDaiToLiquidity(toBurn, dex);
            emit ReserveBurned(ua, toBurn);
        }
    }

    function _consumeReserveTickets(address ua, uint256 amountToConsume) internal {
        // delegated to external ReserveLib — bytecode moved out of StepNet
        ReserveLib.consume(reserveTickets, reserveTicketHead, ua, amountToConsume);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  processDaily — single, resumable daily-distribution routine.
    //
    //  Each invocation does as much work as gas allows and persists a cursor
    //  to storage. A keeper calls the function once per
    //  DAILY_DISTRIBUTION_INTERVAL; if a single transaction cannot complete
    //  the cycle, the next invocation resumes from the saved cursor.
    //
    //  globalCycleStep semantics:
    //    0   ready / "too early" gate / cycle start
    //    1   flush pendingUpdates for all tiers
    //    2   process tier 0
    //    3   process tier 1
    //    ...
    //    7   process tier 5
    //    8   cycle complete — emit event, reset state
    // ═══════════════════════════════════════════════════════════════════════════
function processDaily() external nonReentrant {

    if (globalCycleStep == 0) {
        if (block.timestamp < pools[0].lastDistributionTime + DAILY_DISTRIBUTION_INTERVAL) {
            revert TooEarly();
        }
        globalCycleStartedAt  = block.timestamp;
        globalCycleTotalUsers = activeUsers.length;

        uint256 snapPrice = 0;
        if (initialized) {
            try _dex().getPrice() returns (uint256 p) { snapPrice = p; } catch {}
        }
        cycleStepPriceSnapshot = snapPrice;

        for (uint256 b = 0; b < BOX_COUNT; b++) {
            // Snapshot the per-tier dirty window. Only uplines whose box-`b`
            // counters changed since the last box-`b` distribution are here;
            // entries pushed after this point (mid-cycle activations) sit
            // beyond the snapshot and are processed in the next cycle.
            cycleTotalUsers[b] = dirtyUsers[b].length;
            cycleStartedAt[b]  = block.timestamp;
            dailyPhase[b]      = 0;
            dailyCursor[b]     = 0;
            dailyTotalPoints[b] = 0;
            lastRoundBurnedPointsPerBox[b] = 0;
        }
        globalCycleStep = 1;
        emit CycleStarted(globalCycleStartedAt, globalCycleTotalUsers, snapPrice);
    }

    if (globalCycleStep == 1) {
        // Dynamic safety-gas: PendingLib.processBatch propagates up to 15
        // levels per user (~30-50k gas each); the reserve is scaled with
        // how much of the batch is still pending.
        bool allClear = true;

        for (uint256 b = 0; b < BOX_COUNT; b++) {
            while (pendingUpdates[b].length > 0) {
                uint256 safetyGas = _dynamicSafetyGasUpdates(pendingUpdates[b].length, 150);
                if (gasleft() < safetyGas) return;
                PendingLib.processBatch(
                    users, pendingUpdates, pendingUpdateIndex,
                    lastUpdatedUpline, lastUpdatedChild,
                    dirtyUsers, dirtyIndex,
                    box0LeftSubtree, box0RightSubtree,
                    b, 150
                );
            }
            if (pendingUpdates[b].length > 0) { allClear = false; break; }
        }
        if (!allClear) return;
        globalCycleStep = 2;
    }

    while (globalCycleStep >= 2 && globalCycleStep < BOX_COUNT + 2) {
        uint256 boxId = globalCycleStep - 2;
        bool done = _processDailyBox(boxId);
        if (!done) return;
        globalCycleStep++;
    }

    if (globalCycleStep == BOX_COUNT + 2) {
        pools[0].lastDistributionTime = block.timestamp;
        emit DailyCycleComplete(globalCycleStartedAt, globalCycleTotalUsers);
        globalCycleStep       = 0;
        globalCycleStartedAt  = 0;
        globalCycleTotalUsers = 0;
    }
}

function _processDailyBox(uint256 boxId) internal returns (bool) {
    BoxPool storage pool = pools[boxId];
    uint256 totalUsers = cycleTotalUsers[boxId];

    if (dailyPhase[boxId] == 0) {
        // Phase 0 (tally owners' capped points + burn non-owner counters) is
        // delegated to PendingLib to keep this contract under the EIP-170 cap.
        // Identical state writes / events / gas checkpoint; returns false if it
        // yielded mid-window.
        if (!PendingLib.distPhase0(
                dirtyUsers, users, dailyTotalPoints, dailyCursor, dirtyIndex,
                lastRoundBurnedPointsPerBox, boxId, totalUsers
            )) return false;

        if (dailyTotalPoints[boxId] > 0 && pool.accumulatedDai > 0) {
            pool.pointPriceThisCycle = (pool.accumulatedDai * 1e18) / dailyTotalPoints[boxId];
        } else {
            pool.pointPriceThisCycle = 0;
        }
        dailyPhase[boxId] = 1;
        dailyCursor[boxId] = 0;
    }

    if (dailyPhase[boxId] == 1) {
        IStepDex cachedDex = _dex();
        uint256 pointPrice = pool.pointPriceThisCycle;
        uint256 currentStepPrice = cycleStepPriceSnapshot;

        while (dailyCursor[boxId] < totalUsers) {
            // Phase 1: reward distribution — the heaviest phase. Includes
            // DEX getPrice, token transfers, event emits, and (tier 0)
            // expired-reserve burning. Safety reserve scales with the
            // current subscriber's queue depth.
            uint256 remaining = totalUsers - dailyCursor[boxId];
            uint256 safetyGas = _dynamicSafetyGasReward(remaining);
            if (gasleft() < safetyGas && remaining > 6) return false;

            address ua = dirtyUsers[boxId][dailyCursor[boxId]];
            User storage u = users[ua];

            if (u.boxPurchasedCount[boxId] == 0) {
                unchecked { dailyCursor[boxId]++; }
                continue;
            }

            uint256 l = u.teamLeftCount[boxId];
            uint256 r = u.teamRightCount[boxId];
            uint256 weak = _weaker(l, r);
            uint256 pts = weak > DAILY_CAP ? DAILY_CAP : weak;

            if (pts > 0) {
                uint256 dai_ = (pts * pointPrice) / 1e18;
                uint256 reserve = (dai_ * UPGRADE_RESERVE_PCT) / 100;

                u.totalCommissionDai += dai_;
                if (currentStepPrice > 0) {
                    u.stepEquivFromBoxes += (dai_ * 1e18) / currentStepPrice;
                }
                pendingBoxDaiRewards[ua][boxId] += dai_ - reserve;

                if (_getHighestBox(ua) >= 5) {
                    if (reserve > 0) _donateDaiToLiquidity(reserve, cachedDex);
                } else {
                    u.reservedForUpgrade += reserve;
                    reserveTickets[ua].push(ReserveLib.ReserveTicket({amount: reserve, addedAt: block.timestamp}));
                    if (u.reserveCycleStart == 0) u.reserveCycleStart = block.timestamp;
                    _addReserveUser(ua); // track for the Box-0 expired-reserve sweep
                }

                emit PointsClaimed(ua, boxId, pts, dai_);
                if (u.reservedForUpgrade > 0) _markPendingUpgrade(ua);

                if (l == r) {
                    u.teamLeftCount[boxId] = 0;
                    u.teamRightCount[boxId] = r - pts;
                } else if (l < r) {
                    u.teamLeftCount[boxId] = 0;
                    u.teamRightCount[boxId] = r - pts;
                } else {
                    u.teamLeftCount[boxId] = l - pts;
                    u.teamRightCount[boxId] = 0;
                }

                uint256 burnedExcess = weak > DAILY_CAP ? weak - DAILY_CAP : 0;
                lastDailyBurnedPointsUser[ua][boxId] = burnedExcess;
                lastRoundBurnedPointsPerBox[boxId] += burnedExcess;
                emit DailyPointsBurned(ua, boxId, burnedExcess);

                if (u.inStepClub) _checkAndExitClub(ua);
            }

            unchecked { dailyCursor[boxId]++; }
        }

        if (dailyCursor[boxId] < totalUsers) return false;

        if (boxId == 0) {
            // Box 0 has an extra phase: the expired-reserve sweep. Transition
            // to it instead of finalizing here.
            dailyPhase[0]  = 2;
            dailyCursor[0] = 0;
        } else {
            _finalizeDailyBox(boxId);
            return true;
        }
    }

    // ── Phase 2 (Box 0 only): expired-reserve sweep ─────────────────────────
    //  Runs `_checkAndBurnExpiredReserve` over the subscribers that actually
    //  hold a reserve, rather than every active subscriber. Iteration order is
    //  irrelevant to the economic output: a freshly-added reserve cannot be
    //  expired, and burns are independent across subscribers.
    if (boxId == 0 && dailyPhase[0] == 2) {
        IStepDex sweepDex = _dex();
        while (dailyCursor[0] < reserveUsers.length) {
            uint256 remaining = reserveUsers.length - dailyCursor[0];
            if (gasleft() < 200_000 && remaining > 6) return false;
            address ra = reserveUsers[dailyCursor[0]];
            User storage ru = users[ra];
            _checkAndBurnExpiredReserve(ra, ru, sweepDex);
            if (ru.reservedForUpgrade == 0) {
                _removeReserveUserAt(dailyCursor[0], ra); // swap-pop; do NOT advance
            } else {
                unchecked { dailyCursor[0]++; }
            }
        }
        _finalizeDailyBox(0);
    }

    return true;
}

    function _markPendingUpgrade(address ua) internal {
        PendingLib.markPendingUpgrade(users, hasPendingUpgrade, pendingUpgradeList, pendingUpgradeIndex, ua);
    }

    /**
     * @notice Promote queued subscribers to their next tier when their
     *         accumulated upgrade reserve covers the tier price.
     * @dev    Per-entry pre-check + state-correction semantics: a queued
     *         subscriber whose reserve was spent elsewhere is simply
     *         removed from the queue without consuming the upgrade budget;
     *         they will be re-queued by the next daily distribution if
     *         their reserve is replenished.
     */
    function processAutoUpgrades() external nonReentrant {
        uint256 len = pendingUpgradeList.length;
        if (len == 0) revert NoPendingUpgrades();

        uint256 maxBatch = 250;
        uint256 upgradeCount = 0;
        uint256 cleanedCount = 0;

        while ((upgradeCount + cleanedCount) < maxBatch && len > 0) {
            address ua = pendingUpgradeList[len - 1];
            User storage u = users[ua];

            // Pre-check: can this subscriber actually be upgraded right now?
            bool canUpgrade = false;
            for (uint256 i = 0; i < 5;) {
                if (u.boxPurchasedCount[i] > 0 && u.boxPurchasedCount[i+1] == 0) {
                    if (u.reservedForUpgrade >= _boxPrice(uint8(i+1))) {
                        canUpgrade = true;
                    }
                    break;
                }
                unchecked { ++i; }
            }

            // Always pop so the loop advances; a non-upgradeable subscriber
            // simply leaves the queue and is re-marked by the next daily
            // distribution if their reserve later covers the upgrade.
            pendingUpgradeList.pop();
            len--;
            hasPendingUpgrade[ua] = false;
            pendingUpgradeIndex[ua] = 0;

            if (canUpgrade) {
                _executeAutoUpgrade(ua);
                unchecked { ++upgradeCount; }
            } else {
                unchecked { ++cleanedCount; }
            }
        }

        // Only revert if nothing at all happened (neither an upgrade nor a
        // queue cleanup). State-mutating successful paths always commit.
        if (upgradeCount == 0 && cleanedCount == 0) revert NoPendingUpgrades();
    }

    /// @dev Per-call ceiling on tier upgrades for a single subscriber. Each
    ///      activation includes a DEX swap and up to four transfers; this
    ///      cap prevents a wallet with a very deep upgrade reserve from
    ///      crossing the block gas limit in a single `_executeAutoUpgrade`
    ///      invocation. The remainder is re-queued for the next call.
    uint256 private constant MAX_UPGRADES_PER_CALL = 2;

    function _executeAutoUpgrade(address ua) internal {
        _compactReserveTickets(ua);        // automatic

        User storage u = users[ua];
        uint256 done = 0;
        for (uint256 i = 0; i < 5 && done < MAX_UPGRADES_PER_CALL;) {
            if (u.boxPurchasedCount[i] > 0 && u.boxPurchasedCount[i+1] == 0) {
                uint256 np = _boxPrice(uint8(i+1));
                if (u.reservedForUpgrade >= np) {
                    u.reservedForUpgrade -= np;
                    _consumeReserveTickets(ua, np);
                    _activateBoxInternal(ua, i+1, np, address(0));
                    emit AutoUpgrade(ua, i+1);
                    unchecked { ++done; }
                } else {
                    // Stop at the first tier whose reserve falls short.
                    // A later call resumes once the reserve is replenished.
                    break;
                }
            }
            unchecked { ++i; }
        }

        // If further upgrades remain feasible, keep the subscriber in the
        // queue so the next call to processAutoUpgrades resumes from here.
        if (done == MAX_UPGRADES_PER_CALL) _markPendingUpgrade(ua);
    }

    /// @dev Closes a tier's daily cycle. Emits one of two events depending
    ///      on whether any redistribution occurred; the no-activity event
    ///      gives indexers a clear signal that the keeper ran but the tier
    ///      had no eligible subscribers. Accumulated DAI carries forward.
    function _finalizeDailyBox(uint256 boxId) internal {
        BoxPool storage pool = pools[boxId];
        if (dailyTotalPoints[boxId] > 0) {
            lastRoundRewardPerBox[boxId] = pool.accumulatedDai;
            emit DailyPoolDistributed(boxId, pool.accumulatedDai, pool.pointPriceThisCycle);
            pool.accumulatedDai = 0;
        } else {
            // Preserve the original event semantics: "total subscribers" snapshot.
            emit BoxProcessedNoActivity(boxId, globalCycleTotalUsers, pool.accumulatedDai);
        }
        // Drop this cycle's processed dirty window; mid-cycle additions survive.
        _clearDirtyBox(boxId, cycleTotalUsers[boxId]);
        pool.lastDistributionTime = block.timestamp;
        dailyPhase[boxId] = 0;
        dailyCursor[boxId] = 0;
        dailyTotalPoints[boxId] = 0;
        cycleStartedAt[boxId] = 0;
        cycleTotalUsers[boxId] = 0;
    }

    /**
     * @notice Convert the caller's accumulated DAI rewards for a tier into
     *         STEP at the current AMM price and transfer the resulting
     *         tokens to the caller's wallet.
     */
    function withdrawAllBoxReward(uint256 boxId) external nonReentrant validWallet {
        if (boxId >= BOX_COUNT) revert InvalidBox();

        _compactReserveTickets(msg.sender);
        _checkAndBurnExpiredReserve(msg.sender, users[msg.sender], IStepDex(address(0)));
        uint256 daiAmt = pendingBoxDaiRewards[msg.sender][boxId];
        if (daiAmt == 0) revert NoReward();
        pendingBoxDaiRewards[msg.sender][boxId] = 0;
        IStepCoin stepToken = _step();
        uint256 minted = _buyStepWithDaiToken(daiAmt, stepToken);
        if (minted == 0) revert MintFailed();
        IERC20(address(stepToken)).safeTransfer(msg.sender, minted);
        emit BoxRewardsWithdrawn(msg.sender, boxId, minted);
    }

    // Club interactions (claim / exit) are made directly on StepClub.

    // ─── TREE PROPAGATION ────────────────────────────────────────────────────
    //  Heavy propagation logic is delegated to PendingLib (DELEGATECALL) so
    //  storage and events remain under this contract while keeping deployed
    //  bytecode under the EIP-170 limit.

    function processAllPendingUpdates(uint256 maxUsersPerBox) external nonReentrant {
        if (maxUsersPerBox == 0) maxUsersPerBox = 200;
        bool hasWork = false;
        for (uint256 b = 0; b < BOX_COUNT; b++) {
            if (pendingUpdates[b].length > 0) {
                hasWork = true;
                break;
            }
        }
        if (!hasWork) revert NoPendingUpdates();

        for (uint256 boxId = 0; boxId < BOX_COUNT; boxId++) {
            if (pendingUpdates[boxId].length > 0) {
                PendingLib.processBatch(
                    users, pendingUpdates, pendingUpdateIndex,
                    lastUpdatedUpline, lastUpdatedChild,
                    dirtyUsers, dirtyIndex,
                    box0LeftSubtree, box0RightSubtree,
                    boxId, maxUsersPerBox
                );
            }
        }
    }

    // Note: propagation / batch-update / pending-removal logic lives in
    // PendingLib; call-sites invoke `PendingLib.propagate` and
    // `PendingLib.processBatch` directly.

    function processExpiredReserves(uint256 maxUsers) external nonReentrant {
        if (maxUsers == 0) maxUsers = 250;

        bool hasWork = false;
        uint256 start = reserveBurnCursor;
        uint256 end = start + maxUsers;
        if (end > activeUsers.length) end = activeUsers.length;

        IStepDex dex = _dex();

        for (uint256 i = start; i < end;) {
            address ua = activeUsers[i];
            if (users[ua].reservedForUpgrade > 0) {
                _checkAndBurnExpiredReserve(ua, users[ua], dex);
                hasWork = true;
            }
            unchecked { ++i; }
        }

        reserveBurnCursor = end;

        if (!hasWork && end >= activeUsers.length) {
            reserveBurnCursor = 0;
            revert NoExpiredReserves();
        }

        if (end >= activeUsers.length) {
            reserveBurnCursor = 0;
        }
    }

    // ─── Initial state import ───────────────────────────────────────────
    //  For deployments that migrate from a previous instance, the deployer
    //  may grant one external "Importer" contract permission to seed user
    //  state. This is a one-shot, deployer-only operation that can only
    //  happen pre-finalize.

    function setImporter(address _imp) external {
        if (msg.sender != originalDeployer) revert OnlyOriginalDeployer();
        if (initialized) revert AlreadyInitialized();
        if (importer != address(0)) revert ImporterAlreadySet();
        if (_imp == address(0)) revert ZeroAddress();
        importer = _imp;
    }

    modifier onlyImporter() {
        if (msg.sender != importer) revert OnlyImporter();
        _;
    }

    /// @notice Seed a single subscriber's state during the import window.
    ///         Called by `StepNetImporter` once per exported record.
    function importSingleUser(ImportUserData calldata d) external onlyImporter {
        if (initialized) revert AlreadyInitializedCannotImport();
        if (block.timestamp > deployedAt + IMPORT_WINDOW) revert ImportWindowClosed();

        address ua = d.ua;
        if (ua == address(0)) return;
        // Founder/root is pre-seeded in the constructor (box0 = 1); record its two
        // children here. Any other already-registered address is a duplicate import.
        if (users[ua].boxPurchasedCount[0] > 0) {
            if (ua == originalDeployer) { users[ua].left = d.left; users[ua].right = d.right; }
            return;
        }

        // The bulk per-field writes run in ImportLib via DELEGATECALL so this
        // write-heavy bytecode stays off StepNet (EIP-170 cap). Called once per
        // subscriber inside the import window, so the call overhead is moot.
        ImportLib.writeUser(users, userName, pendingBoxDaiRewards, d);

        // Seed the touched-set so the first post-import distribution sees these
        // subscribers: an importee with pre-existing team counts must be tallied
        // (if they own the tier) or burned (if they do not). Without this seed
        // they would stay invisible to the dirty-set routine until a fresh
        // downline activation re-marked them.
        for (uint256 b = 0; b < BOX_COUNT; b++) {
            if (d.teamLeftCount[b] > 0 || d.teamRightCount[b] > 0) {
                _markDirty(b, ua);
            }
        }
        // An importee carrying a pre-existing upgrade reserve must also enter
        // the reserve set so the Box-0 phase-2 sweep can later expire it.
        if (d.reservedForUpgrade > 0) _addReserveUser(ua);

        // only for addresses that were genuinely club members
        if (d.inStepClub) {
             _club().importMember(ua, d.pendingClubReward, d.clubJoinedAfterDistCount);
        }

        if (!processed[ua]) {
            processed[ua] = true;
            activeUsersIndex[ua] = activeUsers.length + 1;
            activeUsers.push(ua);
        }
        if (d.boxPurchasedCount[0] > 0) {
            unchecked { ++activeBox0Count; }
        }
    }

    // ─── DAO interface ─────────────────────────────────────────────────────
    /// @notice True when `user` has activated the Box-0 subscription tier.
    ///         Used by the registry as the voter-eligibility gate.
    function hasBox0(address user) external view returns (bool) {
        return users[user].boxPurchasedCount[0] > 0;
    }
    /// @notice True when `user` has activated the Box-5 (top) subscription
    ///         tier. The registry requires this for proposal creation —
    ///         the financial commitment of reaching Box 5 makes spam
    ///         proposals economically irrational.
    function hasBox5(address user) external view returns (bool) {
        return users[user].boxPurchasedCount[5] > 0;
    }
    function getActiveBox0Count() external view returns (uint256) {
        return activeBox0Count;
    }
    function getActiveUsersCount() external view returns (uint256) {
        return activeUsers.length;
    }

    /// @notice Returns the smaller of `box0LeftSubtree[ua]` and
    ///         `box0RightSubtree[ua]`, which together with the +1 self
    ///         vote forms the on-chain voting weight in the registry.
    function getBox0SubtreeWeakerSide(address ua) external view returns (uint256) {
        uint256 l = box0LeftSubtree[ua];
        uint256 r = box0RightSubtree[ua];
        return l < r ? l : r;
    }

    /// @notice Raw permanent Box-0 subtree counters (left, right) accumulated
    ///         since deployment for `ua`. Unlike the per-day team counts these
    ///         are never decremented, so they are the all-time totals. Returned
    ///         as a single SLOAD pair to keep added bytecode minimal.
    function getBox0Subtree(address ua) external view returns (uint256 left, uint256 right) {
        return (box0LeftSubtree[ua], box0RightSubtree[ua]);
    }

    /**
     * @notice One-shot backfill used after an initial-state import to
     *         compute the permanent Box-0 subtree counters from the
     *         imported users' upline relationships.
     * @dev    Only the deployer may call it, and only before finalize.
     *         Idempotent: re-runs on the same range have no effect because
     *         propagation walks from the newly-imported subscriber upward.
     */
    function rebuildBox0Subtree(uint256 startIdx, uint256 endIdx) external {
        if (msg.sender != originalDeployer) revert OnlyOriginalDeployer();
        if (initialized) revert AlreadyInitialized();
        PendingLib.rebuildBox0SubtreeBatch(
            users, activeUsers, box0LeftSubtree, box0RightSubtree, startIdx, endIdx
        );
    }

    // VIEW: box arrays (the struct auto-getter does not return array fields)
    function getBoxData(address ua) external view returns (
        uint256[6] memory boxPurchasedCount,
        uint256[6] memory teamLeftCount,
        uint256[6] memory teamRightCount,
        uint256[6] memory totalPaidPerBox
    ) {
        User storage u = users[ua];
        return (u.boxPurchasedCount, u.teamLeftCount, u.teamRightCount, u.totalPaidPerBox);
    }

    // KEEPER WRAPPERS: for StepNetView.burnExpiredReservesBatch
    function checkAndBurnExpiredReserve(address ua) external nonReentrant {
        _checkAndBurnExpiredReserve(ua, users[ua], IStepDex(address(0)));
    }

    // ─── O(1) length getters for off-chain pagination ─────────────────────
    function getReserveTicketsLength(address ua) external view returns (uint256) {
        return reserveTickets[ua].length;
    }
    function getPendingUpgradeListLength() external view returns (uint256) {
        return pendingUpgradeList.length;
    }
    function getPendingUpdatesLength(uint256 boxId) external view returns (uint256) {
        return pendingUpdates[boxId].length;
    }
    function getUserStartTimestamp(address ua) external view returns (uint256) {
        return users[ua].startTimestamp;
    }


    /**
     * @notice DAO-gated asset migration. Transfers the liquid DAI + STEP
     *         held by this contract to a successor address. May only be
     *         invoked by the registry as part of a passed migration
     *         proposal that has cleared its veto window and timelock.
     *         Subscriber state (referral graph, balances, etc.) is moved
     *         via the separate `StepNetImporter` flow.
     */
    event AssetsMigrated(address indexed to, uint256 daiAmount, uint256 stepAmount);

    function migrateAssetsTo(address newContract) external {
        if (msg.sender != address(REGISTRY)) revert NotRegistry();
        if (newContract == address(0)) revert ZeroAddress();
        IStepCoin step = _step();
        uint256 daiBal  = DAI.balanceOf(address(this));
        uint256 stepBal = step.balanceOf(address(this));
        if (daiBal  > 0) DAI.safeTransfer(newContract, daiBal);
        if (stepBal > 0) IERC20(address(step)).safeTransfer(newContract, stepBal);
        emit AssetsMigrated(newContract, daiBal, stepBal);
    }
}
