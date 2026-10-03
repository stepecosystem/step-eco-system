// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStepDex {
    /// @notice Spot STEP price in DAI, PRECISION = 1e18 (DAI per 1 STEP).
    function getPrice() external view returns (uint256);
    function buyStepPublic(uint256 daiAmount, uint256 minStepOut) external;
    function estimateBuy(uint256 daiAmount) external view returns (uint256);
}

interface IStepRegistry {
    function get(bytes32 key) external view returns (address);
    function KEY_STEP_COIN()     external view returns (bytes32);
    function KEY_STEP_DEX()      external view returns (bytes32);
    function KEY_CLUB_TREASURY() external view returns (bytes32);
    function acceptTerms() external;
}

interface IStepClub {
    function donateToPool(uint256 amount) external;
}

interface IStepNFTFund {
    function depositSplit(uint256 amount) external;
}


/**
 * @title  StepSubscription
 * @notice The revenue conduit for the subscription line, and nothing else.
 *
 *         The contract custodies nothing and prices nothing. Every unit of
 *         value that enters — whichever token it arrived in — leaves in the
 *         same transaction, denominated in STEP, split on a fixed schedule:
 *
 *              19 %  → dev wallet
 *              51 %  → owner wallet
 *              10 %  → StepClub live pool
 *              20 %  → StepNFTFund (sale vault + NFT yield vault)
 *
 *         STEP payments are split as received. DAI payments are converted to
 *         STEP through the AMM in the same call, before the split, so the four
 *         destinations are always paid in STEP.
 *
 *         WHAT A SUBSCRIPTION COSTS AND HOW LONG IT LASTS LIVES OFF-CHAIN.
 *         Plans, prices and durations are the dApp's business: it quotes a
 *         price, the user pays it here with a `ref` identifying what they
 *         bought, and the `Payment` event carries payer, ref and amount so the
 *         dApp can credit the account. Changing a price is then a
 *         configuration change, not a transaction — and this contract never
 *         has to be redeployed to reprice anything.
 */
