// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

/**
 * @title  StepNetView
 * @notice Aggregating read-only contract over the Step Ecosystem. Bundles
 *         dashboard data, leaderboard snapshots, and DAO-facing weight
 *         queries into a small number of view calls so dApp front-ends
 *         can render a full subscriber experience with one or two RPCs
 *         instead of dozens.
 *
 *         Also serves as the registry's stepNetView pointer for
 *         DAO-eligibility queries: the registry routes voter checks,
 *         proposer eligibility, and weight calculation through this
 *         contract, which forwards (with safe fallbacks) to the
 *         registry-current StepNet.
 */

// ══════════════════════════════════════════════════════════════════════════════
//  INTERFACES
// ══════════════════════════════════════════════════════════════════════════════

interface IRegistry {
    function get(bytes32 key) external view returns (address);
    function KEY_STEP_COIN()     external view returns (bytes32);
    function KEY_STEP_DEX()      external view returns (bytes32);
    function KEY_NFT_TREASURY()  external view returns (bytes32);
    function KEY_CLUB_TREASURY() external view returns (bytes32);
}

interface IStepNet {
    function getUserStartTimestamp(address ua) external view returns (uint256);
    /// @dev Auto-getter for the public `users` mapping. Matches the
    ///      observable ABI of the deployed StepNet; array fields are
    ///      surfaced separately via `getBoxData`.
    function users(address ua) external view returns (
        uint256 totalPaidAllBoxes,
        address upline,
        address left,
        address right,
        uint256 totalCommissionDai,
        uint256 reservedForUpgrade,
        uint256 stepReceivedFromClub,
        uint256 amountBurnedStepClub,
        uint256 totalBurnedByUser,
        bool    inStepClub,
        uint256 startTimestamp,
        uint256 reserveCycleStart,
        uint256 clubJoinedTimestamp,
        uint256 stepBurnedFromClub
    );
    /// Cap-accounting bundle in a single call (used by the Club).
    function getUserClubData(address ua) external view returns (
        uint256 totalPaidAllBoxes,
        uint256 totalCommissionDai,
        uint256 stepReceivedFromClub,
        uint256 stepBurnedFromClub,
        bool    inStepClub,
        uint256 stepEquivFromBoxes
    );
    /// Reward pools and distribution state.
    function pendingBoxDaiRewards(address ua, uint256 boxId) external view returns (uint256);
    function pools(uint256 boxId) external view returns (
        uint256 accumulatedDai,
        uint256 lastDistributionTime,
        uint256 pointPriceThisCycle
    );
    function lastRoundRewardPerBox(uint256 boxId) external view returns (uint256);
    function lastRoundBurnedPointsPerBox(uint256 boxId) external view returns (uint256);
    function lastDailyBurnedPointsUser(address ua, uint256 boxId) external view returns (uint256);
    function dailyPhase(uint256 boxId) external view returns (uint256);
    function dailyCursor(uint256 boxId) external view returns (uint256);
    function dailyTotalPoints(uint256 boxId) external view returns (uint256);
    /// Reserve ticket queues.
    function reserveTickets(address ua, uint256 idx) external view returns (uint256 amount, uint256 addedAt);
    function reserveTicketHead(address ua) external view returns (uint256);
    /// Subscriber registry.
    function activeUsers(uint256 idx) external view returns (address);
    function getActiveUsersCount() external view returns (uint256);
    function activeBox0Count() external view returns (uint256);
    /// Deferred-work queues.
    function pendingUpgradeList(uint256 idx) external view returns (address);
    function hasPendingUpgrade(address ua) external view returns (bool);
    function pendingUpdates(uint256 boxId, uint256 idx) external view returns (address);
    /// Identity / config getters.
    function userName(address ua) external view returns (string memory);
    function walletChangeCount(address ua) external view returns (uint256);
    function oldToNewWallet(address ua) external view returns (address);
    function newToOldWallet(address ua) external view returns (address);
    function initialized() external view returns (bool);
    function deployedAt() external view returns (uint256);
    function REGISTRY() external view returns (address);
    function hasBox0(address user) external view returns (bool);
    function hasBox5(address user) external view returns (bool);
    function getActiveBox0Count() external view returns (uint256);
    /// Permanent Box-0 subtree counter used for DAO voting weight.
    function getBox0SubtreeWeakerSide(address user) external view returns (uint256);
    /// Raw all-time left/right Box-0 subtree counters.
    function getBox0Subtree(address user) external view returns (uint256 left, uint256 right);
    /// Per-subscriber tier arrays.
    function getBoxData(address ua) external view returns (
        uint256[6] memory boxPurchasedCount,
        uint256[6] memory teamLeftCount,
        uint256[6] memory teamRightCount,
        uint256[6] memory totalPaidPerBox
    );
}

interface IStepClub {
    function livePool() external view returns (uint256);
    function memberCount() external view returns (uint256);
    function roundCount() external view returns (uint256);
    function lastDistributionTime() external view returns (uint256);
    function pendingBurnDeadline() external view returns (uint256);
    function distInProgress() external view returns (bool);
    function totalDonated() external view returns (uint256);
    function isMember(address ua) external view returns (bool);
    function pendingRewards(address ua) external view returns (uint256);
    function totalReceivedStep(address ua) external view returns (uint256);
    function totalBurnedStep(address ua) external view returns (uint256);
    function DISTRIBUTION_INTERVAL() external view returns (uint256);
    function CLAIM_DEADLINE() external view returns (uint256);
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
    );
    function getClubTimerData(address ua) external view returns (
        uint256 nextClubDist,
        uint256 clubTimeLeft,
        uint256 clubBurnAt,
        uint256 clubBurnLeft,
        uint256 clubPending,
        uint256 clubBurned
    );
    function getClubStats() external view returns (
        uint256 _memberCount,
        uint256 _roundCount,
        uint256 _livePool,
        uint256 nextDist,
        uint256 timeLeft
    );
    function getClubPendingReward(address ua) external view returns (uint256);
}

