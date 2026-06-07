// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStepDexPrice {
    /// @notice Spot STEP price in DAI, PRECISION = 1e18 (DAI per 1 STEP).
    function getPrice() external view returns (uint256);
}

interface IStepNetStart {
    /// @notice Unix timestamp at which the user activated Box 0 (0 if never).
    function getUserStartTimestamp(address user) external view returns (uint256);
}

/**
 * @title  StepSubscription
 * @notice dApp-access subscription billed in STEP at the *live* DAI price.
 *
 *         Design goals (millions of users, zero off-chain state):
 *           • Access state is a single O(1) on-chain read — no database row
 *             per user, no indexer dependency. `accessStatus()` returns the
 *             full picture in one call.
 *           • "First month free" is derived, not stored: it is anchored to
 *             the user's Box-0 activation timestamp (already on-chain in
 *             StepNet). No extra storage, no migration.
 *           • Payment is priced in USD/DAI but settled in STEP, converted at
 *             the StepDex spot price at the moment of the transaction, with a
 *             caller-supplied `maxStep` slippage guard.
 *           • STEP is forwarded straight to `treasury` — the contract never
 *             custodies funds.
 *
 *         Plans (per-month price drops with commitment length):
 *           0) Monthly   — 6.99 DAI / mo
 *           1) 3-Month   — 5.99 DAI / mo
 *           2) 6-Month   — 4.99 DAI / mo
 *           3) 12-Month  — 3.99 DAI / mo
 */