contract StepSubscription is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Immutable wiring ────────────────────────────────────────────────────
    IStepRegistry public immutable REGISTRY;
    IERC20        public immutable DAI;

    // ─── Revenue split (must total 100) ──────────────────────────────────────
    uint256 public constant DEV_PCT   = 19;
    uint256 public constant OWNER_PCT = 51;
    uint256 public constant CLUB_PCT  = 10;
    uint256 public constant FUND_PCT  = 20;
    uint256 private constant PCT_DENOMINATOR = 100;

    /// @dev Anti-sandwich floor on every AMM-routed STEP purchase.
    uint256 private constant MIN_STEP_BPS    = 9500;
    uint256 private constant BPS_DENOMINATOR = 10000;

    // ─── Admin ───────────────────────────────────────────────────────────────
    address public owner;
    /// @notice Receiver of the 19 % development slice.
    address public devWallet;
    /// @notice Receiver of the 51 % owner slice.
    address public ownerWallet;
    /// @notice StepNFTFund — receiver of the 20 % slice.
    address public nftFund;
    /// @notice The StepClub contract, the only address allowed to call
    ///         `grantFromClubExit`.
    address public clubAuthority;
    /// @notice Optional low-privilege key allowed to call `grantSubscription`.
    address public granter;

    // ─── Club-exit conversion ────────────────────────────────────────────────
    //  A club exit is settled entirely on-chain: StepClub calls straight into
    //  this contract, so the dApp is not in the loop and cannot price it. The
    //  denomination table below is what turns a forfeited DAI cap-gap into
    //  months, and it is the ONLY pricing this contract holds. Ordinary
    //  payments still carry their price from the dApp — see `payDai`.
    uint256 public constant MONTH = 30 days;
    uint256 public constant PLAN_COUNT = 4;
    /// @notice Denomination lengths, longest first when converting a gap.
    uint32[PLAN_COUNT]  public planMonths;
    /// @notice Per-month price of each denomination, DAI (1e18).
    uint256[PLAN_COUNT] public planMonthlyUsd;

    /// @notice Unix timestamp a wallet's granted access runs to.
    mapping(address => uint256) public paidExpiry;

    // ─── Lifetime routed totals (analytics; no effect on logic) ──────────────
    uint256 public totalRoutedStep;
    uint256 public totalRoutedDai;

    // ─── Events ──────────────────────────────────────────────────────────────
    /**
     * @notice A payment landed and was routed.
     * @param payer      who paid.
     * @param ref        free-form reference the dApp attached to the payment —
     *                   plan id, invoice number, whatever it needs to credit
     *                   the right account for the right period. Zero when the
     *                   payer used the plain `deposit*` entry points.
     * @param token      the token actually handed over (DAI or STEP).
     * @param amountIn   how much of that token was handed over.
     * @param stepRouted STEP that reached the split after conversion and the
     *                   STEP transfer levy.
     */
    event Payment(
        address indexed payer,
        bytes32 indexed ref,
        address indexed token,
        uint256 amountIn,
        uint256 stepRouted
    );
    event RevenueSplit(uint256 stepIn, uint256 toDev, uint256 toOwner, uint256 toClub, uint256 toFund);
    /// @notice StepClub converted a member's forfeited cap-gap into free
    ///         subscription months on the way out of the club.
    event GrantedFromClubExit(address indexed user, uint256 gapDai, uint32 monthsGranted, uint256 newExpiry);
    /// @notice Admin comp — months granted with no payment.
    event SubscriptionGranted(address indexed user, uint32 monthsGranted, uint256 newExpiry, address indexed by);
    event PlanUpdated(uint8 indexed plan, uint32 months, uint256 monthlyUsd);
    event GranterUpdated(address indexed granter);
    /// @notice A wallet bought a plan directly from the contract, in STEP.
    event Subscribed(address indexed user, uint8 indexed plan, uint256 usdPaid, uint256 stepPaid, uint256 newExpiry);
    /// @notice …or in DAI, converted in the same call.
    event SubscribedWithDai(address indexed user, uint8 indexed plan, uint256 daiPaid, uint256 stepRouted, uint256 newExpiry);
    event DevWalletUpdated(address indexed devWallet);
    event OwnerWalletUpdated(address indexed ownerWallet);
    event NftFundUpdated(address indexed nftFund);
    event ClubAuthorityUpdated(address indexed clubAuthority);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ─── Errors ──────────────────────────────────────────────────────────────
    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error NotClubAuthority();
    error NotInitialized();
    error NotGranter();
    error ZeroMonths();
    error BadPlan();
    error PriceUnavailable();
    error SlippageExceeded(uint256 needed, uint256 maxAllowed);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @param registry_    StepRegistry — resolves STEP, the DEX and StepClub,
     *                     so a DAO migration of any of them is picked up
     *                     automatically.
     * @param dai_         DAI token (direct-DAI payment option).
     * @param devWallet_   19 % receiver. Zero defaults to the deployer.
     * @param ownerWallet_ 51 % receiver. Zero defaults to the deployer.
     */
    constructor(address registry_, address dai_, address devWallet_, address ownerWallet_) {
        if (registry_ == address(0) || dai_ == address(0)) revert ZeroAddress();
        REGISTRY    = IStepRegistry(registry_);
        DAI         = IERC20(dai_);
        owner       = msg.sender;
        devWallet   = devWallet_   == address(0) ? msg.sender : devWallet_;
        ownerWallet = ownerWallet_ == address(0) ? msg.sender : ownerWallet_;

        // Denominations used only to convert a club-exit cap-gap into months.
        planMonths     = [uint32(1), 3, 6, 12];
        planMonthlyUsd = [uint256(6.99e18), 5.99e18, 4.99e18, 3.99e18];

        // Needed once so this contract may route DAI through the public AMM
        // entry point when a subscriber pays in DAI.
        REGISTRY.acceptTerms();
    }

    // ─── Resolvers ───────────────────────────────────────────────────────────
    function _step() internal view returns (IERC20)   { return IERC20(REGISTRY.get(REGISTRY.KEY_STEP_COIN())); }
    function _dex()  internal view returns (IStepDex) { return IStepDex(REGISTRY.get(REGISTRY.KEY_STEP_DEX())); }
    function _club() internal view returns (address)  { return REGISTRY.get(REGISTRY.KEY_CLUB_TREASURY()); }

    /// @notice Live addresses this contract currently routes to.
    function routes() external view returns (address step, address dex, address club, address fund) {
        step = address(_step());
        dex  = address(_dex());
        club = _club();
        fund = nftFund;
    }

    /// @notice Spot STEP price in DAI (1e18), for a dApp quoting in STEP.
    function stepPrice() external view returns (uint256) {
        return _dex().getPrice();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  REVENUE CONDUIT
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @dev Splits `amount` STEP already held by this contract across the four
     *      destinations and leaves nothing behind. STEP carries a transfer
     *      levy unless the sender is whitelisted, so each destination credits
     *      what it actually receives; both StepClub and StepNFTFund measure
     *      their own balance delta, so their internal accounting stays exact.
     */
    function _splitStep(uint256 amount) internal {
        if (amount == 0) return;

        address club = _club();
        address fund = nftFund;
        if (club == address(0) || fund == address(0)) revert NotInitialized();

        IERC20 step = _step();

        uint256 toDev   = (amount * DEV_PCT)  / PCT_DENOMINATOR;
        uint256 toClub  = (amount * CLUB_PCT) / PCT_DENOMINATOR;
        uint256 toFund  = (amount * FUND_PCT) / PCT_DENOMINATOR;
        // The owner slice absorbs the rounding dust so the split is exhaustive.
        uint256 toOwner = amount - toDev - toClub - toFund;

        if (toDev   > 0) step.safeTransfer(devWallet,   toDev);
        if (toOwner > 0) step.safeTransfer(ownerWallet, toOwner);

        if (toClub > 0) {
            step.forceApprove(club, toClub);
            IStepClub(club).donateToPool(toClub);
            step.forceApprove(club, 0);
        }
        if (toFund > 0) {
            step.forceApprove(fund, toFund);
            IStepNFTFund(fund).depositSplit(toFund);
            step.forceApprove(fund, 0);
        }

        totalRoutedStep += amount;
        emit RevenueSplit(amount, toDev, toOwner, toClub, toFund);
    }

    /// @dev Pulls STEP from `msg.sender` and returns what actually landed.
    function _pullStep(uint256 amount) internal returns (uint256 received) {
        IERC20 step = _step();
        uint256 before_ = step.balanceOf(address(this));
        step.safeTransferFrom(msg.sender, address(this), amount);
        received = step.balanceOf(address(this)) - before_;
    }

    /// @dev Converts DAI already held by this contract into STEP via the AMM.
    function _daiToStep(uint256 daiAmount) internal returns (uint256 received) {
        IStepDex dex  = _dex();
        IERC20   step = _step();

        uint256 minOut = 0;
        try dex.estimateBuy(daiAmount) returns (uint256 expected) {
            if (expected > 0) minOut = (expected * MIN_STEP_BPS) / BPS_DENOMINATOR;
        } catch {}

        DAI.forceApprove(address(dex), daiAmount);
        uint256 before_ = step.balanceOf(address(this));
        dex.buyStepPublic(daiAmount, minOut);
        received = step.balanceOf(address(this)) - before_;
        if (received == 0) revert ZeroAmount();
    }

    // ─── Payment entry points ────────────────────────────────────────────────

    /**
     * @notice Pay in DAI. It is converted to STEP and split in this same call.
     * @param amount DAI to pay. The dApp decides what this buys.
     * @param ref    the dApp's reference for what was bought — plan id,
     *               invoice, order hash. Emitted, never interpreted here.
     */
    function payDai(uint256 amount, bytes32 ref) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        DAI.safeTransferFrom(msg.sender, address(this), amount);
        uint256 routed = _daiToStep(amount);
        _splitStep(routed);
        totalRoutedDai += amount;
        emit Payment(msg.sender, ref, address(DAI), amount, routed);
    }

    /**
     * @notice Pay in STEP. Split as received.
     * @param amount STEP to pay.
     * @param ref    the dApp's reference for what was bought.
     */
    function payStep(uint256 amount, bytes32 ref) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 routed = _pullStep(amount);
        _splitStep(routed);
        emit Payment(msg.sender, ref, address(_step()), amount, routed);
    }

    /// @notice Route DAI through the split with no reference attached.
    function depositDai(uint256 amount) external { payDai(amount, bytes32(0)); }

    /// @notice Route STEP through the split with no reference attached.
    function depositStep(uint256 amount) external { payStep(amount, bytes32(0)); }

    /**
     * @notice Split anything sitting idle on this contract — STEP directly,
     *         DAI after conversion. Callable by anyone; the contract is a
     *         conduit and is never meant to hold a balance.
     */
    function flush() external nonReentrant {
        uint256 daiBal = DAI.balanceOf(address(this));
        if (daiBal > 0) _daiToStep(daiBal);

        uint256 stepBal = _step().balanceOf(address(this));
        if (stepBal == 0) revert ZeroAmount();
        _splitStep(stepBal);
    }

    // ─── Club-exit hook ──────────────────────────────────────────────────────

    // ─── Self-serve purchase ─────────────────────────────────────────────────
    //  A wallet can buy any of the four plans straight from the contract, with
    //  no backend in the loop: it pays the on-chain price and the months land
    //  in `paidExpiry` in the same transaction. This is the floor the dApp
    //  sits on top of — promotions, bundles and one-off pricing still go
    //  through `payDai` / `payStep` + `grantSubscription`, which can express
    //  anything a four-slot table cannot.

    /// @notice Total DAI price of a plan (per-month price × months).
    function planTotalUsd(uint8 plan) public view returns (uint256) {
        if (plan >= PLAN_COUNT) revert BadPlan();
        return planMonthlyUsd[plan] * planMonths[plan];
    }

    /**
     * @notice Live quote for a plan.
     * @return usd        total price in DAI (1e18).
     * @return stepAmount STEP (wei) that costs at the spot price right now.
     */
    function quote(uint8 plan) public view returns (uint256 usd, uint256 stepAmount) {
        usd = planTotalUsd(plan);
        uint256 price = _dex().getPrice();
        if (price == 0) revert PriceUnavailable();
        stepAmount = (usd * 1e18) / price;
    }

    /**
     * @notice Buy or extend a plan, paying in STEP at the live price.
     * @param plan    plan index (0..3).
     * @param maxStep most STEP the caller will part with — slippage guard, so
     *                a price move between quoting and mining cannot overcharge.
     * @dev   Extends from the later of now and the current expiry, so buying
     *        early never burns time already held. The STEP is split across the
     *        four destinations in this same call.
     */
    function subscribe(uint8 plan, uint256 maxStep) external nonReentrant {
        (uint256 usd, uint256 stepAmount) = quote(plan);
        if (stepAmount > maxStep) revert SlippageExceeded(stepAmount, maxStep);
        if (stepAmount == 0) revert ZeroAmount();

        _splitStep(_pullStep(stepAmount));

        uint256 newExpiry = _extend(msg.sender, planMonths[plan]);
        emit Subscribed(msg.sender, plan, usd, stepAmount, newExpiry);
    }

    /**
     * @notice Buy or extend a plan, paying in DAI. The DAI is converted to
     *         STEP in this same call and then split.
     * @param plan plan index (0..3). Cost = `planTotalUsd(plan)` DAI.
     */
    function subscribeWithDai(uint8 plan) external nonReentrant {
        uint256 usd = planTotalUsd(plan);   // reverts BadPlan if out of range

        DAI.safeTransferFrom(msg.sender, address(this), usd);
        uint256 routed = _daiToStep(usd);
        _splitStep(routed);
        totalRoutedDai += usd;

        uint256 newExpiry = _extend(msg.sender, planMonths[plan]);
        emit SubscribedWithDai(msg.sender, plan, usd, routed, newExpiry);
    }

    /**
     * @notice Greedily convert a DAI amount into the maximum number of
     *         subscription months, using the four denominations as
     *         currency (longest commitment first, floored — any remainder is
     *         ignored).
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

    /// @dev Extends from the later of now and the current expiry, so an early
    ///      grant never burns time the wallet already had.
    function _extend(address user, uint32 months) internal returns (uint256 newExpiry) {
        uint256 cur  = paidExpiry[user];
        uint256 base = cur > block.timestamp ? cur : block.timestamp;
        newExpiry = base + (uint256(months) * MONTH);
        paidExpiry[user] = newExpiry;
    }

    /**
     * @notice Convert a member's forfeited club cap-gap (DAI) into free
     *         subscription months, with NO payment. Callable ONLY by
     *         `clubAuthority` — the StepClub contract — atomically inside its
     *         `exitToSubscription()` flow.
     */
    function grantFromClubExit(address user, uint256 gapDai) external returns (uint32 monthsGranted) {
        if (msg.sender != clubAuthority) revert NotClubAuthority();
        if (user == address(0)) revert ZeroAddress();

        monthsGranted = monthsForGap(gapDai);
        if (monthsGranted == 0) return 0;

        uint256 newExpiry = _extend(user, monthsGranted);
        emit GrantedFromClubExit(user, gapDai, monthsGranted, newExpiry);
    }

    /**
     * @notice Admin comp: grant `months` of access to any wallet with NO
     *         payment. Callable by the `owner` or the optional low-privilege
     *         `granter`. This is also the hook the dApp uses to record time
     *         bought through `payDai` / `payStep`, where the dApp — not the
     *         contract — decides what the payment was worth.
     */
    function grantSubscription(address user, uint32 months) external returns (uint256 newExpiry) {
        if (msg.sender != owner && msg.sender != granter) revert NotGranter();
        if (user == address(0)) revert ZeroAddress();
        if (months == 0) revert ZeroMonths();

        newExpiry = _extend(user, months);
        emit SubscriptionGranted(user, months, newExpiry, msg.sender);
    }

    /// @notice Whether a wallet's access is live right now, and until when.
    function accessStatus(address user) external view returns (bool active, uint256 paidEnd) {
        paidEnd = paidExpiry[user];
        active  = paidEnd > block.timestamp;
    }

    /// @notice All four plans at once: length, per-month price, total price,
    ///         and what that total costs in STEP at the current spot price.
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
        uint256 price = _dex().getPrice();
        for (uint8 i = 0; i < PLAN_COUNT; i++) {
            months[i]     = planMonths[i];
            monthlyUsd[i] = planMonthlyUsd[i];
            totalUsd[i]   = planMonthlyUsd[i] * planMonths[i];
            stepAmount[i] = price == 0 ? 0 : (totalUsd[i] * 1e18) / price;
        }
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    /// @notice How a given STEP amount would divide across the four routes.
    function previewSplit(uint256 amount)
        external
        pure
        returns (uint256 toDev, uint256 toOwner, uint256 toClub, uint256 toFund)
    {
        toDev  = (amount * DEV_PCT)  / PCT_DENOMINATOR;
        toClub = (amount * CLUB_PCT) / PCT_DENOMINATOR;
        toFund = (amount * FUND_PCT) / PCT_DENOMINATOR;
        toOwner = amount - toDev - toClub - toFund;
    }

    /// @notice STEP a DAI amount would buy at the current spot price, before
    ///         the AMM's own buyer share. For dApp display only.
    function quoteStepForDai(uint256 daiAmount) external view returns (uint256) {
        uint256 price = _dex().getPrice();
        return price == 0 ? 0 : (daiAmount * 1e18) / price;
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setDevWallet(address w) external onlyOwner {
        if (w == address(0)) revert ZeroAddress();
        devWallet = w;
        emit DevWalletUpdated(w);
    }

    function setOwnerWallet(address w) external onlyOwner {
        if (w == address(0)) revert ZeroAddress();
        ownerWallet = w;
        emit OwnerWalletUpdated(w);
    }

    /// @notice Wire the StepNFTFund that receives the 20 % slice.
    function setNftFund(address f) external onlyOwner {
        if (f == address(0)) revert ZeroAddress();
        nftFund = f;
        emit NftFundUpdated(f);
    }

    /// @notice Authorise the StepClub contract to report club exits.
    function setClubAuthority(address c) external onlyOwner {
        clubAuthority = c;
        emit ClubAuthorityUpdated(c);
    }

    /// @notice Low-privilege key allowed to call `grantSubscription` — the
    ///         dApp's backend records paid time through this.
    ///         address(0) ⇒ owner-only.
    function setGranter(address g) external onlyOwner {
        granter = g;
        emit GranterUpdated(g);
    }

    /// @notice Adjust a club-exit denomination. Affects `monthsForGap` only.
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

    // No public `acceptTerms()` here on purpose. The constructor accepts once,
    // and `StepRegistry` records acceptance as a permanent, un-versioned
    // timestamp against a `constant` terms string — there is no reissue path
    // and no way to clear it, so a second call could never be needed.
}
