// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IStepCoin is IERC20 {
    function burn(uint256 amount) external;
}

interface IStepDex {
    function getPrice() external view returns (uint256);
    function buyStepPublic(uint256 daiAmount, uint256 minStepOut) external;
    function estimateBuy(uint256 daiAmount) external view returns (uint256);
}

interface IStepRegistry {
    function get(bytes32 key) external view returns (address);
    function KEY_STEP_COIN() external view returns (bytes32);
    function KEY_STEP_DEX()  external view returns (bytes32);
    function acceptTerms() external;
}

interface IStepNFT is IERC721 {
    /// @notice Mint-curve price of `id`, in DAI (1e18).
    function getPrice(uint256 id) external pure returns (uint256);
    /// @notice Price the public pool is minting at right now — "the day
    ///         price". Zero once the pool is sold out.
    function getCurrentPrice() external view returns (uint256);
    /// @notice Next id the public buy pool will mint; ids below it exist.
    function nextBuyId() external view returns (uint256);
    /// @notice The two wallets a primary sale pays, 90 % and 10 %.
    function wallet90() external view returns (address);
    function wallet10() external view returns (address);
    /// @notice Collects whatever the collection's own reward engine has
    ///         credited to the caller.
    function claimRewards() external;
    function pendingOf(address user) external view returns (uint256);
}

/**
 * @title  StepNFTFund
 * @notice Custodian of the 20 % slice that `StepSubscription` routes here.
 *         Every STEP that arrives is split across two strictly separated
 *         vaults, each with its own balance counter — the contract never
 *         nets them against one another and never spends one on the other:
 *
 *           • SALE VAULT   — buy-back desk. A holder may sell an NFT back
 *             to the protocol for half its list price, paid in STEP at the
 *             spot rate of the moment the payout clears. The NFT itself is
 *             taken into custody and immediately re-listed at the CURRENT
 *             DAY PRICE — the price the collection is minting at right now —
 *             so it can be bought again by anyone. When the vault is short,
 *             the request waits in a strict FIFO queue and settles as soon
 *             as the vault is funded — meanwhile the NFT is already listed
 *             and a direct buyer can clear the request instantly. A seller
 *             whose order has not settled may cancel and take the NFT back.
 *
 *           • YIELD VAULT  — daily reward engine, reproducing the timing,
 *             burn and claim-window rules of `StepNFTTreasury`, but paying
 *             ONLY the tier of NFTs whose price is 400 DAI or more, split
 *             evenly per NFT.
 *
 *         Re-sale of a listed NFT is a primary sale in every respect: the
 *         buyer pays the day price in DAI and the whole of it is converted
 *         to STEP and split 90 / 10 across the same two wallets a fresh mint
 *         pays — less only the transfer levy the NFT contract charges this
 *         contract as the token leaves custody. The sale vault is NOT
 *         reimbursed out of that; it is funded by the 20 % subscription
 *         slice and by `donateToSaleVault`, which any address or future
 *         contract may call.
 *
 *         A re-sold NFT is thereafter a member of the tier it was re-sold
 *         at. `tierOf` records that price, and a low-id token promoted this
 *         way joins the yield split for good, so the id it was minted under
 *         never holds it back.
 */