contract StepSubscription is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Immutable wiring ────────────────────────────────────────────────────
    IERC20          public immutable STEP;
    IERC20          public immutable DAI;   // direct-DAI payment option
    IStepDexPrice   public immutable DEX;
    IStepNetStart   public immutable NET;

    // ─── Admin ───────────────────────────────────────────────────────────────
    address public owner;
    address public treasury;
    // The StepClub contract — the ONLY address allowed to call
    // `grantFromClubExit`. Set once by the owner after both contracts deploy;
    // after that the owner may renounce ownership for full trustlessness.
    // No one (not even the owner) can mint subscriptions except StepClub, and
    // StepClub only does so atomically inside its `exitToSubscription()` flow.
    address public clubAuthority;
    // Optional low-privilege key allowed to call `grantSubscription` (manual
    // comps for a wallet) — and NOTHING else. Lets support/marketing grant
    // access without the owner key. Set by owner; address(0) ⇒ owner-only.
    address public granter;

    // ─── Trial ────────────────────────────────────────────────────────────────
    uint256 public constant TRIAL_DURATION = 30 days;
    uint256 public constant MONTH          = 30 days;

    // ─── Plans ────────────────────────────────────────────────────────────────
    uint256 public constant PLAN_COUNT = 4;
    // months covered by each plan
    uint32[PLAN_COUNT] public planMonths;
    // per-month price in DAI (1e18 == 1 DAI)
    uint256[PLAN_COUNT] public planMonthlyUsd;

    // ─── Per-user paid expiry (unix ts) ─────────────────────────────────────────
    mapping(address => uint256) public paidExpiry;

    // ─── Events ──────────────────────────────────────────────────────────────
    event Subscribed(
        address indexed user,
        uint8   indexed plan,
        uint256 usdPaid,
        uint256 stepPaid,
        uint256 newExpiry
    );
    event SubscribedWithDai(address indexed user, uint8 indexed plan, uint256 daiPaid, uint256 newExpiry);
    event SubscriptionGranted(address indexed user, uint32 monthsGranted, uint256 newExpiry, address indexed by);
    event TreasuryUpdated(address indexed treasury);
    event PlanUpdated(uint8 indexed plan, uint32 months, uint256 monthlyUsd);
    event OwnershipTransferred(address indexed from, address indexed to);
    event ClubAuthorityUpdated(address indexed clubAuthority);
    event GranterUpdated(address indexed granter);
    /// @notice Emitted when StepClub converts a member's forfeited cap-gap
    ///         (DAI) into free subscription months. See `grantFromClubExit`.
    event GrantedFromClubExit(address indexed user, uint256 gapDai, uint32 monthsGranted, uint256 newExpiry);

    // ─── Errors ──────────────────────────────────────────────────────────────
    error NotOwner();
    error BadPlan();
    error ZeroAddress();
    error PriceUnavailable();
    error SlippageExceeded(uint256 needed, uint256 maxAllowed);
    error NotClubAuthority();
    error NotGranter();
    error ZeroMonths();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @param step      STEP token (StepCoin).
     * @param dai       DAI token (direct-DAI payment option).
     * @param dex       StepDex (live price source).
     * @param net       StepNet (Box-0 start timestamp source).
     * @param treasury_ Receiver of STEP/DAI payments. If zero, defaults to the
     *                  deployer — so `deploy.js` may pass address(0) to use the
     *                  deployer wallet automatically.
     */
    constructor(address step, address dai, address dex, address net, address treasury_) {
        if (step == address(0) || dai == address(0) || dex == address(0) || net == address(0)) revert ZeroAddress();
        STEP     = IERC20(step);
        DAI      = IERC20(dai);
        DEX      = IStepDexPrice(dex);
        NET      = IStepNetStart(net);
        owner    = msg.sender;
        treasury = treasury_ == address(0) ? msg.sender : treasury_;

        // Monthly / 3-Month / 6-Month / 12-Month
        planMonths     = [uint32(1), 3, 6, 12];
        planMonthlyUsd = [uint256(6.99e18), 5.99e18, 4.99e18, 3.99e18];
    }

    // ─── Pricing views ─────────────────────────────────────────────────────────

    /// @notice Total DAI price for a plan (per-month price × months).
    function planTotalUsd(uint8 plan) public view returns (uint256) {
        if (plan >= PLAN_COUNT) revert BadPlan();
        return planMonthlyUsd[plan] * planMonths[plan];
    }

    /**
     * @notice Live quote for a plan.
     * @return usd        total price in DAI (1e18).
     * @return stepAmount STEP (wei) required *right now* at the spot price.
     */
    function quote(uint8 plan) public view returns (uint256 usd, uint256 stepAmount) {
        usd = planTotalUsd(plan);
        uint256 price = DEX.getPrice();          // DAI per STEP, 1e18
        if (price == 0) revert PriceUnavailable();
        stepAmount = (usd * 1e18) / price;       // STEP wei
    }

    // ─── Subscribe ─────────────────────────────────────────────────────────────

    /**
     * @notice Buy/extend a subscription, paying in STEP at the live price.
     * @param plan    plan index (0..3).
     * @param maxStep maximum STEP (wei) the caller will pay — slippage guard.
     *                Pass `quote().stepAmount * (1 + tolerance)` from the UI.
     *
     * @dev   Extends from the later of `now` and the current expiry, so buying
     *        early never burns remaining days. STEP is pulled and forwarded to
     *        the treasury atomically; the contract holds no balance.
     */
    function subscribe(uint8 plan, uint256 maxStep) external nonReentrant {
        (uint256 usd, uint256 stepAmount) = quote(plan);
        if (stepAmount > maxStep) revert SlippageExceeded(stepAmount, maxStep);

        STEP.safeTransferFrom(msg.sender, treasury, stepAmount);

        uint256 cur  = paidExpiry[msg.sender];
        uint256 base = cur > block.timestamp ? cur : block.timestamp;
        uint256 newExpiry = base + (uint256(planMonths[plan]) * MONTH);
        paidExpiry[msg.sender] = newExpiry;

        emit Subscribed(msg.sender, plan, usd, stepAmount, newExpiry);
    }

    /**
     * @notice Buy/extend a subscription, paying directly in DAI (no STEP, no
     *         DEX price needed — plans are already DAI-denominated).
     * @param plan plan index (0..3). Cost = `planTotalUsd(plan)` DAI.
     * @dev   DAI is pulled and forwarded straight to `treasury`; the contract
     *        holds no balance. Extends from the later of now and current expiry.
     */
    function subscribeWithDai(uint8 plan) external nonReentrant {
        uint256 usd = planTotalUsd(plan);   // reverts BadPlan if out of range

        DAI.safeTransferFrom(msg.sender, treasury, usd);

        uint256 cur  = paidExpiry[msg.sender];
        uint256 base = cur > block.timestamp ? cur : block.timestamp;
        uint256 newExpiry = base + (uint256(planMonths[plan]) * MONTH);
        paidExpiry[msg.sender] = newExpiry;

        emit SubscribedWithDai(msg.sender, plan, usd, newExpiry);
    }

    // ─── Club-exit conversion (no payment) ───────────────────────────────────────

    /**
     * @notice Greedily convert a DAI amount into the maximum number of
     *         subscription months, using the four fixed plans as denominations
     *         (largest total price first, floored — any remainder is ignored).
     * @dev    Because the 12-month plan has the lowest per-month price, filling
     *         with it first maximises the months the user receives. Example
     *         (default pricing): 130 DAI → 2×12mo + 1×6mo = 30 months
     *         (4.30 DAI remainder is forfeited); 7 DAI → 1 month.
     */
    function monthsForGap(uint256 gapDai) public view returns (uint32 months) {
        uint256 remaining = gapDai;
        uint256 totMonths;
        uint8[PLAN_COUNT] memory order = [uint8(3), 2, 1, 0]; // 12mo, 6mo, 3mo, 1mo
        for (uint256 k = 0; k < PLAN_COUNT; k++) {
            uint8 p = order[k];
            uint256 total = planMonthlyUsd[p] * planMonths[p];
            if (total == 0) continue;
            uint256 count = remaining / total;
            if (count > 0) {
                totMonths += count * planMonths[p];
                remaining -= count * total;
            }
        }
        months = uint32(totMonths);
    }

    /**
     * @notice Convert a member's forfeited club cap-gap (DAI) into free
     *         subscription months, with NO STEP payment. Callable ONLY by
     *         `clubAuthority` (the StepClub contract), atomically inside its
     *         `exitToSubscription()` flow — StepClub computes `gapDai` from real
     *         cap accounting AND consumes it in the same transaction, so the gap
     *         can never be granted twice and no subscription can be minted
     *         without an actual club exit that forfeits that gap.
     * @dev    Months are computed on-chain via `monthsForGap` — fully
     *         deterministic and verifiable. No admin, no off-chain trust.
     * @return monthsGranted months added to the user's paid expiry (0 if the gap
     *         does not cover even the cheapest plan).
     */
    function grantFromClubExit(address user, uint256 gapDai) external returns (uint32 monthsGranted) {
        if (msg.sender != clubAuthority) revert NotClubAuthority();
        if (user == address(0)) revert ZeroAddress();

        monthsGranted = monthsForGap(gapDai);
        if (monthsGranted == 0) return 0;

        uint256 cur  = paidExpiry[user];
        uint256 base = cur > block.timestamp ? cur : block.timestamp;
        uint256 newExpiry = base + (uint256(monthsGranted) * MONTH);
        paidExpiry[user] = newExpiry;

        emit GrantedFromClubExit(user, gapDai, monthsGranted, newExpiry);
    }

    /**
     * @notice Admin comp: directly grant `months` of subscription to any wallet,
     *         with NO payment. Callable by the `owner` or the optional
     *         low-privilege `granter`. For support, promos, or manual activation.
     * @dev    This is an INTENTIONAL trusted capability (not the trustless
     *         club-exit path). A compromised owner/granter key can mint free
     *         access — but cannot touch user funds, the club, or revenue (which
     *         goes straight to `treasury`). Keep the owner key cold and use the
     *         `granter` key for routine grants.
     */
    function grantSubscription(address user, uint32 months) external returns (uint256 newExpiry) {
        if (msg.sender != owner && msg.sender != granter) revert NotGranter();
        if (user == address(0)) revert ZeroAddress();
        if (months == 0) revert ZeroMonths();

        uint256 cur  = paidExpiry[user];
        uint256 base = cur > block.timestamp ? cur : block.timestamp;
        newExpiry = base + (uint256(months) * MONTH);
        paidExpiry[user] = newExpiry;

        emit SubscriptionGranted(user, months, newExpiry, msg.sender);
    }

    // ─── Access status (single source of truth) ──────────────────────────────────

    /**
     * @notice Everything the dApp needs to gate access, in one call.
     * @return active       true if the user may use the dApp right now.
     * @return reason        0 = locked, 1 = free trial, 2 = paid.
     * @return trialEnd      unix ts when the free trial ends (0 if no Box 0).
     * @return paidEnd       unix ts when the paid subscription ends.
     * @return effectiveEnd  max(trialEnd, paidEnd) — when access actually lapses.
     */
    function accessStatus(address user)
        external
        view
        returns (bool active, uint8 reason, uint256 trialEnd, uint256 paidEnd, uint256 effectiveEnd)
    {
        uint256 start = 0;
        try NET.getUserStartTimestamp(user) returns (uint256 s) { start = s; } catch {}

        trialEnd = start == 0 ? 0 : start + TRIAL_DURATION;
        paidEnd  = paidExpiry[user];
        effectiveEnd = trialEnd > paidEnd ? trialEnd : paidEnd;
        active = effectiveEnd > block.timestamp;

        if (paidEnd > block.timestamp)      reason = 2; // paid
        else if (trialEnd > block.timestamp) reason = 1; // trial
        else                                 reason = 0; // locked
    }

    /// @notice All four plans at once (months, per-month USD, total USD, live STEP).
    function getPlans()
        external
        view
        returns (
            uint32[PLAN_COUNT]  memory months,
            uint256[PLAN_COUNT] memory monthlyUsd,
            uint256[PLAN_COUNT] memory totalUsd,
            uint256[PLAN_COUNT] memory stepAmount
        )
    {
        uint256 price = DEX.getPrice();
        for (uint8 i = 0; i < PLAN_COUNT; i++) {
            months[i]     = planMonths[i];
            monthlyUsd[i] = planMonthlyUsd[i];
            totalUsd[i]   = planMonthlyUsd[i] * planMonths[i];
            stepAmount[i] = price == 0 ? 0 : (totalUsd[i] * 1e18) / price;
        }
    }

    // ─── Admin ───────────────────────────────────────────────────────────────────

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasuryUpdated(t);
    }

    /// @notice Authorise the StepClub contract to grant club-exit subscriptions.
    ///         Set once after deploy; address(0) disables the conversion path.
    function setClubAuthority(address c) external onlyOwner {
        clubAuthority = c;
        emit ClubAuthorityUpdated(c);
    }

    /// @notice Set the optional low-privilege key allowed to call
    ///         `grantSubscription`. address(0) ⇒ owner-only grants.
    function setGranter(address g) external onlyOwner {
        granter = g;
        emit GranterUpdated(g);
    }

    function setPlan(uint8 plan, uint32 months, uint256 monthlyUsd) external onlyOwner {
        if (plan >= PLAN_COUNT) revert BadPlan();
        planMonths[plan]     = months;
        planMonthlyUsd[plan] = monthlyUsd;
        emit PlanUpdated(plan, months, monthlyUsd);
    }

    function transferOwnership(address n) external onlyOwner {
        if (n == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, n);
        owner = n;
    }
}