interface INFTTreasury {
    function nextId() external view returns (uint256);
    function nftRewardPool() external view returns (uint256);
    function totalPendingRewards() external view returns (uint256);
    function lastDistributionTime() external view returns (uint256);
    function distInProgress() external view returns (bool);
    function TOTAL_SUPPLY() external view returns (uint256);
    function DISTRIBUTION_INTERVAL() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function pendingOf(address user) external view returns (uint256);
    function totalClaimed(address user) external view returns (uint256);
    function totalBurnedNFT(address user) external view returns (uint256);
    function getTimeUntilNextDistribution() external view returns (uint256);
    function getUserDashboard(address user) external view returns (
        uint256 timeUntilNextDist,
        uint256 timeUntilClaimDeadline,
        bool    claimWindowExpired,
        uint256 pendingStep,
        uint256 totalClaimedStep,
        uint256 totalBurnedStep,
        uint256 rewardPoolBalance
    );
}

interface IStepDex {
    function getPrice() external view returns (uint256);
    function daiReserve() external view returns (uint256);
    function estimateBuy(uint256 daiAmount) external view returns (uint256 stepOut);
    function estimateSell(uint256 stepAmount) external view returns (uint256 daiOut);
    function isInitialized() external view returns (bool);
}

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IStepNetKeeper {
    function checkAndBurnExpiredReserve(address ua) external;
}

// ══════════════════════════════════════════════════════════════════════════════
//  RETURN STRUCTS
// ══════════════════════════════════════════════════════════════════════════════

struct BoxData {
    uint256[6] owned;               // boxPurchasedCount
    uint256[6] teamLeft;            // teamLeftCount
    uint256[6] teamRight;           // teamRightCount
    uint256[6] pendingDai;
    uint256[6] lastReward;
    uint256[6] lastBurnedPts;
    uint256[6] lastPointValue;
    uint256    totalCommDai;
    uint256    totalBurned;
    uint256    stepFromClub;
    uint256    stepBurnedFromClub;
    bool       inClub;
    address    upline;
    uint256    startTimestamp;
    uint256    reservedForUpgrade;
    uint256    uniqueLeft;          // from getBoxData()
    uint256    uniqueRight;         // from getBoxData()
    uint256    totalPaidAllBoxes;   // lets the frontend derive isOwned without an extra call
}

struct ClubData {
    bool    isMember;
    uint256 pending;
    uint256 totalReceived;
    uint256 totalBurnedStep;
    uint256 livePool;
    uint256 memberCount;
    uint256 roundCount;
    uint256 nextDistAt;
    uint256 timeLeft;
    uint256 burnDeadline;
    uint256 burnTimeLeft;
}

struct NFTData {
    uint256   count;
    uint256   pendingStep;
    uint256   totalClaimed;
    uint256   totalBurned;
    uint256   rewardPool;
    uint256   timeToNextDist;
    uint256   timeToDeadline;
    bool      claimExpired;
    bool      distInProgress;
    uint256   nftNextId;
    uint256[] tokenIds;
}

struct MarketData {
    uint256 stepPrice;
    uint256 daiReserve;
    uint256 stepTotalSupply;
    uint256 daiBalance;
    uint256 stepBalance;
}

struct TimerData {
    uint256 nextBoxDistAt;
    uint256 boxTimeLeft;
    bool    boxReady;
    uint256 resBurnAt;
    uint256 resTimeLeft;
    uint256 ticketCount;
    uint256 totalReserved;
}

struct DashboardResult {
    BoxData    box;
    ClubData   club;
    NFTData    nft;
    MarketData market;
    TimerData  timer;
    string     communityMessage;
    string     communityMessageIPFS;
    uint256    activeUsersCount;
    string     name;
}

struct GlobalStats {
    uint256    activeUsersCount;
    uint256    activeBox0Count;
    uint256    stepTotalSupply;
    uint256    stepPrice;
    uint256    daiReserve;
    uint256    nftNextId;
    uint256    nftTotalSupply;
    uint256    nftRewardPool;
    uint256    clubMemberCount;
    uint256    clubRoundCount;
    uint256    clubLivePool;
    uint256    nextBoxDistAt;
    uint256    boxTimeLeft;
    bool       boxReady;
    uint256[6] poolAccumulated;
    uint256[6] lastRoundReward;
    bool       importWindowOpen;
    uint256    importWindowCloseAt;
    string     communityMessage;
    string     communityMessageIPFS;
}

struct HolderInfo {
    address user;
    uint256 totalPaid;
    uint256 highestBox;
    uint256 uniqueTeamLeft;
    uint256 uniqueTeamRight;
    uint256 weakerLeg;
    uint256 totalCommDai;
    bool    inClub;
    string  name;
}

// ══════════════════════════════════════════════════════════════════════════════
//  CONTRACT
// ══════════════════════════════════════════════════════════════════════════════