contract StepNFTFund is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── ERRORS ──────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error NotTokenOwner();
    error AlreadyListed();
    error NotListed();
    error TooEarly();
    error NoRewards();
    error NoEligibleNFTs();
    error NothingToClaim();
    error DistributionInProgress();
    error PriceUnavailable();
    error PriceExceedsMax();
    error BadShare();
    error NothingToSettle();
    error NotAuthorized();
    error AlreadyMigrated();
    error NotMigrated();
    error NothingToMigrate();
    error SlippageExceeded();

    // ─── CONSTANTS ───────────────────────────────────────────────────────────
    /// @notice Lowest NFT id that earns from the yield vault by birth. Ids
    ///         1..300 are the 100/200-DAI tiers; 301 upward are priced 400 DAI
    ///         and above. A lower id can still join later — see `tierOf`.
    uint256 public constant FIRST_YIELD_ID = 301;
    /// @notice Price at or above which an NFT earns from the yield vault.
    uint256 public constant YIELD_MIN_PRICE = 400e18;

    /// @notice Share of an NFT's price returned to a seller.
    uint256 public constant SELLBACK_PCT = 50;
    /// @notice Share of an NFT's MINT price consumed by the NFT contract's own
    ///         transfer levy when the token changes hands. Charged against
    ///         `NFT.getPrice(id)`, never against the day price.
    uint256 public constant TRANSFER_FEE_PCT = 10;
    /// @notice How a re-sale divides, mirroring a primary mint exactly.
    uint256 public constant RESALE_W90_PCT = 90;
    uint256 private constant PCT_DENOMINATOR = 100;

    uint256 public constant DISTRIBUTION_INTERVAL = 1 days;
    uint256 public constant CLAIM_DEADLINE        = 30 days;
    uint256 public constant DIST_BATCH_SIZE       = 400;

    uint256 private constant PRECISION       = 1e18;
    uint256 private constant BPS_DENOMINATOR = 10000;
    /// @dev Anti-sandwich floor on every AMM-routed STEP purchase.
    uint256 private constant MIN_STEP_BPS = 9500;
    /// @dev Queue entries settled opportunistically on an inbound deposit.
    uint256 private constant AUTO_SETTLE_ON_DEPOSIT = 2;
    /// @dev How far past `queueHead` a re-sale will look for the first order
    ///      that is still owed money, stepping over ones already cleared.
    uint256 private constant QUEUE_LOOKAHEAD = 32;

    /// @notice Registry slot this contract expects to be listed under, so the
    ///         DAO's `proposeMigration` / `executeMigration` path can reach it.
    ///         The registry stores addresses under arbitrary bytes32 keys, so no
    ///         change to the deployed registry is needed — the controller just
    ///         calls `setInitial(KEY_NFT_FUND, <this>)` once.
    bytes32 public constant KEY_NFT_FUND = keccak256("NFT_FUND");

    // ─── IMMUTABLE WIRING ────────────────────────────────────────────────────
    IStepRegistry public immutable REGISTRY;
    IERC20        public immutable DAI;
    /// @notice The NFT collection this vault takes custody of. Deliberately
    ///         immutable rather than resolved through the registry: the
    ///         contract holds specific token ids of THIS collection and tracks
    ///         them in `listed` / `escrowedTokens` / `escrowedYieldCount`. If
    ///         the pointer could move, that custody bookkeeping would silently
    ///         describe a different collection. STEP and the DEX stay dynamic,
    ///         so a DAO migration of either is still followed automatically.
    IStepNFT public immutable NFT;

    // ─── ADMIN ───────────────────────────────────────────────────────────────
    /// @notice Share of every inbound deposit routed to the sale vault; the
    ///         remainder goes to the yield vault. 5000 bps = an even split.
    uint256 public saleShareBps = 5000;

    // ─── TIER PROMOTION ──────────────────────────────────────────────────────
    /// @notice Price (DAI, 1e18) a token is considered to be worth after this
    ///         contract re-sold it. Zero means "never re-sold here" — the
    ///         token's own mint-curve price applies.
    mapping(uint256 => uint256) public tierOf;
    /// @notice Tokens minted below `FIRST_YIELD_ID` that a re-sale lifted into
    ///         the yield tier. Enumerable, because the distribution walk cannot
    ///         reach them through the id range.
    uint256[] public promotedTokens;
    /// @dev tokenId => index into `promotedTokens`, + 1. Zero means absent.
    mapping(uint256 => uint256) public promotedIndex;

    // ─── VAULT BALANCES (never netted against each other) ────────────────────
    /// @notice STEP earmarked for buy-back payouts.
    uint256 public saleVaultStep;
    /// @notice STEP waiting to be distributed as daily yield.
    uint256 public yieldVaultStep;
    /// @notice STEP already distributed and awaiting claim by its holders.
    uint256 public totalPendingRewards;

    // ─── SALE VAULT — custody, listing, FIFO queue ───────────────────────────
    struct SellOrder {
        address seller;    // who handed the NFT over
        uint32  tokenId;   // the NFT taken into custody
        bool    paid;      // seller has received the 50 % payout
        bool    cancelled; // seller withdrew before the payout cleared
        uint256 owedDai;   // 50 % of the effective price, in DAI (1e18)
    }

    SellOrder[] public sellQueue;
    /// @notice First queue slot not yet cleared. Entries below it are done.
    uint256 public queueHead;
    /// @notice tokenId => queue index + 1, while the token is in custody.
    mapping(uint256 => uint256) public orderOfToken;
    /// @notice tokenId is held by this contract and buyable at its list price.
    mapping(uint256 => bool) public listed;
    /// @notice Count of yield-eligible ids currently in custody. Held tokens
    ///         earn nothing, so this is subtracted from the eligible supply.
    uint256 public escrowedYieldCount;
    /// @notice Every id currently in custody, enumerable so a DAO migration can
    ///         hand the tokens to the successor without off-chain bookkeeping.
    uint256[] public escrowedTokens;
    /// @dev tokenId => index into `escrowedTokens`, + 1. Zero means absent.
    mapping(uint256 => uint256) public escrowIndex;

    // ─── DAO-gated migration ─────────────────────────────────────────────────
    /// @notice Successor contract, set once the registry executes a migration
    ///         proposal against `KEY_NFT_FUND`. Non-zero means this contract is
    ///         retired: it stops taking value in and stops paying value out, so
    ///         its ledger can never drift from the balances that were moved.
    address public migratedTo;

    // ─── YIELD VAULT — distribution ledger ───────────────────────────────────
    struct DistributionRecord {
        uint256 timestamp;
        uint256 stepPerNFT;
        uint256 eligibleCount;
        /// @notice STEP credited by this round and not yet claimed. Every
        ///         claim decrements it, and whatever survives the claim window
        ///         is burned wholesale — so a holder who left the collection
        ///         cannot strand their share the way a per-holder sweep would.
        uint256 unclaimed;
    }
    DistributionRecord[] public distributions;

    uint256 public lastDistributionTime;
    /// @notice Oldest distribution id that can still hold a claimable balance;
    ///         everything below has been swept and burned.
    uint256 public oldestActivDistId;

    mapping(address => mapping(uint256 => uint256)) public userPendingRewards;
    mapping(address => uint256) public lastClaimedDistIndex;
    mapping(address => uint256) public lastClaimedTimestamp;
    mapping(address => uint256) public totalClaimed;
    mapping(address => uint256) public totalBurnedOf;

    // ─── Resumable round state ───────────────────────────────────────────────
    //  The walk runs over a virtual index space so promoted low-id tokens and
    //  the plain id range can share one resumable cursor:
    //
    //      v <  distPromotedLen   ->  promotedTokens[v]
    //      v >= distPromotedLen   ->  FIRST_YIELD_ID + (v - distPromotedLen)
    //
    //  Custody changes are refused while a round is open, so neither half can
    //  move under the cursor.
    bool    public distInProgress;
    uint256 public distCursor;         // next virtual index to credit
    uint256 public distTotalUnits;     // exclusive upper bound, snapshotted
    uint256 public distPromotedLen;    // promotedTokens.length at round start
    uint256 public distEndId;          // NFT.nextBuyId() at round start
    uint256 public distCurrentId;      // distributions index of this round
    uint256 public distAmountPerNFT;
    uint256 public distEligibleCount;  // eligible supply snapshotted at start
    uint256 public distCreditedCount;  // tokens actually credited this round

    // Expired-claim accumulators, round-scoped and persisted across batches,
    // exactly as `StepNFTTreasury` keeps them.
    uint256 public distExpiredBurnAccum;
    uint256 public distExpiredHolderAccum;
    bool    public distHasExpiredInRound;
    uint256 public distExpiredDistId;

    // ─── EVENTS ──────────────────────────────────────────────────────────────
    event Deposited(address indexed from, uint256 amount, uint256 toSale, uint256 toYield);
    event SaleVaultDonated(address indexed from, uint256 amount);
    event YieldVaultDonated(address indexed from, uint256 amount);
    event SellRequested(uint256 indexed orderId, address indexed seller, uint256 indexed tokenId, uint256 owedDai);
    event SellOrderSettled(uint256 indexed orderId, address indexed seller, uint256 indexed tokenId, uint256 stepPaid, bool fromVault);
    event SellOrderCancelled(uint256 indexed orderId, address indexed seller, uint256 indexed tokenId);
    event ListedNFTBought(
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 priceDai,
        uint256 feeDai,
        uint256 toQueueStep,
        uint256 toWallet90Step,
        uint256 toWallet10Step
    );
    event TokenPromoted(uint256 indexed tokenId, uint256 fromPriceDai, uint256 toPriceDai, bool joinedYield);
    event TreasuryRewardsSwept(uint256 amount);
    event DepositForwarded(address indexed successor, uint256 amount);
    event YieldDistributed(uint256 indexed distId, uint256 amount, uint256 stepPerNFT, uint256 eligibleCount);
    event YieldBatchProcessed(uint256 indexed distId, uint256 fromId, uint256 toId, uint256 credited);
    event YieldClaimed(address indexed user, uint256 amount);
    event ExpiredRewardsBurned(uint256 indexed distId, uint256 totalBurned, uint256 holderCount);
    event TokensBurned(address indexed user, uint256 amount);
    event SaleShareUpdated(uint256 bps);

    /**
     * @param registry_ StepRegistry — resolves STEP and the DEX, so a DAO
     *                  migration of either is picked up automatically.
     * @param dai_      DAI token.
     * @param nft_      The NFT collection this vault trades. Pinned for the
     *                  lifetime of the contract (see `NFT`). Its `wallet90` /
     *                  `wallet10` are read live, so a re-sale always pays the
     *                  same two wallets a fresh mint does.
     */
    constructor(address registry_, address dai_, address nft_) Ownable(msg.sender) {
        if (registry_ == address(0) || dai_ == address(0) || nft_ == address(0)) revert ZeroAddress();
        REGISTRY = IStepRegistry(registry_);
        DAI      = IERC20(dai_);
        NFT      = IStepNFT(nft_);
        // Needed once so this contract may route DAI through the public AMM
        // entry point when a listed NFT is bought.
        REGISTRY.acceptTerms();
    }

    // ─── INTERNAL RESOLVERS ──────────────────────────────────────────────────
    function _step() internal view returns (IStepCoin) { return IStepCoin(REGISTRY.get(REGISTRY.KEY_STEP_COIN())); }
    function _dex()  internal view returns (IStepDex)  { return IStepDex(REGISTRY.get(REGISTRY.KEY_STEP_DEX())); }

    /// @dev Spot STEP price in DAI (1e18). Reverts rather than paying out at
    ///      a price of zero.
    function _stepPrice() internal view returns (uint256 p) {
        p = _dex().getPrice();
        if (p == 0) revert PriceUnavailable();
    }

    function _calcMinStepOut(uint256 daiAmount, IStepDex dex) internal view returns (uint256) {
        if (daiAmount == 0) return 0;
        try dex.estimateBuy(daiAmount) returns (uint256 expected) {
            if (expected == 0) return 0;
            return (expected * MIN_STEP_BPS) / BPS_DENOMINATOR;
        } catch {
            return 0;
        }
    }

    /**
     * @dev The price a token counts as today: whatever this contract last
     *      re-sold it for, or its mint-curve price if it never passed through
     *      here. This is the figure the buy-back quote and yield eligibility
     *      both read, so a promoted token behaves as a full member of its new
     *      tier everywhere.
     */
    function _effectivePrice(uint256 tokenId) internal view returns (uint256) {
        uint256 t = tierOf[tokenId];
        return t != 0 ? t : NFT.getPrice(tokenId);
    }

    /// @dev The price the collection is minting at right now. Once the public
    ///      pool is sold out there is no day price left, so a listing falls
    ///      back to what the token itself is worth.
    function _dayPrice(uint256 tokenId) internal view returns (uint256 p) {
        p = NFT.getCurrentPrice();
        if (p == 0) p = _effectivePrice(tokenId);
    }

    /// @dev Pulls `amount` STEP from `msg.sender` and returns what actually
    ///      landed — STEP carries a transfer levy unless the payer is
    ///      whitelisted, so the credited figure is the received one.
    function _pullStep(uint256 amount) internal returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();
        IERC20 step = IERC20(address(_step()));
        uint256 before_ = step.balanceOf(address(this));
        step.safeTransferFrom(msg.sender, address(this), amount);
        received = step.balanceOf(address(this)) - before_;
        if (received == 0) revert ZeroAmount();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INFLOW
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit STEP and split it across the two vaults by
     *         `saleShareBps`. This is the entry point `StepSubscription`
     *         uses for its 20 % slice; anyone may also call it as a donation.
     *
     * @dev    After a DAO migration this forwards to the successor instead of
     *         reverting. Reverting would take the entire subscription line
     *         down with it, since `StepSubscription._splitStep` calls this on
     *         every payment and cannot route around a revert.
     */
    function depositSplit(uint256 amount) external nonReentrant {
        uint256 received = _pullStep(amount);

        address successor = migratedTo;
        if (successor != address(0)) {
            IERC20(address(_step())).safeTransfer(successor, received);
            emit DepositForwarded(successor, received);
            return;
        }

        uint256 toSale = (received * saleShareBps) / BPS_DENOMINATOR;
        uint256 toYield = received - toSale;

        saleVaultStep  += toSale;
        yieldVaultStep += toYield;

        emit Deposited(msg.sender, received, toSale, toYield);

        // A funded sale vault may unblock the head of the queue.
        if (toSale > 0) _settleQueue(AUTO_SETTLE_ON_DEPOSIT);
    }

    /// @notice Donate STEP straight into the buy-back vault.
    function donateToSaleVault(uint256 amount) external nonReentrant {
        uint256 received = _pullStep(amount);
        saleVaultStep += received;
        emit SaleVaultDonated(msg.sender, received);
        _settleQueue(AUTO_SETTLE_ON_DEPOSIT);
    }

    /// @notice Donate STEP straight into the daily-yield vault.
    function donateToYieldVault(uint256 amount) external nonReentrant {
        uint256 received = _pullStep(amount);
        yieldVaultStep += received;
        emit YieldVaultDonated(msg.sender, received);
    }

    /**
     * @notice Collect what the ORIGINAL NFT contract has credited to this
     *         contract, and hand it to the yield vault.
     * @dev    A token sitting in this contract's custody still counts in
     *         `StepNFTTreasury`'s own distribution, and that reward is
     *         credited to this address. Without this call it would simply sit
     *         there until its claim window closed and the treasury burned it.
     *         Sweeping it into the yield vault returns it to holders instead.
     *         Callable by anyone — a keeper should run it alongside
     *         `distributeYield`.
     * @return swept STEP that actually arrived.
     */
    function claimTreasuryRewards() external nonReentrant returns (uint256 swept) {
        IERC20 step = IERC20(address(_step()));
        uint256 before_ = step.balanceOf(address(this));
        NFT.claimRewards();
        swept = step.balanceOf(address(this)) - before_;
        if (swept > 0) {
            yieldVaultStep += swept;
            emit TreasuryRewardsSwept(swept);
        }
    }

    /// @notice What the original NFT contract currently owes this contract for
    ///         the tokens it holds in custody.
    function treasuryRewardsPending() external view returns (uint256) {
        try NFT.pendingOf(address(this)) returns (uint256 p) { return p; } catch { return 0; }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SALE VAULT
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Sell an NFT back to the protocol for half of what it is worth
     *         today — its mint-curve price, or the higher tier this contract
     *         last re-sold it at.
     * @param  tokenId     the NFT to hand over.
     * @param  minStepOut  floor on the STEP payout if it settles in this same
     *                     call; 0 to accept any. The NFT contract swaps its
     *                     own DAI transfer levy on the AMM as the token moves,
     *                     which nudges the spot price before the payout is
     *                     priced, so a quote taken beforehand is a few basis
     *                     points stale.
     *
     * @dev    The token is taken into custody immediately and re-listed at the
     *         CURRENT DAY PRICE, so it stays purchasable even while the payout
     *         is still queued. The payout itself is quoted in STEP at the spot
     *         price of the moment it clears, never at request time.
     *
     *         The NFT contract levies its own 10 % transfer fee in DAI on the
     *         `from` side of every move, so the seller must hold that fee in
     *         DAI and have approved the NFT contract for it — see
     *         `quoteSellback`. That levy is the NFT contract's own rule and
     *         is unchanged by this vault.
     */
    function sellToFund(uint256 tokenId, uint256 minStepOut) public nonReentrant {
        if (migratedTo != address(0)) revert AlreadyMigrated();
        if (distInProgress) revert DistributionInProgress();
        if (listed[tokenId]) revert AlreadyListed();

        IStepNFT nft = NFT;
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        uint256 priceDai = _effectivePrice(tokenId);
        uint256 owedDai  = (priceDai * SELLBACK_PCT) / PCT_DENOMINATOR;

        // Custody first, so the listing below is always backed by a real token.
        nft.transferFrom(msg.sender, address(this), tokenId);

        listed[tokenId] = true;
        escrowedTokens.push(tokenId);
        escrowIndex[tokenId] = escrowedTokens.length;
        // Tokens in custody earn nothing, so an eligible one leaves the split
        // for as long as it is held here.
        if (priceDai >= YIELD_MIN_PRICE) {
            unchecked { ++escrowedYieldCount; }
        }

        sellQueue.push(SellOrder({
            seller:    msg.sender,
            tokenId:   uint32(tokenId),
            paid:      false,
            cancelled: false,
            owedDai:   owedDai
        }));
        uint256 orderId = sellQueue.length - 1;
        orderOfToken[tokenId] = orderId + 1;

        emit SellRequested(orderId, msg.sender, tokenId, owedDai);

        // Settles right away when the vault is funded; otherwise the order
        // simply waits its turn. With maxItems = 1 at most one order clears,
        // so a non-zero return belongs to this order.
        uint256 paidStep = _settleQueue(1);

        if (minStepOut > 0 && (!sellQueue[orderId].paid || paidStep < minStepOut)) {
            revert SlippageExceeded();
        }
    }

    /// @notice Sell an NFT back with no floor on the payout.
    function sellToFund(uint256 tokenId) external {
        sellToFund(tokenId, 0);
    }

    /**
     * @notice Take an unsettled NFT back out of the desk. Only the original
     *         seller, and only while their order is still unpaid — once the
     *         vault has paid out, the sale is final.
     * @dev    Without this a single oversized order at the head of the FIFO
     *         queue could hold a seller's token hostage indefinitely.
     *
     *         The NFT contract charges its transfer levy to whichever address
     *         the token moves FROM, which here is this contract — and this
     *         contract holds no DAI. So the levy is pulled from the canceller
     *         first: they must have approved `cancelFeeDai(tokenId)` to THIS
     *         contract (not to the NFT contract, as a normal sale would).
     */
    function cancelSellOrder(uint256 tokenId) external nonReentrant {
        if (distInProgress) revert DistributionInProgress();
        if (!listed[tokenId]) revert NotListed();

        uint256 oid = orderOfToken[tokenId];
        if (oid == 0) revert NotListed();
        SellOrder storage o = sellQueue[oid - 1];
        if (o.seller != msg.sender) revert NotTokenOwner();
        if (o.paid || o.cancelled) revert NothingToSettle();

        o.cancelled = true;
        orderOfToken[tokenId] = 0;
        _releaseCustody(tokenId);

        uint256 feeDai = (NFT.getPrice(tokenId) * TRANSFER_FEE_PCT) / PCT_DENOMINATOR;
        if (feeDai > 0) DAI.safeTransferFrom(msg.sender, address(this), feeDai);
        DAI.forceApprove(address(NFT), feeDai);
        NFT.transferFrom(address(this), msg.sender, tokenId);
        DAI.forceApprove(address(NFT), 0);

        emit SellOrderCancelled(oid - 1, msg.sender, tokenId);
    }

    /// @notice DAI the canceller must approve to THIS contract to withdraw
    ///         `tokenId` from the desk.
    function cancelFeeDai(uint256 tokenId) external view returns (uint256) {
        return (NFT.getPrice(tokenId) * TRANSFER_FEE_PCT) / PCT_DENOMINATOR;
    }

    /// @dev Drops a token out of the listing / escrow set and restores it to
    ///      the yield split if it is eligible.
    function _releaseCustody(uint256 tokenId) internal {
        listed[tokenId] = false;
        _dropEscrow(tokenId);
        if (_effectivePrice(tokenId) >= YIELD_MIN_PRICE && escrowedYieldCount > 0) {
            unchecked { --escrowedYieldCount; }
        }
    }

    /**
     * @notice Clear as many queued buy-backs as the sale vault can cover.
     *         Callable by anyone (keeper, or a seller nudging their order).
     * @dev    Strict FIFO: the walk stops at the first order the vault cannot
     *         cover, so a later order can never jump an earlier one.
     */
    function settleQueue(uint256 maxItems) external nonReentrant {
        if (maxItems == 0) revert ZeroAmount();
        uint256 headBefore = queueHead;
        _settleQueue(maxItems);
        if (queueHead == headBefore) revert NothingToSettle();
    }

    /// @return lastPaid STEP handed to the seller of the last order cleared in
    ///         this call; zero when nothing settled.
    function _settleQueue(uint256 maxItems) internal returns (uint256 lastPaid) {
        if (migratedTo != address(0)) return 0;
        uint256 len = sellQueue.length;
        if (queueHead >= len || maxItems == 0) return 0;

        uint256 price = _dex().getPrice();
        if (price == 0) return 0;

        IERC20 step = IERC20(address(_step()));
        uint256 processed;

        while (queueHead < len && processed < maxItems) {
            SellOrder storage o = sellQueue[queueHead];

            // Already cleared by a direct buyer, or withdrawn by the seller —
            // just walk past it.
            if (o.paid || o.cancelled) {
                unchecked { ++queueHead; ++processed; }
                continue;
            }

            uint256 stepOwed = (o.owedDai * PRECISION) / price;
            if (stepOwed == 0 || saleVaultStep < stepOwed) break;

            saleVaultStep -= stepOwed;
            o.paid = true;
            address seller = o.seller;
            uint256 tokenId = o.tokenId;
            uint256 orderId = queueHead;
            unchecked { ++queueHead; ++processed; }

            step.safeTransfer(seller, stepOwed);
            lastPaid = stepOwed;
            emit SellOrderSettled(orderId, seller, tokenId, stepOwed, true);
        }
    }

    /**
     * @dev Locates the first order in the queue that is still owed money,
     *      stepping over any that a direct buyer or a cancellation already
     *      closed. The scan is bounded; if the dead run is longer than
     *      `QUEUE_LOOKAHEAD` the caller simply sees no live order, and a
     *      `settleQueue` call will walk `queueHead` forward.
     * @return found   whether a live order was reached.
     * @return skip    dead entries sitting in front of it.
     * @return owedDai what it is owed, in DAI.
     */
    function _firstLiveOrder() internal view returns (bool found, uint256 skip, uint256 owedDai) {
        uint256 len = sellQueue.length;
        uint256 i = queueHead;
        uint256 scanned;
        while (i < len && scanned < QUEUE_LOOKAHEAD) {
            SellOrder storage o = sellQueue[i];
            if (!o.paid && !o.cancelled) return (true, scanned, o.owedDai);
            unchecked { ++i; ++scanned; }
        }
        return (false, 0, 0);
    }

    /// @dev STEP the sale vault is short of covering the first live order.
    ///      Zero when the queue is empty or the vault already covers it.
    function _headShortfallStep() internal view returns (uint256) {
        (bool found, , uint256 owedDai) = _firstLiveOrder();
        if (!found) return 0;
        uint256 price = _dex().getPrice();
        if (price == 0) return 0;
        uint256 stepOwed = (owedDai * PRECISION) / price;
        return stepOwed > saleVaultStep ? stepOwed - saleVaultStep : 0;
    }

    /**
     * @notice Buy an NFT held by this contract. It is priced at the CURRENT
     *         DAY PRICE — whatever the collection is minting at right now —
     *         regardless of the id it was originally minted under.
     * @param  tokenId     the listed NFT.
     * @param  maxPriceDai upper bound the caller accepts (0 = no bound).
     *
     * @dev    The price is applied in three steps, in this order:
     *
     *           1. the NFT contract's own transfer levy is carved out in DAI,
     *              because that levy is charged to this contract as the token
     *              leaves custody and cannot be waived. It is assessed on the
     *              token's MINT price, which is the NFT contract's rule;
     *
     *           2. the rest is converted to STEP, and whatever the sale vault
     *              is SHORT of paying the FIRST outstanding order in the queue
     *              is moved into the vault, which then settles that one order.
     *              Exactly one — the next order in line waits for the next
     *              sale. When the vault already covers the head, or the queue
     *              is empty, this step takes nothing;
     *
     *           3. everything still left splits 90 / 10 across the same two
     *              wallets a fresh mint pays.
     *
     *         Worked example. A 400-DAI NFT was sold to the desk, so a seller
     *         is owed 200 DAI. The vault holds 50 DAI. The day price is 800:
     *
     *              800  price the buyer pays
     *             - 80  transfer levy (10 % of the mint price)
     *             -150  into the vault, taking it 50 -> 200, clearing the order
     *             ─────
     *              570  split 90 / 10  =>  513 + 57
     *
     *         The token is promoted to the tier it sold at, so from here on it
     *         quotes, earns and re-sells as a member of that tier.
     */
    function buyListed(uint256 tokenId, uint256 maxPriceDai) external nonReentrant {
        if (migratedTo != address(0)) revert AlreadyMigrated();
        if (distInProgress) revert DistributionInProgress();
        if (!listed[tokenId]) revert NotListed();

        IStepNFT nft = NFT;
        uint256 priceDai = _dayPrice(tokenId);
        if (priceDai == 0) revert PriceUnavailable();
        if (maxPriceDai > 0 && priceDai > maxPriceDai) revert PriceExceedsMax();

        // The levy the NFT contract will pull from this contract on transfer.
        uint256 feeDai = (nft.getPrice(tokenId) * TRANSFER_FEE_PCT) / PCT_DENOMINATOR;
        if (feeDai >= priceDai) revert PriceUnavailable();
        uint256 swapDai = priceDai - feeDai;

        // Measured before the swap, because the swap itself lifts the STEP
        // price — so this over-states the need by a hair and the head order is
        // certain to clear afterwards.
        (, uint256 skip, ) = _firstLiveOrder();
        uint256 shortfallStep = _headShortfallStep();

        DAI.safeTransferFrom(msg.sender, address(this), priceDai);

        // Convert everything but the levy into STEP.
        IStepDex dex  = _dex();
        IERC20   step = IERC20(address(_step()));
        uint256 minOut = _calcMinStepOut(swapDai, dex);
        DAI.forceApprove(address(dex), swapDai);
        uint256 stepBefore = step.balanceOf(address(this));
        dex.buyStepPublic(swapDai, minOut);
        uint256 stepIn = step.balanceOf(address(this)) - stepBefore;

        // Top the vault up for the head of the queue, then split what is left.
        uint256 toQueue = shortfallStep < stepIn ? shortfallStep : stepIn;
        uint256 rest    = stepIn - toQueue;
        uint256 to90    = (rest * RESALE_W90_PCT) / PCT_DENOMINATOR;
        uint256 to10    = rest - to90;

        if (toQueue > 0) saleVaultStep += toQueue;

        // This token leaves custody; any order still open against it stays in
        // the queue and is paid from the vault like any other.
        if (orderOfToken[tokenId] != 0) orderOfToken[tokenId] = 0;

        _releaseCustody(tokenId);
        _promote(tokenId, priceDai);

        // The NFT contract pulls `feeDai` from this contract as the token moves.
        DAI.forceApprove(address(nft), feeDai);
        nft.transferFrom(address(this), msg.sender, tokenId);
        DAI.forceApprove(address(nft), 0);

        if (to90 > 0) step.safeTransfer(nft.wallet90(), to90);
        if (to10 > 0) step.safeTransfer(nft.wallet10(), to10);

        emit ListedNFTBought(msg.sender, tokenId, priceDai, feeDai, toQueue, to90, to10);

        // Clear exactly the one order the top-up was sized for. The budget
        // covers the dead entries in front of it so they cannot absorb it.
        if (toQueue > 0) _settleQueue(skip + 1);
    }

    /**
     * @dev Records the tier a token now belongs to, and enrols it in the yield
     *      walk when its id sits below `FIRST_YIELD_ID` — the id range alone
     *      can never reach those, so they need an explicit set.
     */
    function _promote(uint256 tokenId, uint256 newPriceDai) internal {
        uint256 oldPrice = _effectivePrice(tokenId);
        tierOf[tokenId] = newPriceDai;

        bool joined = false;
        if (tokenId < FIRST_YIELD_ID && newPriceDai >= YIELD_MIN_PRICE && promotedIndex[tokenId] == 0) {
            promotedTokens.push(tokenId);
            promotedIndex[tokenId] = promotedTokens.length;
            joined = true;
        }
        emit TokenPromoted(tokenId, oldPrice, newPriceDai, joined);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  YIELD VAULT
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice NFTs currently entitled to yield: every minted id at or above
    ///         `FIRST_YIELD_ID`, less the ones sitting in this contract's own
    ///         custody (which earn nothing).
    function eligibleNftCount() public view returns (uint256) {
        uint256 endId  = NFT.nextBuyId();
        uint256 minted = endId > FIRST_YIELD_ID ? endId - FIRST_YIELD_ID : 0;
        uint256 total  = minted + promotedTokens.length;
        uint256 held   = escrowedYieldCount;
        return total > held ? total - held : 0;
    }

    /// @dev Maps a virtual walk index onto the token id it stands for.
    ///      Indices below `promotedLen` address the promoted set; the rest run
    ///      through the plain id range from `FIRST_YIELD_ID` up.
    function _idAt(uint256 v, uint256 promotedLen) internal view returns (uint256) {
        return v < promotedLen ? promotedTokens[v] : FIRST_YIELD_ID + (v - promotedLen);
    }

    /**
     * @notice STEP recorded against rounds that are already closed and can
     *         therefore never be claimed or burned.
     * @dev    The expiry sweep visits holders, not rounds — the same rule
     *         `StepNFTTreasury` applies — so a holder who parted with their
     *         last eligible NFT before their round expired is never revisited
     *         and their share stays on the books. This view surfaces exactly
     *         how much that is, which the original contract cannot report.
     */
    function strandedRewards() external view returns (uint256 total, uint256 rounds) {
        uint256 oldest = oldestActivDistId;
        for (uint256 d = 0; d < oldest; ) {
            uint256 u = distributions[d].unclaimed;
            if (u > 0) { total += u; unchecked { ++rounds; } }
            unchecked { ++d; }
        }
    }

    /**
     * @notice Run (or resume) the daily yield distribution. Anyone may call.
     * @dev    Resumable: a round opens once per `DISTRIBUTION_INTERVAL` and
     *         credits ids in batches of `DIST_BATCH_SIZE`, persisting a cursor
     *         so it can never be too large to finish. While a round is open,
     *         custody changes are refused so the eligible count snapshotted at
     *         the start stays exact.
     */
    function distributeYield() external nonReentrant {
        if (migratedTo != address(0)) revert AlreadyMigrated();
        if (!distInProgress) {
            if (block.timestamp < lastDistributionTime + DISTRIBUTION_INTERVAL) revert TooEarly();
            if (yieldVaultStep == 0) revert NoRewards();

            uint256 endId = NFT.nextBuyId();
            uint256 count = eligibleNftCount();
            if (count == 0) revert NoEligibleNFTs();

            uint256 total  = yieldVaultStep;
            uint256 perNFT = total / count;
            if (perNFT == 0) revert NoRewards();

            // Only the exactly-divisible part leaves the vault; the dust rolls
            // into the next round.
            yieldVaultStep       = total - (perNFT * count);
            lastDistributionTime = block.timestamp;

            uint256 pLen = promotedTokens.length;

            distCurrentId = distributions.length;
            distributions.push(DistributionRecord({
                timestamp:     block.timestamp,
                stepPerNFT:    perNFT,
                eligibleCount: count,
                unclaimed:     0
            }));

            distInProgress    = true;
            distCursor        = 0;
            distPromotedLen   = pLen;
            distEndId         = endId;
            distTotalUnits    = pLen + (endId > FIRST_YIELD_ID ? endId - FIRST_YIELD_ID : 0);
            distAmountPerNFT  = perNFT;
            distEligibleCount = count;
            distCreditedCount = 0;

            // Each round starts with a clean slate, so one round's expiry data
            // can never bleed into the next.
            distExpiredBurnAccum   = 0;
            distExpiredHolderAccum = 0;
            distHasExpiredInRound  = false;
            distExpiredDistId      = 0;

            emit YieldDistributed(distCurrentId, perNFT * count, perNFT, count);
        }

        uint256 from = distCursor;
        uint256 to   = from + DIST_BATCH_SIZE;
        if (to > distTotalUnits) to = distTotalUnits;

        uint256 distId      = distCurrentId;
        uint256 perUnit     = distAmountPerNFT;
        uint256 promotedLen = distPromotedLen;

        // Expiry state is read from storage, not locals, so every batch of the
        // round shares one view: once any batch detects an expiry, the rest act
        // on it too. Same shape as `StepNFTTreasury.distributeRewards`.
        bool    hasExpired    = distHasExpiredInRound;
        uint256 expiredDistId = distExpiredDistId;
        if (!hasExpired) {
            uint256 oldest = oldestActivDistId;
            if (oldest < distId && block.timestamp >= distributions[oldest].timestamp + CLAIM_DEADLINE) {
                hasExpired            = true;
                expiredDistId         = oldest;
                distHasExpiredInRound = true;
                distExpiredDistId     = oldest;
            }
        }

        IStepNFT nft = NFT;
        uint256 credited;
        uint256 burnAccum;
        uint256 holderAccum;

        for (uint256 v = from; v < to; ) {
            address holder = _ownerOrZero(nft, _idAt(v, promotedLen));
            // address(0) = never minted; this contract = held in custody.
            if (holder != address(0) && holder != address(this)) {
                userPendingRewards[holder][distId] += perUnit;
                unchecked { ++credited; }

                if (hasExpired) {
                    uint256 expiredAmt = userPendingRewards[holder][expiredDistId];
                    if (expiredAmt > 0) {
                        userPendingRewards[holder][expiredDistId] = 0;
                        totalBurnedOf[holder] += expiredAmt;
                        burnAccum   += expiredAmt;
                        unchecked { ++holderAccum; }
                    }
                }
            }
            unchecked { ++v; }
        }

        distCursor              = to;
        distCreditedCount      += credited;
        distExpiredBurnAccum   += burnAccum;
        distExpiredHolderAccum += holderAccum;

        emit YieldBatchProcessed(distId, from, to, credited);

        if (to >= distTotalUnits) _finalizeRound();
    }

    function _finalizeRound() internal {
        uint256 perUnit  = distAmountPerNFT;
        uint256 credited = distCreditedCount;

        // Only what was actually credited becomes a liability; anything the
        // snapshot promised but no live holder claimed returns to the vault,
        // so the two vault counters and the ledger always reconcile.
        uint256 issued = perUnit * credited;
        totalPendingRewards += issued;
        distributions[distCurrentId].unclaimed = issued;

        uint256 planned = perUnit * distEligibleCount;
        if (planned > issued) yieldVaultStep += planned - issued;

        // Burn against the round-wide accumulator, i.e. the sum across every
        // batch — the same rule `StepNFTTreasury` applies.
        if (distHasExpiredInRound) {
            uint256 burnAmt = distExpiredBurnAccum;
            if (burnAmt > 0) {
                totalPendingRewards -= burnAmt;
                distributions[distExpiredDistId].unclaimed -= burnAmt;
                _step().burn(burnAmt);
                emit ExpiredRewardsBurned(distExpiredDistId, burnAmt, distExpiredHolderAccum);
            }
            unchecked { oldestActivDistId = distExpiredDistId + 1; }
        }

        distInProgress    = false;
        distCursor        = 0;
        distTotalUnits    = 0;
        distPromotedLen   = 0;
        distEndId         = 0;
        distAmountPerNFT  = 0;
        distEligibleCount = 0;
        distCreditedCount = 0;
    }

    function _ownerOrZero(IStepNFT nft, uint256 id) internal view returns (address) {
        try nft.ownerOf(id) returns (address o) { return o; } catch { return address(0); }
    }

    /**
     * @notice Claim accrued yield. Rounds older than `CLAIM_DEADLINE` are
     *         burned rather than paid — the same forfeit rule the NFT
     *         treasury applies.
     */
    function claimYield() external nonReentrant {
        // After a migration the STEP backing these claims lives on the
        // successor, which honours them; paying here would double-spend it.
        if (migratedTo != address(0)) revert AlreadyMigrated();
        uint256 len    = distributions.length;
        uint256 oldest = oldestActivDistId;
        uint256 start  = lastClaimedDistIndex[msg.sender];
        if (start < oldest) start = oldest;
        if (start >= len) revert NothingToClaim();

        uint256 totalOwed;
        uint256 totalToBurn;
        uint256 latestTs = lastClaimedTimestamp[msg.sender];

        for (uint256 d = start; d < len; ) {
            DistributionRecord memory dist = distributions[d];
            if (dist.timestamp <= lastClaimedTimestamp[msg.sender]) {
                unchecked { ++d; }
                continue;
            }

            uint256 r = userPendingRewards[msg.sender][d];
            if (r > 0) {
                userPendingRewards[msg.sender][d] = 0;
                // Retire the claim against its round, so the wholesale expiry
                // sweep can never burn this amount a second time.
                distributions[d].unclaimed -= r;
                if (block.timestamp >= dist.timestamp + CLAIM_DEADLINE) {
                    totalToBurn += r;
                } else {
                    totalOwed += r;
                    if (dist.timestamp > latestTs) latestTs = dist.timestamp;
                }
            }
            unchecked { ++d; }
        }

        if (totalOwed == 0 && totalToBurn == 0) revert NothingToClaim();

        lastClaimedDistIndex[msg.sender] = len;
        lastClaimedTimestamp[msg.sender] = latestTs;
        totalPendingRewards -= (totalOwed + totalToBurn);

        if (totalToBurn > 0) {
            _step().burn(totalToBurn);
            totalBurnedOf[msg.sender] += totalToBurn;
            emit TokensBurned(msg.sender, totalToBurn);
        }
        if (totalOwed > 0) {
            totalClaimed[msg.sender] += totalOwed;
            IERC20(address(_step())).safeTransfer(msg.sender, totalOwed);
            emit YieldClaimed(msg.sender, totalOwed);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @notice Full picture of where the contract's STEP sits.
     * @return sale      buy-back vault balance.
     * @return yield     undistributed daily-yield balance.
     * @return pending   already distributed, awaiting claim.
     * @return balance   the contract's actual STEP balance.
     * @return surplus   balance minus the three tracked buckets — must never
     *                   be negative, and is normally zero or a stray donation.
     */
    function vaultBalances()
        external
        view
        returns (uint256 sale, uint256 yield, uint256 pending, uint256 balance, uint256 surplus)
    {
        sale    = saleVaultStep;
        yield   = yieldVaultStep;
        pending = totalPendingRewards;
        balance = IERC20(address(_step())).balanceOf(address(this));
        uint256 tracked = sale + yield + pending;
        surplus = balance > tracked ? balance - tracked : 0;
    }

    /// @notice What selling `tokenId` back would cost and pay right now.
    /// @return priceDai       the NFT's list price.
    /// @return owedDai        the 50 % buy-back amount, in DAI.
    /// @return stepOwedNow    that amount in STEP at the current spot price.
    /// @return vaultCovers    whether the sale vault can pay it immediately.
    /// @return transferFeeDai DAI the seller must have approved to the NFT
    ///                        contract for its own transfer levy.
    function quoteSellback(uint256 tokenId)
        external
        view
        returns (uint256 priceDai, uint256 owedDai, uint256 stepOwedNow, bool vaultCovers, uint256 transferFeeDai)
    {
        priceDai       = _effectivePrice(tokenId);
        owedDai        = (priceDai * SELLBACK_PCT) / PCT_DENOMINATOR;
        // The levy is the NFT contract's own rule and always tracks the mint
        // price, even for a token this contract has promoted.
        transferFeeDai = (NFT.getPrice(tokenId) * TRANSFER_FEE_PCT) / PCT_DENOMINATOR;
        uint256 p = _dex().getPrice();
        stepOwedNow = p == 0 ? 0 : (owedDai * PRECISION) / p;
        vaultCovers = stepOwedNow > 0 && saleVaultStep >= stepOwedNow;
    }

    /**
     * @notice What buying `tokenId` off this desk costs and where it goes, in
     *         DAI terms, right now.
     * @return priceDai   the day price the buyer pays.
     * @return feeDai     carved out for the NFT contract's transfer levy.
     * @return swapDai    converted to STEP — the sum of the three below.
     * @return toQueueDai moved into the sale vault to clear the FIRST
     *                    outstanding buy-back order. Zero when the queue is
     *                    empty or the vault already covers its head.
     * @return toWallet90 the 90 % slice of what remains.
     * @return toWallet10 the 10 % slice of what remains.
     */
    function quoteBuyListed(uint256 tokenId)
        external
        view
        returns (
            uint256 priceDai,
            uint256 feeDai,
            uint256 swapDai,
            uint256 toQueueDai,
            uint256 toWallet90,
            uint256 toWallet10
        )
    {
        priceDai = _dayPrice(tokenId);
        feeDai   = (NFT.getPrice(tokenId) * TRANSFER_FEE_PCT) / PCT_DENOMINATOR;
        if (feeDai >= priceDai) return (priceDai, feeDai, 0, 0, 0, 0);
        swapDai = priceDai - feeDai;

        (bool found, , uint256 owedDai) = _firstLiveOrder();
        if (found) {
            uint256 price = _dex().getPrice();
            if (price > 0) {
                uint256 vaultDai = (saleVaultStep * price) / PRECISION;
                if (owedDai > vaultDai) {
                    toQueueDai = owedDai - vaultDai;
                    if (toQueueDai > swapDai) toQueueDai = swapDai;
                }
            }
        }

        uint256 rest = swapDai - toQueueDai;
        toWallet90 = (rest * RESALE_W90_PCT) / PCT_DENOMINATOR;
        toWallet10 = rest - toWallet90;
    }

    /// @notice Everything about a token's tier in one call.
    /// @return mintPrice     what the mint curve says the id is worth.
    /// @return effectivePrice what it counts as today.
    /// @return promoted      whether a re-sale here lifted it above its id.
    /// @return earnsYield    whether it is in the daily split (custody aside).
    function tokenTier(uint256 tokenId)
        external
        view
        returns (uint256 mintPrice, uint256 effectivePrice, bool promoted, bool earnsYield)
    {
        mintPrice      = NFT.getPrice(tokenId);
        effectivePrice = _effectivePrice(tokenId);
        promoted       = tierOf[tokenId] != 0;
        earnsYield     = effectivePrice >= YIELD_MIN_PRICE;
    }

    /// @notice How many low-id tokens a re-sale has lifted into the yield tier.
    function promotedCount() external view returns (uint256) { return promotedTokens.length; }

    /// @notice Queue health in one call.
    function queueInfo()
        external
        view
        returns (uint256 total, uint256 head, uint256 outstanding, uint256 outstandingDai, uint256 outstandingStepNow)
    {
        total = sellQueue.length;
        head  = queueHead;
        for (uint256 i = head; i < total; ) {
            if (!sellQueue[i].paid && !sellQueue[i].cancelled) {
                unchecked { ++outstanding; }
                outstandingDai += sellQueue[i].owedDai;
            }
            unchecked { ++i; }
        }
        uint256 p = _dex().getPrice();
        outstandingStepNow = p == 0 ? 0 : (outstandingDai * PRECISION) / p;
    }

    /// @notice Page through the sell queue.
    function getSellOrders(uint256 start, uint256 limit)
        external
        view
        returns (
            uint256[] memory orderIds,
            address[] memory sellers,
            uint256[] memory tokenIds,
            uint256[] memory owedDai,
            bool[]    memory paid,
            bool[]    memory cancelled
        )
    {
        uint256 total = sellQueue.length;
        if (start >= total) {
            return (
                new uint256[](0), new address[](0), new uint256[](0),
                new uint256[](0), new bool[](0),    new bool[](0)
            );
        }
        uint256 len = (start + limit > total) ? total - start : limit;
        orderIds  = new uint256[](len);
        sellers   = new address[](len);
        tokenIds  = new uint256[](len);
        owedDai   = new uint256[](len);
        paid      = new bool[](len);
        cancelled = new bool[](len);
        for (uint256 i = 0; i < len; ) {
            SellOrder memory o = sellQueue[start + i];
            orderIds[i]  = start + i;
            sellers[i]   = o.seller;
            tokenIds[i]  = o.tokenId;
            owedDai[i]   = o.owedDai;
            paid[i]      = o.paid;
            cancelled[i] = o.cancelled;
            unchecked { ++i; }
        }
    }

    /// @notice Ids currently in custody and buyable, scanning `[from, to)`.
    function listedTokens(uint256 from, uint256 to) external view returns (uint256[] memory ids) {
        if (to <= from) return new uint256[](0);
        uint256 n;
        for (uint256 i = from; i < to; ) {
            if (listed[i]) { unchecked { ++n; } }
            unchecked { ++i; }
        }
        ids = new uint256[](n);
        uint256 k;
        for (uint256 i = from; i < to; ) {
            if (listed[i]) { ids[k] = i; unchecked { ++k; } }
            unchecked { ++i; }
        }
    }

    function getTimeUntilNextDistribution() external view returns (uint256) {
        uint256 next = lastDistributionTime + DISTRIBUTION_INTERVAL;
        return block.timestamp >= next ? 0 : next - block.timestamp;
    }

    function distributionCount() external view returns (uint256) { return distributions.length; }

    function getDistributions(uint256 start, uint256 limit)
        external
        view
        returns (
            uint256[] memory ids,
            uint256[] memory timestamps,
            uint256[] memory stepPerNFT,
            uint256[] memory eligibleCounts,
            bool[]    memory expired,
            uint256[] memory timeLeft
        )
    {
        uint256 total = distributions.length;
        if (start >= total) {
            return (
                new uint256[](0), new uint256[](0), new uint256[](0),
                new uint256[](0), new bool[](0),    new uint256[](0)
            );
        }
        uint256 len = (start + limit > total) ? total - start : limit;
        ids            = new uint256[](len);
        timestamps     = new uint256[](len);
        stepPerNFT     = new uint256[](len);
        eligibleCounts = new uint256[](len);
        expired        = new bool[](len);
        timeLeft       = new uint256[](len);
        for (uint256 i = 0; i < len; ) {
            DistributionRecord memory d = distributions[start + i];
            ids[i]            = start + i;
            timestamps[i]     = d.timestamp;
            stepPerNFT[i]     = d.stepPerNFT;
            eligibleCounts[i] = d.eligibleCount;
            uint256 deadline  = d.timestamp + CLAIM_DEADLINE;
            bool isExpired    = block.timestamp >= deadline;
            expired[i]  = isExpired;
            timeLeft[i] = isExpired ? 0 : deadline - block.timestamp;
            unchecked { ++i; }
        }
    }

    /// @notice Claimable / already-expired split for one holder.
    function getRewardInfo(address user)
        external
        view
        returns (
            uint256 pendingClaimable,
            uint256 pendingExpired,
            uint256 totalClaimedAmount,
            uint256 totalBurnedAmount,
            uint256 timeUntilClaimDeadline,
            bool    claimWindowExpired
        )
    {
        uint256 start = lastClaimedDistIndex[user];
        if (start < oldestActivDistId) start = oldestActivDistId;
        uint256 len = distributions.length;
        for (uint256 d = start; d < len; ) {
            DistributionRecord memory dist = distributions[d];
            if (dist.timestamp > lastClaimedTimestamp[user]) {
                uint256 r = userPendingRewards[user][d];
                if (r > 0) {
                    if (block.timestamp >= dist.timestamp + CLAIM_DEADLINE) pendingExpired   += r;
                    else                                                    pendingClaimable += r;
                }
            }
            unchecked { ++d; }
        }
        totalClaimedAmount = totalClaimed[user];
        totalBurnedAmount  = totalBurnedOf[user];

        if (len > 0) {
            uint256 deadline = distributions[len - 1].timestamp + CLAIM_DEADLINE;
            if (block.timestamp >= deadline) claimWindowExpired = true;
            else timeUntilClaimDeadline = deadline - block.timestamp;
        }
    }

    function pendingOf(address user) external view returns (uint256 pending) {
        uint256 start = lastClaimedDistIndex[user];
        if (start < oldestActivDistId) start = oldestActivDistId;
        uint256 len = distributions.length;
        for (uint256 d = start; d < len; ) {
            DistributionRecord memory dist = distributions[d];
            if (dist.timestamp > lastClaimedTimestamp[user] && block.timestamp < dist.timestamp + CLAIM_DEADLINE) {
                pending += userPendingRewards[user][d];
            }
            unchecked { ++d; }
        }
    }

    function getDistributionStatus()
        external
        view
        returns (bool inProgress, uint256 cursor, uint256 endId, uint256 currentDistId, uint256 amountPerNFT, uint256 credited)
    {
        inProgress    = distInProgress;
        cursor        = distCursor;
        endId         = distEndId;
        currentDistId = distCurrentId;
        amountPerNFT  = distAmountPerNFT;
        credited      = distCreditedCount;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Change how inbound deposits divide between the two vaults.
    ///         Only affects deposits made after the change.
    function setSaleShareBps(uint256 bps) external onlyOwner {
        if (bps > BPS_DENOMINATOR) revert BadShare();
        saleShareBps = bps;
        emit SaleShareUpdated(bps);
    }

    // No public `acceptTerms()` here on purpose. The constructor accepts once,
    // and `StepRegistry` records acceptance as a permanent, un-versioned
    // timestamp against a `constant` terms string — there is no reissue path
    // and no way to clear it, so a second call could never be needed.

    /// @dev Swap-pop removal from the enumerable escrow set.
    function _dropEscrow(uint256 tokenId) internal {
        uint256 idx = escrowIndex[tokenId];
        if (idx == 0) return;
        uint256 last = escrowedTokens.length;
        if (idx != last) {
            uint256 moved = escrowedTokens[last - 1];
            escrowedTokens[idx - 1] = moved;
            escrowIndex[moved] = idx;
        }
        escrowedTokens.pop();
        escrowIndex[tokenId] = 0;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DAO-GATED MIGRATION
    //
    //  Identical in shape to the escape hatch every other contract in the
    //  system carries (StepCoin, StepDex, StepNet, StepNFTTreasury): the ONLY
    //  caller accepted is the registry, and the registry only calls it from
    //  `executeMigration`, i.e. after a migration proposal has been raised by a
    //  Box-5 holder, cleared the voting threshold, survived the veto window and
    //  served the timelock. There is no owner path and no deployer path.
    //
    //  For the registry to reach this contract it must be listed under
    //  `KEY_NFT_FUND`; the controller sets that once with
    //  `setInitial(KEY_NFT_FUND, <this>)`, which stays available after DAO
    //  activation because the key has never been written.
    // ═════════════════════════════════════════════════════════════════════════

    event AssetsMigrated(address indexed to, uint256 stepAmount, uint256 daiAmount);
    event EscrowedNFTsMigrated(address indexed to, uint256 count, uint256 remaining);

    /**
     * @notice Hand the contract's fungible balances to a successor and retire
     *         this one. Registry-only.
     * @dev    Retirement is what keeps the books honest: once `migratedTo` is
     *         set, this contract stops accepting deposits, stops buying back,
     *         stops distributing and stops paying claims — so the ledger it
     *         leaves behind still describes exactly the balances that moved.
     *         The successor inherits both vault balances plus the outstanding
     *         claim liability and is responsible for honouring them.
     *
     *         Escrowed NFTs are moved separately by `migrateEscrowedNFTs`,
     *         because the NFT contract charges its transfer levy per token and
     *         an unbounded loop here could make `executeMigration` un-runnable.
     */
    function migrateAssetsTo(address newContract) external {
        if (msg.sender != address(REGISTRY)) revert NotAuthorized();
        if (newContract == address(0)) revert ZeroAddress();
        if (migratedTo != address(0)) revert AlreadyMigrated();

        migratedTo = newContract;

        IERC20  step    = IERC20(address(_step()));
        uint256 stepBal = step.balanceOf(address(this));
        uint256 daiBal  = DAI.balanceOf(address(this));

        if (stepBal > 0) step.safeTransfer(newContract, stepBal);
        if (daiBal  > 0) DAI.safeTransfer(newContract, daiBal);

        emit AssetsMigrated(newContract, stepBal, daiBal);
    }

    /**
     * @notice Forward NFTs still held in custody to the successor, in bounded
     *         batches. Permissionless once the DAO has fixed the destination —
     *         the target is `migratedTo` and cannot be chosen by the caller.
     * @param  maxCount tokens to move this call; 0 means "as many as are left".
     * @dev    The NFT contract levies its transfer fee in DAI on the sending
     *         side, so this contract must hold `escrowMigrationFeeDai(maxCount)`
     *         worth of DAI. `migrateAssetsTo` sweeps DAI out, so whoever runs
     *         the migration tops this contract up first — a plain DAI transfer
     *         to this address is enough.
     */
    function migrateEscrowedNFTs(uint256 maxCount) external nonReentrant {
        address to = migratedTo;
        if (to == address(0)) revert NotMigrated();

        uint256 left = escrowedTokens.length;
        if (left == 0) revert NothingToMigrate();
        if (maxCount == 0 || maxCount > left) maxCount = left;

        for (uint256 i = 0; i < maxCount; ) {
            uint256 tokenId = escrowedTokens[escrowedTokens.length - 1];
            uint256 feeDai  = (NFT.getPrice(tokenId) * TRANSFER_FEE_PCT) / PCT_DENOMINATOR;

            escrowedTokens.pop();
            escrowIndex[tokenId] = 0;
            listed[tokenId]      = false;
            if (tokenId >= FIRST_YIELD_ID && escrowedYieldCount > 0) {
                unchecked { --escrowedYieldCount; }
            }

            DAI.forceApprove(address(NFT), feeDai);
            NFT.transferFrom(address(this), to, tokenId);

            unchecked { ++i; }
        }
        DAI.forceApprove(address(NFT), 0);

        emit EscrowedNFTsMigrated(to, maxCount, escrowedTokens.length);
    }

    /// @notice DAI needed to move the next `maxCount` escrowed tokens across,
    ///         at the NFT contract's own transfer-levy rate.
    function escrowMigrationFeeDai(uint256 maxCount) external view returns (uint256 feeDai) {
        uint256 left = escrowedTokens.length;
        if (maxCount == 0 || maxCount > left) maxCount = left;
        for (uint256 i = 0; i < maxCount; ) {
            uint256 tokenId = escrowedTokens[left - 1 - i];
            feeDai += (NFT.getPrice(tokenId) * TRANSFER_FEE_PCT) / PCT_DENOMINATOR;
            unchecked { ++i; }
        }
    }

    function escrowedTokensLength() external view returns (uint256) {
        return escrowedTokens.length;
    }
}