contract StepNetView {

    IStepNet public immutable NET;
    address  public immutable DAI;

    address public messageAdmin;
    string  public communityMessage;
    string  public communityMessageIPFS;

    uint256 private constant BOX_COUNT             = 6;
    uint256 private constant RESERVE_BURN_INTERVAL = 90 days;
    uint256 private constant DAILY_DIST_INTERVAL   = 24 hours;
    uint256 private constant IMPORT_WINDOW         = 2 days;
    uint256 private constant MAX_NFT_IDS           = 150;
    uint256 private constant MAX_NFT_PAGE          = 200;  // per-page cap for getUserNFTIds
    uint256 private constant MAX_TOP_LIMIT         = 100;

    event CommunityMessageUpdated(string newMessage);
    event MessageAdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // Custom errors (cheaper + smaller bytecode than revert strings; identical reverts).
    error ZeroAddress();
    error Unauthorized();
    error InvalidBox();

    constructor(address _net, address _dai, address _messageAdmin) {
        if (_net == address(0) || _dai == address(0) || _messageAdmin == address(0)) revert ZeroAddress();
        NET          = IStepNet(_net);
        DAI          = _dai;
        messageAdmin = _messageAdmin;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function updateCommunityMessage(string calldata msg_, string calldata ipfs_) external {
        if (msg.sender != messageAdmin) revert Unauthorized();
        communityMessage     = msg_;
        communityMessageIPFS = ipfs_;
        emit CommunityMessageUpdated(msg_);
    }

    function transferMessageAdmin(address newAdmin) external {
        if (msg.sender != messageAdmin || newAdmin == address(0)) revert Unauthorized();
        emit MessageAdminTransferred(messageAdmin, newAdmin);
        messageAdmin = newAdmin;
    }

    // ─── Private resolvers ───────────────────────────────────────────────────

    function _reg() private view returns (IRegistry) {
        return IRegistry(NET.REGISTRY());
    }

    function _club() private view returns (IStepClub) {
        IRegistry r = _reg();
        return IStepClub(r.get(r.KEY_CLUB_TREASURY()));
    }

    function _nft() private view returns (INFTTreasury) {
        IRegistry r = _reg();
        return INFTTreasury(r.get(r.KEY_NFT_TREASURY()));
    }

    function _dex() private view returns (IStepDex) {
        IRegistry r = _reg();
        return IStepDex(r.get(r.KEY_STEP_DEX()));
    }

    function _coin() private view returns (IERC20Min) {
        IRegistry r = _reg();
        return IERC20Min(r.get(r.KEY_STEP_COIN()));
    }

    function _weaker(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _ticketLen(address ua) private view returns (uint256 len) {
        len = NET.reserveTicketHead(ua);
        while (true) {
            try NET.reserveTickets(ua, len) returns (uint256, uint256) {
                unchecked { ++len; }
            } catch { break; }
        }
    }

    function _getPrice() private view returns (uint256) {
        try _dex().getPrice() returns (uint256 p) { return p; } catch { return 0; }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ① getMasterDashboard
    // ════════════════════════════════════════════════════════════════════════

    function getMasterDashboard(address ua) external view returns (DashboardResult memory r) {
        r.box   = _buildBoxData(ua);
        r.club  = _buildClubData(ua);
        r.nft   = _buildNFTData(ua);
        r.market = _buildMarketData(ua);
        r.timer = _buildTimerData(ua);
        r.communityMessage     = communityMessage;
        r.communityMessageIPFS = communityMessageIPFS;
        try NET.getActiveUsersCount() returns (uint256 c) { r.activeUsersCount = c; } catch {}
        try NET.userName(ua) returns (string memory n) { r.name = n; } catch {}
    }

    // ─── BoxData builder ─────────────────────────────────────────────────────
    // owned/teamLeft/teamRight come from getBoxData() (not the auto-getter)
    // totalPaidAllBoxes: lets the frontend derive isOwned without an extra call
    function _buildBoxData(address ua) private view returns (BoxData memory b) {
        try NET.users(ua) returns (
            uint256 totalPaidAllBoxes,
            address upline,
            address, address,
            uint256 totalCommissionDai,
            uint256 reservedForUpgrade,
            uint256 stepReceivedFromClub,
            uint256, // amountBurnedStepClub — sourced from StepClub
            uint256 totalBurnedByUser,
            bool    inStepClub,
            uint256 startTimestamp,
            uint256, uint256, uint256
        ) {
            b.totalPaidAllBoxes  = totalPaidAllBoxes;
            b.totalCommDai       = totalCommissionDai;
            b.totalBurned        = totalBurnedByUser;
            b.stepFromClub       = stepReceivedFromClub;
            b.inClub             = inStepClub;
            b.upline             = upline;
            b.startTimestamp     = startTimestamp;
            b.reservedForUpgrade = reservedForUpgrade;
        } catch {}

        // stepBurnedFromClub comes directly from StepClub (the source of truth)
        try _club().totalBurnedStep(ua) returns (uint256 burned) {
            b.stepBurnedFromClub = burned;
        } catch {}

        // fetch box arrays (owned/teamLeft/teamRight)
        // the public getter does not return struct arrays — use getBoxData()
        try NET.getBoxData(ua) returns (
            uint256[6] memory bpc,
            uint256[6] memory tlc,
            uint256[6] memory trc,
            uint256[6] memory
        ) {
            b.owned     = bpc;
            b.teamLeft  = tlc;
            b.teamRight = trc;
            // uniqueLeft/Right = total team on Box 0 (team-health indicator)
            b.uniqueLeft  = tlc[0];
            b.uniqueRight = trc[0];
        } catch {}

        for (uint256 i = 0; i < BOX_COUNT;) {
            try NET.pendingBoxDaiRewards(ua, i) returns (uint256 v) { b.pendingDai[i] = v; } catch {}
            try NET.lastRoundRewardPerBox(i)    returns (uint256 v) { b.lastReward[i] = v; } catch {}
            try NET.lastDailyBurnedPointsUser(ua, i) returns (uint256 v) { b.lastBurnedPts[i] = v; } catch {}
            try NET.pools(i) returns (uint256, uint256, uint256 ptc) { b.lastPointValue[i] = ptc; } catch {}
            unchecked { ++i; }
        }
    }

    // ─── ClubData builder ────────────────────────────────────────────────────
    function _buildClubData(address ua) private view returns (ClubData memory c) {
        IStepClub club = _club();
        try club.getClubDashboard(ua) returns (
            uint256 pool,
            bool    member,
            uint256 received,
            uint256 burned,
            uint256 pending,
            uint256 timeNext,
            uint256 timeDeadline,
            uint256 rCount,
            uint256 mCount
        ) {
            c.isMember        = member;
            c.pending         = pending;
            c.totalReceived   = received;
            c.totalBurnedStep = burned;
            c.livePool        = pool;
            c.memberCount     = mCount;
            c.roundCount      = rCount;
            c.timeLeft        = timeNext;
            c.burnTimeLeft    = timeDeadline;
            c.nextDistAt      = block.timestamp + timeNext;
            try club.pendingBurnDeadline() returns (uint256 bd) { c.burnDeadline = bd; } catch {}
        } catch {
            try club.isMember(ua) returns (bool m) { c.isMember = m; } catch {}
            try club.pendingRewards(ua) returns (uint256 p) { c.pending = p; } catch {}
            try club.totalReceivedStep(ua) returns (uint256 v) { c.totalReceived = v; } catch {}
            try club.totalBurnedStep(ua) returns (uint256 v) { c.totalBurnedStep = v; } catch {}
            try club.livePool() returns (uint256 v) { c.livePool = v; } catch {}
            try club.memberCount() returns (uint256 v) { c.memberCount = v; } catch {}
            try club.roundCount() returns (uint256 v) { c.roundCount = v; } catch {}
            try club.lastDistributionTime() returns (uint256 ldt) {
                uint256 nd = ldt + DAILY_DIST_INTERVAL;
                c.nextDistAt = nd;
                c.timeLeft   = block.timestamp >= nd ? 0 : nd - block.timestamp;
            } catch {}
            try club.pendingBurnDeadline() returns (uint256 bd) {
                c.burnDeadline = bd;
                c.burnTimeLeft = bd > block.timestamp ? bd - block.timestamp : 0;
            } catch {}
        }
    }

    // ─── NFTData builder ─────────────────────────────────────────────────────
    function _buildNFTData(address ua) private view returns (NFTData memory n) {
        INFTTreasury nftC = _nft();

        try nftC.getUserDashboard(ua) returns (
            uint256 timeNext,
            uint256 timeDeadline,
            bool    expired,
            uint256 pending,
            uint256 claimed,
            uint256 burned,
            uint256 poolBal
        ) {
            n.timeToNextDist = timeNext;
            n.timeToDeadline = timeDeadline;
            n.claimExpired   = expired;
            n.pendingStep    = pending;
            n.totalClaimed   = claimed;
            n.totalBurned    = burned;
            n.rewardPool     = poolBal;
        } catch {
            try nftC.pendingOf(ua) returns (uint256 p) { n.pendingStep = p; } catch {}
            try nftC.totalClaimed(ua) returns (uint256 v) { n.totalClaimed = v; } catch {}
            try nftC.totalBurnedNFT(ua) returns (uint256 v) { n.totalBurned = v; } catch {}
            try nftC.nftRewardPool() returns (uint256 v) { n.rewardPool = v; } catch {}
            try nftC.getTimeUntilNextDistribution() returns (uint256 v) { n.timeToNextDist = v; } catch {}
        }

        try nftC.balanceOf(ua) returns (uint256 bal) {
            n.count = bal;
            uint256 toFetch = bal > MAX_NFT_IDS ? MAX_NFT_IDS : bal;
            n.tokenIds = new uint256[](toFetch);
            for (uint256 i = 0; i < toFetch;) {
                try nftC.tokenOfOwnerByIndex(ua, i) returns (uint256 id) {
                    n.tokenIds[i] = id;
                } catch {}
                unchecked { ++i; }
            }
        } catch {
            n.tokenIds = new uint256[](0);
        }

        try nftC.distInProgress() returns (bool d) { n.distInProgress = d; } catch {}
        try nftC.nextId() returns (uint256 v) { n.nftNextId = v; } catch {}
    }

    // ─── Paginated NFT enumeration ───────────────────────────────────────────
    // getMasterDashboard caps token IDs at MAX_NFT_IDS (50) to keep that call
    // cheap. This view lets the dApp page through *all* NFTs for holders with
    // larger collections, one bounded call at a time.
    /// @param owner  NFT owner.
    /// @param offset start index into the owner's enumeration.
    /// @param limit  page size (clamped to MAX_NFT_PAGE).
    /// @return ids   token IDs for [offset, offset+limit).
    /// @return total owner's full NFT balance (so the UI knows the page count).
    function getUserNFTIds(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        INFTTreasury nftC = _nft();
        try nftC.balanceOf(owner) returns (uint256 bal) {
            total = bal;
        } catch {
            return (new uint256[](0), 0);
        }
        if (limit == 0 || limit > MAX_NFT_PAGE) limit = MAX_NFT_PAGE;
        if (offset >= total) return (new uint256[](0), total);

        uint256 end = offset + limit;
        if (end > total) end = total;

        ids = new uint256[](end - offset);
        uint256 k = 0;
        for (uint256 i = offset; i < end;) {
            try nftC.tokenOfOwnerByIndex(owner, i) returns (uint256 id) {
                ids[k] = id;
            } catch {}
            unchecked { ++i; ++k; }
        }
    }

    // ─── MarketData builder ──────────────────────────────────────────────────
    function _buildMarketData(address ua) private view returns (MarketData memory m) {
        IStepDex  dex  = _dex();
        IERC20Min coin = _coin();

        try dex.getPrice() returns (uint256 p) { m.stepPrice = p; } catch {}
        try dex.daiReserve() returns (uint256 v) { m.daiReserve = v; } catch {}
        try coin.totalSupply() returns (uint256 v) { m.stepTotalSupply = v; } catch {}

        if (ua != address(0)) {
            try coin.balanceOf(ua) returns (uint256 v) { m.stepBalance = v; } catch {}
            try IERC20Min(DAI).balanceOf(ua) returns (uint256 v) { m.daiBalance = v; } catch {}
        }
    }

    // ─── TimerData builder ───────────────────────────────────────────────────
    function _buildTimerData(address ua) private view returns (TimerData memory t) {
        try NET.pools(0) returns (uint256, uint256 ldt, uint256) {
            t.nextBoxDistAt = ldt + DAILY_DIST_INTERVAL;
            t.boxTimeLeft   = block.timestamp >= t.nextBoxDistAt ? 0 : t.nextBoxDistAt - block.timestamp;
            t.boxReady      = block.timestamp >= t.nextBoxDistAt;
        } catch {}

        uint256 head = 0;
        uint256 len  = 0;
        try NET.reserveTicketHead(ua) returns (uint256 h) { head = h; } catch {}
        len = _ticketLen(ua);
        t.ticketCount = head < len ? len - head : 0;

        try NET.users(ua) returns (
            uint256,
            address, address, address,
            uint256, uint256 reservedForUpgrade,
            uint256, uint256, uint256, bool, uint256,
            uint256 reserveCycleStart,
            uint256, uint256
        ) {
            t.totalReserved = reservedForUpgrade;
            if (head < len) {
                try NET.reserveTickets(ua, head) returns (uint256, uint256 addedAt) {
                    t.resBurnAt   = addedAt + RESERVE_BURN_INTERVAL;
                    t.resTimeLeft = block.timestamp >= t.resBurnAt ? 0 : t.resBurnAt - block.timestamp;
                } catch {}
            } else if (reserveCycleStart != 0) {
                t.resBurnAt   = reserveCycleStart + RESERVE_BURN_INTERVAL;
                t.resTimeLeft = block.timestamp >= t.resBurnAt ? 0 : t.resBurnAt - block.timestamp;
            }
        } catch {}
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ② getGlobalStats
    // ════════════════════════════════════════════════════════════════════════

    function getGlobalStats() external view returns (GlobalStats memory g) {
        try NET.getActiveUsersCount() returns (uint256 v) { g.activeUsersCount = v; } catch {}
        try NET.getActiveBox0Count()  returns (uint256 v) { g.activeBox0Count  = v; } catch {}

        try _coin().totalSupply() returns (uint256 v) { g.stepTotalSupply = v; } catch {}
        try _dex().getPrice()     returns (uint256 v) { g.stepPrice = v; } catch {}
        try _dex().daiReserve()   returns (uint256 v) { g.daiReserve = v; } catch {}

        INFTTreasury nftC = _nft();
        try nftC.nextId()        returns (uint256 v) { g.nftNextId = v; } catch {}
        try nftC.TOTAL_SUPPLY()  returns (uint256 v) { g.nftTotalSupply = v; } catch {}
        try nftC.nftRewardPool() returns (uint256 v) { g.nftRewardPool = v; } catch {}

        IStepClub club = _club();
        try club.getClubStats() returns (
            uint256 mCnt, uint256 rCnt, uint256 pool, uint256, uint256
        ) {
            g.clubMemberCount = mCnt;
            g.clubRoundCount  = rCnt;
            g.clubLivePool    = pool;
        } catch {
            try club.memberCount() returns (uint256 v) { g.clubMemberCount = v; } catch {}
            try club.roundCount()  returns (uint256 v) { g.clubRoundCount  = v; } catch {}
            try club.livePool()    returns (uint256 v) { g.clubLivePool    = v; } catch {}
        }

        try NET.pools(0) returns (uint256, uint256 ldt, uint256) {
            g.nextBoxDistAt = ldt + DAILY_DIST_INTERVAL;
            g.boxTimeLeft   = block.timestamp >= g.nextBoxDistAt ? 0 : g.nextBoxDistAt - block.timestamp;
            g.boxReady      = block.timestamp >= g.nextBoxDistAt;
        } catch {}

        for (uint256 i = 0; i < BOX_COUNT;) {
            try NET.pools(i) returns (uint256 acc, uint256, uint256) { g.poolAccumulated[i] = acc; } catch {}
            try NET.lastRoundRewardPerBox(i) returns (uint256 v) { g.lastRoundReward[i] = v; } catch {}
            unchecked { ++i; }
        }

        try NET.deployedAt() returns (uint256 da) {
            g.importWindowCloseAt = da + IMPORT_WINDOW;
            g.importWindowOpen    = (!NET.initialized()) && (block.timestamp <= g.importWindowCloseAt);
        } catch {}

        g.communityMessage     = communityMessage;
        g.communityMessageIPFS = communityMessageIPFS;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ③ getTopHolders
    // ════════════════════════════════════════════════════════════════════════

function getTopHolders(
    address net,           // typed as address (not IStepNet) — see LeaderboardLib note
    uint256 limit,
    uint256 offset,
    uint256 maxScan
)
    external view
    returns (HolderInfo[] memory holders, uint256 totalScanned, uint256 nextOffset)
{
    return LeaderboardLib.getTopHolders(net, limit, offset, maxScan); // `net` is the raw address; the library casts it to IStepNet internally
}

    // ════════════════════════════════════════════════════════════════════════
    //  ④ Backward Compatible
    // ════════════════════════════════════════════════════════════════════════

    function getFullUserData(address ua) external view returns (
        uint256[6] memory boxes,
        uint256[6] memory teamLeft,
        uint256[6] memory teamRight,
        uint256[6] memory pendingDai,
        uint256[6] memory lastReward,
        uint256[6] memory lastBurnedPts,
        uint256[6] memory lastPointValue,
        uint256 totalCommDai,
        uint256 clubStep,
        uint256 reserve10,
        bool    inClub,
        uint256 totalBurned,
        uint256 uniqueLeft,
        uint256 uniqueRight
    ) {
        try NET.users(ua) returns (
            uint256,
            address, address, address,
            uint256 commDai, uint256 resv,
            uint256 stepClub, uint256, uint256 tBurned,
            bool isClub, uint256, uint256, uint256, uint256
        ) {
            totalCommDai = commDai;
            clubStep     = stepClub;
            reserve10    = resv;
            inClub       = isClub;
            totalBurned  = tBurned;
        } catch {}

        // box arrays from getBoxData() — the auto-getter omits struct arrays
        try NET.getBoxData(ua) returns (
            uint256[6] memory bpc,
            uint256[6] memory tlc,
            uint256[6] memory trc,
            uint256[6] memory
        ) {
            boxes     = bpc;
            teamLeft  = tlc;
            teamRight = trc;
            uniqueLeft  = tlc[0];
            uniqueRight = trc[0];
        } catch {}

        for (uint256 i = 0; i < BOX_COUNT;) {
            try NET.pendingBoxDaiRewards(ua, i) returns (uint256 v) { pendingDai[i] = v; } catch {}
            try NET.lastRoundRewardPerBox(i) returns (uint256 v) { lastReward[i] = v; } catch {}
            try NET.lastDailyBurnedPointsUser(ua, i) returns (uint256 v) { lastBurnedPts[i] = v; } catch {}
            try NET.pools(i) returns (uint256, uint256, uint256 ptc) { lastPointValue[i] = ptc; } catch {}
            unchecked { ++i; }
        }
    }

    function getNextReserveBurnTime(address ua) external view returns (
        uint256 burnAt, uint256 timeLeft, uint256 ticketCount, uint256 totalReserved
    ) {
        uint256 head = 0;
        try NET.reserveTicketHead(ua) returns (uint256 h) { head = h; } catch {}
        uint256 len = _ticketLen(ua);
        ticketCount = head < len ? len - head : 0;

        try NET.users(ua) returns (
            uint256,
            address, address, address,
            uint256, uint256 reservedForUpgrade,
            uint256, uint256, uint256,
            bool, uint256,
            uint256 reserveCycleStart,
            uint256, uint256
        ) {
            totalReserved = reservedForUpgrade;
            if (head >= len) {
                if (reserveCycleStart == 0) return (0, 0, 0, totalReserved);
                burnAt   = reserveCycleStart + RESERVE_BURN_INTERVAL;
                timeLeft = block.timestamp >= burnAt ? 0 : burnAt - block.timestamp;
                return (burnAt, timeLeft, 0, totalReserved);
            }
        } catch {}

        try NET.reserveTickets(ua, head) returns (uint256, uint256 addedAt) {
            burnAt   = addedAt + RESERVE_BURN_INTERVAL;
            timeLeft = block.timestamp >= burnAt ? 0 : burnAt - block.timestamp;
        } catch {}
    }

    function getBox0Timer() external view returns (
        uint256 nextDistAt, uint256 secondsLeft, uint256 lastDistAt, bool readyToProcess
    ) {
        try NET.pools(0) returns (uint256, uint256 ldt, uint256) {
            lastDistAt     = ldt;
            nextDistAt     = ldt + DAILY_DIST_INTERVAL;
            secondsLeft    = block.timestamp >= nextDistAt ? 0 : nextDistAt - block.timestamp;
            readyToProcess = block.timestamp >= nextDistAt;
        } catch {}
    }

    function getUserDailyBurnedPoints(address ua) external view returns (uint256[6] memory b) {
        for (uint256 i = 0; i < BOX_COUNT;) {
            try NET.lastDailyBurnedPointsUser(ua, i) returns (uint256 v) { b[i] = v; } catch {}
            unchecked { ++i; }
        }
    }

    function getLastPointValue(uint256 boxId) external view returns (
        uint256 pointPriceDai, uint256 totalDaiLastRound, uint256 totalPointsLastRound
    ) {
        if (boxId >= BOX_COUNT) revert InvalidBox();
        try NET.pools(boxId) returns (uint256, uint256, uint256 ptc) { pointPriceDai = ptc; } catch {}
        try NET.lastRoundRewardPerBox(boxId) returns (uint256 v) { totalDaiLastRound = v; } catch {}
        if (pointPriceDai > 0 && totalDaiLastRound > 0) {
            totalPointsLastRound = (totalDaiLastRound * 1e18) / pointPriceDai;
        }
    }

    function getTimersDashboard(address ua) external view returns (
        uint256 nextBoxDist, uint256 boxTimeLeft,
        uint256 nextClubDist, uint256 clubTimeLeft,
        uint256 clubBurnAt, uint256 clubBurnLeft,
        uint256 clubPending, uint256 clubBurned,
        uint256 resBurnAt, uint256 resLeft
    ) {
        try NET.pools(0) returns (uint256, uint256 ldt, uint256) {
            nextBoxDist = ldt + DAILY_DIST_INTERVAL;
            boxTimeLeft = block.timestamp >= nextBoxDist ? 0 : nextBoxDist - block.timestamp;
        } catch {}

        try _club().getClubTimerData(ua) returns (
            uint256 ncd, uint256 ctl, uint256 cba, uint256 cbl, uint256 cp, uint256 cb
        ) {
            nextClubDist = ncd; clubTimeLeft = ctl;
            clubBurnAt   = cba; clubBurnLeft = cbl;
            clubPending  = cp;  clubBurned   = cb;
        } catch {}

        uint256 head = 0;
        try NET.reserveTicketHead(ua) returns (uint256 h) { head = h; } catch {}
        uint256 len = _ticketLen(ua);
        if (head < len) {
            try NET.reserveTickets(ua, head) returns (uint256, uint256 addedAt) {
                resBurnAt = addedAt + RESERVE_BURN_INTERVAL;
            } catch {}
        } else {
            try NET.users(ua) returns (
                uint256, address, address, address,
                uint256, uint256, uint256, uint256, uint256,
                bool, uint256, uint256 rcs, uint256, uint256
            ) {
                if (rcs != 0) resBurnAt = rcs + RESERVE_BURN_INTERVAL;
            } catch {}
        }
        resLeft = (resBurnAt == 0 || block.timestamp >= resBurnAt) ? 0 : resBurnAt - block.timestamp;
    }

    function getActiveUsersPage(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = 0;
        try NET.getActiveUsersCount() returns (uint256 v) { total = v; } catch {}
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new address[](end - offset);
        for (uint256 i = 0; i < end - offset;) {
            try NET.activeUsers(offset + i) returns (address a) { page[i] = a; } catch {}
            unchecked { ++i; }
        }
    }

    function getExpiredReserveUsers(
        uint256 offset, uint256 limit, uint256 maxResults
    ) external view returns (address[] memory expiredUsers, uint256 count, uint256 nextOffset) {
        uint256 total = 0;
        try NET.getActiveUsersCount() returns (uint256 v) { total = v; } catch {}
        if (offset >= total) return (new address[](0), 0, total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        address[] memory buf = new address[](end - offset < maxResults ? end - offset : maxResults);
        count = 0;
        for (uint256 i = offset; i < end && count < maxResults;) {
            address ua;
            try NET.activeUsers(i) returns (address a) { ua = a; } catch { unchecked { ++i; } continue; }

            uint256 resv = 0;
            uint256 rcs  = 0;
            try NET.users(ua) returns (
                uint256, address, address, address,
                uint256, uint256 rv,
                uint256, uint256, uint256, bool, uint256,
                uint256 rc, uint256, uint256
            ) { resv = rv; rcs = rc; } catch {}

            if (resv > 0) {
                uint256 head = 0;
                try NET.reserveTicketHead(ua) returns (uint256 h) { head = h; } catch {}
                bool expired = false;
                try NET.reserveTickets(ua, head) returns (uint256, uint256 addedAt) {
                    expired = block.timestamp >= addedAt + RESERVE_BURN_INTERVAL;
                } catch {
                    if (rcs != 0) expired = block.timestamp >= rcs + RESERVE_BURN_INTERVAL;
                }
                if (expired) { buf[count] = ua; unchecked { ++count; } }
            }
            unchecked { ++i; }
        }
        expiredUsers = new address[](count);
        for (uint256 i = 0; i < count;) { expiredUsers[i] = buf[i]; unchecked { ++i; } }
        nextOffset = end;
    }

    function getImportWindowStatus() external view returns (
        bool isOpen, uint256 windowCloseAt, uint256 timeRemaining
    ) {
        try NET.deployedAt() returns (uint256 da) {
            windowCloseAt = da + IMPORT_WINDOW;
            isOpen        = (!NET.initialized()) && (block.timestamp <= windowCloseAt);
            timeRemaining = block.timestamp >= windowCloseAt ? 0 : windowCloseAt - block.timestamp;
        } catch {}
    }

    function getActiveUsersCount() external view returns (uint256 v) {
        try NET.getActiveUsersCount() returns (uint256 c) { v = c; } catch {}
    }

    function getPendingUpgradeCount() external view returns (uint256 count) {
        while (true) {
            try NET.pendingUpgradeList(count) returns (address) { unchecked { ++count; } }
            catch { break; }
        }
    }

    function getPendingUpdatesCount(uint256 boxId) external view returns (uint256 count) {
        if (boxId >= BOX_COUNT) revert InvalidBox();
        while (true) {
            try NET.pendingUpdates(boxId, count) returns (address) { unchecked { ++count; } }
            catch { break; }
        }
    }

    function getBoxPrice(uint256 boxId) external pure returns (uint256) {
        if (boxId >= BOX_COUNT) revert InvalidBox();
        if (boxId == 0) return 25 ether;
        if (boxId == 1) return 75 ether;
        if (boxId == 2) return 100 ether;
        if (boxId == 3) return 300 ether;
        if (boxId == 4) return 500 ether;
        return 1000 ether;
    }

    /// @notice DAO weight component for `ua`: the smaller of their two
    ///         permanent Box-0 subtree counters. Used by the registry as
    ///         `1 + getBox0WeakerSide(voter)` (capped at the proposal's
    ///         snapshot of total Box-0 subscribers).
    function getBox0WeakerSide(address ua) external view returns (uint256) {
        return NET.getBox0SubtreeWeakerSide(ua);
    }

    /// @notice All-time left and right Box-0 subtree totals for `ua`,
    ///         accumulated since deployment and never decremented. Convenience
    ///         view for dashboards that need to show both legs separately
    ///         (the on-chain voting weight only uses the weaker of the two).
    function getBox0Legs(address ua)
        external
        view
        returns (uint256 left, uint256 right)
    {
        return NET.getBox0Subtree(ua);
    }

    /// @notice Sum of the weaker-leg counters across every tier the
    ///         subscriber holds. Convenience aggregate for dashboards.
    function getTotalWeakerSide(address ua) external view returns (uint256 total) {
        try NET.getBoxData(ua) returns (
            uint256[6] memory bpc,
            uint256[6] memory tlc,
            uint256[6] memory trc,
            uint256[6] memory
        ) {
            for (uint256 i = 0; i < BOX_COUNT;) {
                if (bpc[i] > 0) total += _weaker(tlc[i], trc[i]);
                unchecked { ++i; }
            }
        } catch {}
    }

    function getDailyBoxStatus(uint256 boxId) external view returns (
        uint256 accumulated, uint256 lastDistTime, uint256 nextDistTime,
        uint256 phase, uint256 cursor, uint256 totalPoints, bool ready
    ) {
        if (boxId >= BOX_COUNT) revert InvalidBox();
        try NET.pools(boxId) returns (uint256 acc, uint256 ldt, uint256) {
            accumulated  = acc;
            lastDistTime = ldt;
            nextDistTime = ldt + DAILY_DIST_INTERVAL;
            ready        = block.timestamp >= nextDistTime;
        } catch {}
        try NET.dailyPhase(boxId)       returns (uint256 v) { phase  = v; } catch {}
        try NET.dailyCursor(boxId)      returns (uint256 v) { cursor = v; } catch {}
        try NET.dailyTotalPoints(boxId) returns (uint256 v) { totalPoints = v; } catch {}
    }

    function estimateBuy(uint256 daiAmount) external view returns (uint256 stepOut) {
        try _dex().estimateBuy(daiAmount) returns (uint256 v) { stepOut = v; } catch {}
    }

    function estimateSell(uint256 stepAmount) external view returns (uint256 daiOut) {
        try _dex().estimateSell(stepAmount) returns (uint256 v) { daiOut = v; } catch {}
    }

    function getClubTimerData(address ua) external view returns (
        uint256 nextClubDist, uint256 clubTimeLeft,
        uint256 clubBurnAt, uint256 clubBurnLeft,
        uint256 clubPending, uint256 clubBurned
    ) {
        try _club().getClubTimerData(ua) returns (
            uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f
        ) { return (a, b, c, d, e, f); } catch {}
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ⑤ Keeper/Batch
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Keeper helper: burn each listed subscriber's expired reserve.
    ///         `checkAndBurnExpiredReserve` also compacts the ticket queue at
    ///         its end, so no separate compaction call is required.
    function burnExpiredReservesBatch(address[] calldata userList) external {
        IStepNetKeeper net = IStepNetKeeper(address(NET));
        for (uint256 i = 0; i < userList.length;) {
            try net.checkAndBurnExpiredReserve(userList[i]) {} catch {}
            unchecked { ++i; }
        }
    }

    // ─── IStepNetDAO forwarding layer ──────────────────────────────────
    //  Allows StepNetView to be registered as the registry's stepNetView
    //  pointer without exposing the underlying StepNet directly. Each
    //  forward includes a defensive fallback for legacy StepNet ABIs.

    function hasBox0(address user) external view returns (bool) {
        return NET.hasBox0(user);
    }

    /// @notice Box-5 ownership query used by the registry to gate proposal
    ///         creation.
    function hasBox5(address user) external view returns (bool) {
        return NET.hasBox5(user);
    }

    function getActiveBox0Count() external view returns (uint256) {
        return NET.getActiveBox0Count();
    }

    /// @notice Returns the subscriber's first-activation timestamp. Used by
    ///         the registry to enforce the "voter must pre-exist the
    ///         proposal" rule. Legacy ABI fallback retained because the
    ///         registry can be pointed at an older StepNet during a
    ///         migration window.
    function getUserStartTimestamp(address user) external view returns (uint256 ts) {
        try NET.getUserStartTimestamp(user) returns (uint256 v) {
            return v;
        } catch {
            try NET.users(user) returns (
                uint256,                  // 0: totalPaidAllBoxes
                address,                  // 1: upline
                address,                  // 2: left
                address,                  // 3: right
                uint256,                  // 4: totalCommissionDai
                uint256,                  // 5: reservedForUpgrade
                uint256,                  // 6: stepReceivedFromClub
                uint256,                  // 7: amountBurnedStepClub
                uint256,                  // 8: totalBurnedByUser
                bool,                     // 9: inStepClub
                uint256 startTimestamp,   // 10: startTimestamp
                uint256,                  // 11: reserveCycleStart
                uint256,                  // 12: clubJoinedTimestamp
                uint256                   // 13: stepBurnedFromClub
            ) {
                return startTimestamp;
            } catch {
                return 0;
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  LeaderboardLib — top-holder ranking + holder-info assembly.
//  Deployed standalone; StepNetView invokes it via DELEGATECALL so this heavy
//  read path lives off-contract, keeping StepNetView under the EIP-170 cap.
//  View-only — it reads StepNet and assembles the ranking, never writes state.
// ═══════════════════════════════════════════════════════════════════════════
library LeaderboardLib {
    uint256 private constant MAX_TOP_LIMIT = 100;

    // The param is typed as `address`, not `IStepNet`, on purpose: an external
    // library function with an interface-typed parameter emits the type "IStepNet"
    // in the ABI, which ethers v6 fails to parse (the "Invalid Fragment" warning).
    // The function selector is unchanged (IStepNet maps to address in the ABI),
    // so we simply cast to IStepNet inside the function body.
    function getTopHolders(address netAddr, uint256 limit, uint256 offset, uint256 maxScan)
        external view returns (HolderInfo[] memory holders, uint256 totalScanned, uint256 nextOffset)
    {
        IStepNet net = IStepNet(netAddr);
        if (limit > MAX_TOP_LIMIT) limit = MAX_TOP_LIMIT;
        if (limit == 0) return (new HolderInfo[](0), 0, offset);

        uint256 total = 0;
        try net.getActiveUsersCount() returns (uint256 v) { total = v; } catch {}
        if (offset >= total) return (new HolderInfo[](0), 0, total);

        uint256 end = offset + maxScan;
        if (end > total) end = total;

        address[] memory topAddr = new address[](limit);
        uint256[] memory topPaid = new uint256[](limit);
        uint256 filled = 0;

        for (uint256 i = offset; i < end;) {
            address ua;
            try net.activeUsers(i) returns (address a) { ua = a; } catch { unchecked { ++i; } continue; }

            uint256 paid = 0;
            try net.getUserClubData(ua) returns (uint256 tp, uint256, uint256, uint256, bool, uint256) {
                paid = tp;
            } catch {}

            if (paid == 0) { unchecked { ++i; } continue; }

            if (filled < limit) {
                uint256 j = filled;
                while (j > 0 && topPaid[j - 1] < paid) {
                    topAddr[j] = topAddr[j - 1];
                    topPaid[j] = topPaid[j - 1];
                    unchecked { --j; }
                }
                topAddr[j] = ua;
                topPaid[j] = paid;
                unchecked { ++filled; }
            } else if (paid > topPaid[limit - 1]) {
                uint256 j = limit - 1;
                while (j > 0 && topPaid[j - 1] < paid) {
                    topAddr[j] = topAddr[j - 1];
                    topPaid[j] = topPaid[j - 1];
                    unchecked { --j; }
                }
                topAddr[j] = ua;
                topPaid[j] = paid;
            }
            unchecked { ++i; }
        }

        totalScanned = end - offset;
        nextOffset   = end;

        uint256 resultLen = filled < limit ? filled : limit;
        holders = new HolderInfo[](resultLen);

        for (uint256 i = 0; i < resultLen;) {
            holders[i] = _buildHolderInfo(net, topAddr[i], topPaid[i]);
            unchecked { ++i; }
        }
    }

    function _buildHolderInfo(IStepNet net, address ua, uint256 paid)
        internal view returns (HolderInfo memory h)
    {
        h.user      = ua;
        h.totalPaid = paid;

        try net.users(ua) returns (
            uint256,
            address, address, address,
            uint256 commDai,
            uint256, uint256, uint256, uint256,
            bool    inClub,
            uint256, uint256, uint256, uint256
        ) {
            h.totalCommDai = commDai;
            h.inClub       = inClub;
        } catch {}

        try net.getBoxData(ua) returns (
            uint256[6] memory bpc,
            uint256[6] memory tlc,
            uint256[6] memory trc,
            uint256[6] memory
        ) {
            for (uint256 i = 5; i > 0;) {
                unchecked { --i; }
                if (bpc[i + 1] > 0) { h.highestBox = i + 1; break; }
            }
            if (bpc[0] > 0 && h.highestBox == 0) h.highestBox = 0;

            h.uniqueTeamLeft  = tlc[0];
            h.uniqueTeamRight = trc[0];
            h.weakerLeg       = tlc[0] < trc[0] ? tlc[0] : trc[0];
        } catch {}

        try net.userName(ua) returns (string memory n) { h.name = n; } catch {}
    }
}
