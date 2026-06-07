// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IStepCoin is IERC20 {
    function burn(uint256 amount) external;
}

interface IStepDex {
    function buyStep(uint256 daiAmount, uint256 minStepOut) external;
    // slippage-protection accounting
    function estimateBuy(uint256 daiAmount) external view returns (uint256);
}

interface IStepRegistry {
    function get(bytes32 key) external view returns (address);
    function KEY_STEP_COIN()     external view returns (bytes32);
    function KEY_STEP_DEX()      external view returns (bytes32);
    function KEY_STEP_NET()      external view returns (bytes32);
    function KEY_CLUB_TREASURY() external view returns (bytes32);
    function hasAcceptedCurrentTerms(address user) external view returns (bool);
}

interface IStepClub {
    function notifyStepClubDeposit(uint256 amount) external;
}

/**
 * @title  StepNFTTreasury
 * @notice Limited-supply ERC-721 collection (1,000 tokens) granting
 *         auxiliary utility within the Step Ecosystem. Two segments:
 *           • IDs 1..300   — reserved swap pool (legacy holders only).
 *           • IDs 301..1000 — public buy pool, priced on a stepped curve.
 *
 *         Subscription proceeds from StepNet feed a STEP reward pool that
 *         is periodically distributed pro-rata to every active NFT holder.
 *         Distribution is a resumable, batched routine designed to never
 *         freeze regardless of holder count.
 *
 *         Every user-facing entry point (buy, buyMultiple, swap variants,
 *         transfers) requires the caller to have acknowledged the
 *         registry's current Terms-of-Service hash.
 */
contract StepNFTTreasury is ERC721Enumerable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── ERRORS ──────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error NotAuthorized();
    error ZeroAmount();
    error SoldOut();
    error InvalidQuantity();
    error NotEnoughLeft();
    error TooEarly();
    error NoRewards();
    error NoNFTs();
    error NotStepNet();
    error ReservedAlreadyMinted();
    error NothingToClaim();
    error PriceExceedsMax();
    error OldNFTNotSet();
    error OldNFTAlreadySet();
    error NotOldNFTOwner();
    error AlreadySwapped();
    error DistributionInProgress();
    error NothingToDistribute();
    error TokenMintedAfterSnapshot();
    error NotSwappableTier();
    error SwapPoolFull();
    error TermsNotAccepted();

    // ─── CONSTANTS ───────────────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY          = 1000;
    uint256 public constant SWAP_END_ID           = 300;
    uint256 public constant MAX_SWAPPABLE_TIER_ID = 300;
    uint256 public constant MAX_BATCH_SWAP        = 50;

    uint256 public constant DISTRIBUTION_INTERVAL = 24 hours;
    uint256 public constant CLAIM_DEADLINE        = 30 days;
    uint256 public constant DIST_BATCH_SIZE       = 500;

    uint256 private constant PRECISION            = 1e18;
    uint256 private constant PERCENT_90           = 90;
    uint256 private constant PERCENT_10           = 10;
    uint256 private constant PERCENT_DENOMINATOR  = 100;

    uint256 private constant TRANSFER_FEE_PCT    = 10;
    uint256 private constant FEE_TO_TREASURY_PCT = 70;
    uint256 private constant FEE_TO_CLUB_PCT     = 30;

    /// @dev Slippage floor for every AMM-routed STEP purchase: at least
    ///      95 % of the simulated output must materialise, otherwise the
    ///      transaction reverts (anti-sandwich).
    uint256 private constant MIN_STEP_BPS     = 9500;
    uint256 private constant BPS_DENOMINATOR  = 10000;

    // ─── IMMUTABLES ──────────────────────────────────────────────────────────────
    IStepRegistry public immutable REGISTRY;
    IERC20 public immutable DAI;
    address public immutable wallet90;
    address public immutable wallet10;

    // ─── OLD-CONTRACT LINK ───────────────────────────────────────────────────────
    IERC721 public oldNFTContract;
    bool public oldNFTContractSet;
    mapping(uint256 => bool) public oldTokenSwapped;
    uint256 public maxSwappableOldTokenId;

    // ─── ID COUNTERS ─────────────────────────────────────────────────────────────
    uint256 public nextSwapId;
    uint256 public nextBuyId;

    string private _baseTokenURI;
    uint256 public lastDistributionTime;

    // ─── REWARDS ─────────────────────────────────────────────────────────────────
    uint256 public nftRewardPool;
    uint256 public totalPendingRewards;

    struct DistributionRecord {
        uint256 timestamp;
        uint256 stepPerNFT;
        uint256 totalSupplyAtDist;
    }
    DistributionRecord[] public distributions;

    mapping(uint256 => uint256) public mintedAtDistIndex;
    mapping(address => mapping(uint256 => uint256)) public userPendingRewards;
    mapping(address => uint256) public lastClaimedDistIndex;
    mapping(address => uint256) public lastClaimedTimestamp;
    mapping(address => uint256) public totalBurnedNFT;
    mapping(address => uint256) public totalClaimed;

    bool    public distInProgress;
    uint256 public distCursor;
    uint256 public distCurrentId;
    uint256 public distAmountPerNFT;
    uint256 public distTotalSupply;

    uint256 public oldestActivDistId;

    // ─── Expired-burn accumulators (round-scoped, persisted in storage) ────────
    // A distribution round can span multiple batched transactions, so the
    // running expired-burn tally lives in storage rather than local memory.
    uint256 public distExpiredBurnAccum;    // total expired STEP burned this round
    uint256 public distExpiredHolderAccum;  // count of holders that expired this round
    bool    public distHasExpiredInRound;   // whether any holder expired in this round
    uint256 public distExpiredDistId;       // distribution id currently expiring
    // ────────────────────────────────────────────────────────────────────────────

    // ─── EVENTS ──────────────────────────────────────────────────────────────────
    event Bought(address indexed buyer, uint256 indexed tokenId, uint256 priceDAI);
    event StepDistributed(uint256 amount90, uint256 amount10);
    event RewardsDeposited(uint256 amount, address indexed from);
    event RewardsDistributed(uint256 indexed distId, uint256 amount, uint256 stepPerNFT);
    event RewardClaimed(address indexed user, uint256 amount);
    event BaseURIUpdated(string newURI);
    event NFTSwapped(address indexed user, uint256 oldTokenId, uint256 newTokenId);
    event BatchNFTSwapped(address indexed user, uint256 count, uint256 firstNewId, uint256 lastNewId);
    event OldNFTContractSet(address indexed oldContract, uint256 maxSwappableTokenId);
    event TransferFeeCollected(address indexed from, uint256 tokenId, uint256 daiFee, uint256 stepMinted);
    event TokensBurned(address indexed user, uint256 amount);
    event DistributionBatchProcessed(uint256 indexed distId, uint256 from, uint256 to);
    event ExpiredRewardsBurned(uint256 indexed distId, uint256 totalBurned, uint256 holderCount);

    // ─── CONSTRUCTOR ─────────────────────────────────────────────────────────────
    constructor(
        address _registry,
        address _dai,
        address _wallet90,
        address _wallet10
    )
        ERC721("Step NFT 2025", "STEPNFT25")
        Ownable(msg.sender)
    {
        if (_registry == address(0) || _dai == address(0)) revert ZeroAddress();
        if (_wallet90 == address(0) || _wallet10 == address(0)) revert ZeroAddress();
        REGISTRY             = IStepRegistry(_registry);
        DAI                  = IERC20(_dai);
        wallet90             = _wallet90;
        wallet10             = _wallet10;
        // `lastDistributionTime` is intentionally left at zero so the
        // first successful `distributeRewards` call may run at any time
        // post-deployment; that call sets the timer going forward.
        nextSwapId = 1;
        nextBuyId  = SWAP_END_ID + 1;
    }

    // ─── INTERNAL HELPERS ────────────────────────────────────────────────────────
    function _step()    internal view returns (IStepCoin) { return IStepCoin(REGISTRY.get(REGISTRY.KEY_STEP_COIN())); }
    function _dex()     internal view returns (IStepDex)  { return IStepDex(REGISTRY.get(REGISTRY.KEY_STEP_DEX())); }
    function _stepNet() internal view returns (address)   { return REGISTRY.get(REGISTRY.KEY_STEP_NET()); }
    function _club()    internal view returns (address)   { return REGISTRY.get(REGISTRY.KEY_CLUB_TREASURY()); }

    /// @notice Caller must have on-chain accepted the registry's current
    ///         Terms-of-Service hash before any value-bearing entry point.
    modifier requireTermsAccepted() {
        if (!REGISTRY.hasAcceptedCurrentTerms(msg.sender)) revert TermsNotAccepted();
        _;
    }

    /// @dev Returns 95 % of the DEX's simulated STEP output for `daiAmount`.
    ///      Falls through to zero (no slippage floor) if the DEX rejects
    ///      the call, preserving forward compatibility.
    function _calcMinStepOut(uint256 daiAmount, IStepDex dex) internal view returns (uint256) {
        if (daiAmount == 0) return 0;
        try dex.estimateBuy(daiAmount) returns (uint256 expected) {
            if (expected == 0) return 0;
            return (expected * MIN_STEP_BPS) / BPS_DENOMINATOR;
        } catch {
            return 0;
        }
    }

    // ─── ADMIN (owner-only — NO platform fee) ────────────────────────────────────
    function setBaseURI(string calldata newURI) external onlyOwner {
        _baseTokenURI = newURI;
        emit BaseURIUpdated(newURI);
    }

    function renounceOwnership() public onlyOwner override {
        _transferOwnership(address(0));
    }

    function setOldNFTContract(address _oldNFT, uint256 _maxOldTokenId) external onlyOwner {
        if (oldNFTContractSet) revert OldNFTAlreadySet();
        if (_oldNFT == address(0)) revert ZeroAddress();
        if (_maxOldTokenId == 0) revert ZeroAmount();

        oldNFTContract         = IERC721(_oldNFT);
        maxSwappableOldTokenId = _maxOldTokenId;
        oldNFTContractSet      = true;
        emit OldNFTContractSet(_oldNFT, _maxOldTokenId);
    }

    // ─── SWAP HELPERS ────────────────────────────────────────────────────────────
    function _consumeSwap(uint256 oldTokenId) internal returns (uint256 newTokenId) {
        if (oldTokenId > MAX_SWAPPABLE_TIER_ID)        revert NotSwappableTier();
        if (oldTokenId > maxSwappableOldTokenId)       revert TokenMintedAfterSnapshot();
        if (oldTokenSwapped[oldTokenId])               revert AlreadySwapped();
        if (oldNFTContract.ownerOf(oldTokenId) != msg.sender) revert NotOldNFTOwner();

        oldTokenSwapped[oldTokenId] = true;
        oldNFTContract.transferFrom(msg.sender, address(this), oldTokenId);

        newTokenId = nextSwapId;
        unchecked { ++nextSwapId; }
    }

    // ─── USER-FACING WRITE FUNCTIONS (platform fee applies) ──────────────────────

    /// @notice Swap a single old NFT for a new one.
    function swapNFT(uint256 oldTokenId) external requireTermsAccepted nonReentrant {
        if (!oldNFTContractSet)            revert OldNFTNotSet();
        if (nextSwapId > SWAP_END_ID)      revert SwapPoolFull();

        uint256 newTokenId = _consumeSwap(oldTokenId);

        mintedAtDistIndex[newTokenId] = distributions.length;
        _safeMint(msg.sender, newTokenId);

        emit NFTSwapped(msg.sender, oldTokenId, newTokenId);
    }

    /// @notice Batch swap old NFTs.
    function swapNFTBatch(uint256[] calldata oldTokenIds) external requireTermsAccepted nonReentrant {
        if (!oldNFTContractSet) revert OldNFTNotSet();

        uint256 n = oldTokenIds.length;
        if (n == 0 || n > MAX_BATCH_SWAP)              revert InvalidQuantity();
        if (nextSwapId + n - 1 > SWAP_END_ID)          revert SwapPoolFull();

        uint256 firstNewId = nextSwapId;
        uint256 distLen    = distributions.length;

        for (uint256 i = 0; i < n; ) {
            uint256 oldId = oldTokenIds[i];
            uint256 newId = _consumeSwap(oldId);

            mintedAtDistIndex[newId] = distLen;
            _safeMint(msg.sender, newId);

            emit NFTSwapped(msg.sender, oldId, newId);
            unchecked { ++i; }
        }

        emit BatchNFTSwapped(msg.sender, n, firstNewId, nextSwapId - 1);
    }

    // ─── REWARD POOL ─────────────────────────────────────────────────────────────

    /// @notice Called by StepNet — NO platform fee (system call).
    function addToRewardPool(uint256 amount) external {
        if (msg.sender != _stepNet()) revert NotStepNet();
        if (amount == 0) revert ZeroAmount();

        IERC20 stepToken = IERC20(address(_step()));
        uint256 balBefore = stepToken.balanceOf(address(this));
        stepToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stepToken.balanceOf(address(this)) - balBefore;

        nftRewardPool += received;
        emit RewardsDeposited(received, msg.sender);
    }

    /// @notice User donation to reward pool. (no platform fee)
    function donateToRewardPool(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20 stepToken = IERC20(address(_step()));
        uint256 balBefore = stepToken.balanceOf(address(this));
        stepToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stepToken.balanceOf(address(this)) - balBefore;

        nftRewardPool += received;
        emit RewardsDeposited(received, msg.sender);
    }

    /// @notice Trigger reward distribution (keeper / any user). (no platform fee)
    function distributeRewards() external nonReentrant {
        uint256 supply = totalSupply();

        if (!distInProgress) {
            if (block.timestamp < lastDistributionTime + DISTRIBUTION_INTERVAL) revert TooEarly();
            if (nftRewardPool == 0) revert NoRewards();
            if (supply == 0) revert NoNFTs();

            uint256 totalStep    = nftRewardPool;
            nftRewardPool        = 0;
            lastDistributionTime = block.timestamp;

            uint256 newAmountPerNFT = totalStep / supply;
            uint256 remainder    = totalStep - (newAmountPerNFT * supply);
            if (remainder > 0) nftRewardPool = remainder;

            uint256 newDistId = distributions.length;
            distributions.push(DistributionRecord({
                timestamp:         block.timestamp,
                stepPerNFT:        newAmountPerNFT,
                totalSupplyAtDist: supply
            }));

            emit RewardsDistributed(newDistId, totalStep, newAmountPerNFT);

            totalPendingRewards += newAmountPerNFT * supply;

            distInProgress   = true;
            distCursor       = 0;
            distCurrentId    = newDistId;
            distAmountPerNFT = newAmountPerNFT;
            distTotalSupply  = supply;

            // Each new round starts with a clean slate: zero the accumulators so
            // one round's expiry data can never bleed into the next.
            distExpiredBurnAccum   = 0;
            distExpiredHolderAccum = 0;
            distHasExpiredInRound  = false;
            distExpiredDistId      = 0;
        }

        uint256 from = distCursor;
        uint256 to   = from + DIST_BATCH_SIZE;
        if (to > distTotalSupply) to = distTotalSupply;

        uint256 amountPerNFT = distAmountPerNFT;
        uint256 distId       = distCurrentId;

        // Expiry state is read from storage (not locals) so every batch in the
        // round shares one consistent view: once any batch detects an expiry,
        // all subsequent batches act on it too.
        bool    hasExpired    = distHasExpiredInRound;
        uint256 expiredDistId = distExpiredDistId;

        // If no expiry has been found yet this round, check for one now.
        if (!hasExpired) {
            uint256 oldest = oldestActivDistId;
            if (oldest < distId) {
                DistributionRecord memory oldDist = distributions[oldest];
                if (block.timestamp >= oldDist.timestamp + CLAIM_DEADLINE) {
                    hasExpired             = true;
                    expiredDistId          = oldest;
                    distHasExpiredInRound  = true;   // persist in storage
                    distExpiredDistId      = oldest;  // persist in storage
                }
            }
        }

        for (uint256 i = from; i < to; ) {
            uint256 tokenId = tokenByIndex(i);
            address owner_  = ownerOf(tokenId);

            userPendingRewards[owner_][distId] += amountPerNFT;

            if (hasExpired) {
                uint256 expiredAmt = userPendingRewards[owner_][expiredDistId];
                if (expiredAmt > 0) {
                    userPendingRewards[owner_][expiredDistId] = 0;
                    totalBurnedNFT[owner_] += expiredAmt;
                    // Accumulate in storage so the running total stays correct
                    // across every batch of a multi-batch distribution.
                    distExpiredBurnAccum           += expiredAmt;
                    unchecked { distExpiredHolderAccum++; }
                }
            }

            unchecked { ++i; }
        }

        distCursor = to;
        emit DistributionBatchProcessed(distId, from, to);

        if (to >= distTotalSupply) {
            distInProgress   = false;
            distCursor       = 0;
            distCurrentId    = 0;
            distAmountPerNFT = 0;
            distTotalSupply  = 0;

            // Burn against the round-wide accumulator (the sum across all
            // batches), giving the complete expired total for the round.
            if (distHasExpiredInRound && distExpiredBurnAccum > 0) {
                totalPendingRewards -= distExpiredBurnAccum;
                _step().burn(distExpiredBurnAccum);
                emit ExpiredRewardsBurned(distExpiredDistId, distExpiredBurnAccum, distExpiredHolderAccum);
            }
            if (distHasExpiredInRound) {
                unchecked { oldestActivDistId = distExpiredDistId + 1; }
            }
            // The accumulators are zeroed when the next round starts.
        }
    }

    /**
     * @notice Claim accrued STEP rewards.
     * @dev    Iteration starts at `max(lastClaimedDistIndex,
     *         oldestActivDistId)` so the walk is always bounded by the
     *         current claim window (≈ 3 active distributions), regardless
     *         of how long the user has been inactive.
     */
    function claimRewards() external nonReentrant {
        uint256 len   = distributions.length;
        uint256 oldest = oldestActivDistId;
        uint256 start = lastClaimedDistIndex[msg.sender];

        // Skip up to oldestActivDistId; entries before it have already
        // been burned and are guaranteed zero.
        if (start < oldest) start = oldest;

        if (start >= len) revert NothingToClaim();

        uint256 totalOwed    = 0;
        uint256 totalToBurn  = 0;
        uint256 latestTs     = lastClaimedTimestamp[msg.sender];

        for (uint256 d = start; d < len; ) {
            DistributionRecord memory dist = distributions[d];

            if (dist.timestamp <= lastClaimedTimestamp[msg.sender]) {
                unchecked { ++d; }
                continue;
            }

            uint256 r = userPendingRewards[msg.sender][d];
            if (r > 0) {
                userPendingRewards[msg.sender][d] = 0;

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

        lastClaimedDistIndex[msg.sender]  = len;
        lastClaimedTimestamp[msg.sender]  = latestTs;
        totalPendingRewards              -= (totalOwed + totalToBurn);

        if (totalToBurn > 0) {
            _step().burn(totalToBurn);
            totalBurnedNFT[msg.sender] += totalToBurn;
            emit TokensBurned(msg.sender, totalToBurn);
        }

        if (totalOwed > 0) {
            totalClaimed[msg.sender] += totalOwed;
            IERC20(address(_step())).safeTransfer(msg.sender, totalOwed);
            emit RewardClaimed(msg.sender, totalOwed);
        }
    }

    // ─── BUY ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Buy a single NFT from the public pool at the curve-determined
     *         price. `maxPrice` is an upper bound the caller is willing to
     *         pay (frontends should set it from the latest `getCurrentPrice`
     *         + tolerance).
     */
    function buy(uint256 maxPrice) external requireTermsAccepted nonReentrant {
        if (nextBuyId > TOTAL_SUPPLY)   revert SoldOut();

        uint256 tokenId = nextBuyId;
        uint256 price   = getPrice(tokenId);

        if (maxPrice > 0 && price > maxPrice) revert PriceExceedsMax();

        unchecked { ++nextBuyId; }

        DAI.safeTransferFrom(msg.sender, address(this), price);

        IStepCoin step = _step();
        IStepDex  dex  = _dex();
        // Slippage-protected AMM purchase.
        uint256 minOut = _calcMinStepOut(price, dex);
        DAI.forceApprove(address(dex), price);

        uint256 stepBefore = IERC20(address(step)).balanceOf(address(this));
        dex.buyStep(price, minOut);
        uint256 stepMinted = IERC20(address(step)).balanceOf(address(this)) - stepBefore;

        if (stepMinted > 0) {
            uint256 to90 = (stepMinted * PERCENT_90) / PERCENT_DENOMINATOR;
            uint256 to10 = stepMinted - to90;
            if (to90 > 0) IERC20(address(step)).safeTransfer(wallet90, to90);
            if (to10 > 0) IERC20(address(step)).safeTransfer(wallet10, to10);
            emit StepDistributed(to90, to10);
        }

        mintedAtDistIndex[tokenId] = distributions.length;
        _safeMint(msg.sender, tokenId);

        emit Bought(msg.sender, tokenId, price);
    }

    /**
     * @notice Buy a small batch of NFTs in a single call. Maximum batch
     *         size is 10. `maxTotalPrice` is the aggregate upper bound.
     */
    function buyMultiple(uint256 quantity, uint256 maxTotalPrice) external requireTermsAccepted nonReentrant {
        if (quantity == 0 || quantity > 10)                  revert InvalidQuantity();
        if (nextBuyId + quantity - 1 > TOTAL_SUPPLY)         revert NotEnoughLeft();

        uint256 totalPrice = 0;
        for (uint256 i = 0; i < quantity; ++i) {
            totalPrice += getPrice(nextBuyId + i);
        }
        if (maxTotalPrice > 0 && totalPrice > maxTotalPrice) revert PriceExceedsMax();

        DAI.safeTransferFrom(msg.sender, address(this), totalPrice);

        IStepCoin step = _step();
        IStepDex  dex  = _dex();
        DAI.forceApprove(address(dex), totalPrice);

        for (uint256 i = 0; i < quantity; ++i) {
            uint256 tokenId = nextBuyId;
            uint256 price   = getPrice(tokenId);
            unchecked { ++nextBuyId; }

            // Slippage protection re-evaluated per iteration: each prior
            // buy moves the AMM price, so the safe minOut shifts too.
            uint256 minOutIter = _calcMinStepOut(price, dex);
            uint256 stepBefore = IERC20(address(step)).balanceOf(address(this));
            dex.buyStep(price, minOutIter);
            uint256 stepMinted = IERC20(address(step)).balanceOf(address(this)) - stepBefore;

            if (stepMinted > 0) {
                uint256 to90 = (stepMinted * PERCENT_90) / PERCENT_DENOMINATOR;
                uint256 to10 = stepMinted - to90;
                if (to90 > 0) IERC20(address(step)).safeTransfer(wallet90, to90);
                if (to10 > 0) IERC20(address(step)).safeTransfer(wallet10, to10);
                emit StepDistributed(to90, to10);
            }

            mintedAtDistIndex[tokenId] = distributions.length;
            _safeMint(msg.sender, tokenId);
            emit Bought(msg.sender, tokenId, price);
        }
    }

    // ─── PRICING ─────────────────────────────────────────────────────────────────
    function getPrice(uint256 id) public pure returns (uint256) {
        if (id <= 200) return 100e18;
        if (id <= 300) return 200e18;
        if (id <= 400) return 400e18;
        if (id <= 500) return 800e18;
        if (id <= 600) return 1600e18;
        if (id <= 700) return 3200e18;
        if (id <= 800) return 6400e18;
        if (id <= 900) return 12800e18;
        return 25600e18;
    }

    function getCurrentPrice() external view returns (uint256) {
        if (nextBuyId > TOTAL_SUPPLY) return 0;
        return getPrice(nextBuyId);
    }

    // ─── TRANSFER FEE (DAI-based — separate from BNB platform fee) ───────────────
    function _collectTransferFee(address from, uint256 tokenId) internal {
        uint256 nftMintPrice = getPrice(tokenId);
        uint256 daiFee       = (nftMintPrice * TRANSFER_FEE_PCT) / PERCENT_DENOMINATOR;
        if (daiFee == 0) return;

        DAI.safeTransferFrom(from, address(this), daiFee);

        IStepCoin step = _step();
        IStepDex  dex  = _dex();

        // Slippage-protected transfer-fee swap.
        uint256 minOutFee = _calcMinStepOut(daiFee, dex);
        DAI.forceApprove(address(dex), daiFee);
        uint256 stepBefore = IERC20(address(step)).balanceOf(address(this));
        dex.buyStep(daiFee, minOutFee);
        uint256 stepMinted = IERC20(address(step)).balanceOf(address(this)) - stepBefore;

        emit TransferFeeCollected(from, tokenId, daiFee, stepMinted);

        if (stepMinted == 0) return;

        uint256 toClub     = (stepMinted * FEE_TO_CLUB_PCT)     / PERCENT_DENOMINATOR;
        uint256 toTreasury = stepMinted - toClub;

        if (toTreasury > 0) {
            nftRewardPool += toTreasury;
            emit RewardsDeposited(toTreasury, address(this));
        }

        if (toClub > 0) {
            address clubAddr = _club();
            IERC20(address(step)).safeTransfer(clubAddr, toClub);
            IStepClub(clubAddr).notifyStepClubDeposit(toClub);
        }
    }

    // Transfers attract a tokenomic transfer levy denominated in DAI; it is
    // collected and split between the reward pool and the Club at every
    // peer-to-peer move (see `_collectTransferFee`). The levy is hooked on
    // `_update` — the single chokepoint every ERC-721 movement routes through —
    // so it is charged exactly once regardless of which transfer entry point
    // (`transferFrom` or either `safeTransferFrom`) the caller uses. Mints
    // (from == address(0)) and burns (to == address(0)) are exempt.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Enumerable)
        returns (address from)
    {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) {
            _collectTransferFee(from, tokenId);
        }
    }

    // ─── VIEW HELPERS ────────────────────────────────────────────────────────────
    function nextId() external view returns (uint256) {
        return nextBuyId;
    }

    function swapPoolInfo() external view returns (
        uint256 nextSwapTokenId,
        uint256 swapPoolEndId,
        uint256 swapsRemaining,
        uint256 maxSwappableOldId
    ) {
        nextSwapTokenId   = nextSwapId;
        swapPoolEndId     = SWAP_END_ID;
        swapsRemaining    = nextSwapId > SWAP_END_ID ? 0 : (SWAP_END_ID + 1 - nextSwapId);
        maxSwappableOldId = maxSwappableOldTokenId;
    }

    function getDistributions(uint256 start, uint256 limit) external view returns (
        uint256[] memory ids,
        uint256[] memory timestamps,
        uint256[] memory stepPerNFT,
        bool[]    memory expired,
        uint256[] memory timeLeft
    ) {
        uint256 distLength = distributions.length;
        if (start >= distLength) {
            return (
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new bool[](0),
                new uint256[](0)
            );
        }

        uint256 len = (start + limit > distLength) ? distLength - start : limit;

        ids        = new uint256[](len);
        timestamps = new uint256[](len);
        stepPerNFT = new uint256[](len);
        expired    = new bool[](len);
        timeLeft   = new uint256[](len);

        for (uint256 i = 0; i < len; ) {
            DistributionRecord memory d = distributions[start + i];
            ids[i]        = start + i;
            timestamps[i] = d.timestamp;
            stepPerNFT[i] = d.stepPerNFT;

            uint256 deadline  = d.timestamp + CLAIM_DEADLINE;
            bool    isExpired = block.timestamp >= deadline;
            expired[i]  = isExpired;
            timeLeft[i] = isExpired ? 0 : deadline - block.timestamp;
            unchecked { ++i; }
        }
    }

    function getRewardInfo(address user) external view returns (
        uint256 pendingClaimable,
        uint256 pendingExpired,
        uint256 totalClaimedAmount,
        uint256 timeUntilClaimDeadline,
        uint256 rewardPoolBalance,
        bool    claimWindowExpired
    ) {
        uint256 start = lastClaimedDistIndex[user];
        if (start < oldestActivDistId) start = oldestActivDistId;
        for (uint256 d = start; d < distributions.length; ++d) {
            DistributionRecord memory dist = distributions[d];
            if (dist.timestamp <= lastClaimedTimestamp[user]) continue;
            uint256 r = userPendingRewards[user][d];
            if (r == 0) continue;
            if (block.timestamp >= dist.timestamp + CLAIM_DEADLINE) {
                pendingExpired += r;
            } else {
                pendingClaimable += r;
            }
        }
        totalClaimedAmount = totalClaimed[user];
        claimWindowExpired = false;

        if (distributions.length > 0) {
            DistributionRecord memory last = distributions[distributions.length - 1];
            uint256 deadline = last.timestamp + CLAIM_DEADLINE;
            if (block.timestamp >= deadline) {
                claimWindowExpired = true;
            } else {
                timeUntilClaimDeadline = deadline - block.timestamp;
            }
        }

        rewardPoolBalance = nftRewardPool + totalPendingRewards;
    }

    function getTimeUntilNextDistribution() external view returns (uint256) {
        uint256 next = lastDistributionTime + DISTRIBUTION_INTERVAL;
        return block.timestamp >= next ? 0 : next - block.timestamp;
    }

    /// @dev Bounded by `oldestActivDistId` so the walk never crosses the
    ///      expired-burn boundary.
    function pendingOf(address user) external view returns (uint256) {
        uint256 pending = 0;
        uint256 start = lastClaimedDistIndex[user];
        if (start < oldestActivDistId) start = oldestActivDistId;
        for (uint256 d = start; d < distributions.length; ++d) {
            DistributionRecord memory dist = distributions[d];
            if (dist.timestamp <= lastClaimedTimestamp[user]) continue;
            if (block.timestamp < dist.timestamp + CLAIM_DEADLINE) {
                pending += userPendingRewards[user][d];
            }
        }
        return pending;
    }

    function pendingOfPaginated(address user, uint256 maxDists) external view returns (
        uint256 pending,
        bool    hasMore
    ) {
        uint256 start = lastClaimedDistIndex[user];
        if (start < oldestActivDistId) start = oldestActivDistId;
        uint256 total = distributions.length;
        uint256 end   = (maxDists == 0 || start + maxDists >= total) ? total : start + maxDists;
        for (uint256 d = start; d < end; ++d) {
            pending += userPendingRewards[user][d];
        }
        hasMore = end < total;
    }

    function totalClaimedOf(address user) external view returns (uint256) { return totalClaimed[user]; }
    function totalBurnedOf (address user) external view returns (uint256) { return totalBurnedNFT[user]; }
    function getRewardPool ()             external view returns (uint256) { return nftRewardPool; }
    function getCurrentStepBalance()      external view returns (uint256) { return IERC20(address(_step())).balanceOf(address(this)); }

    function getDistributionStatus() external view returns (
        bool   inProgress,
        uint256 cursor,
        uint256 total,
        uint256 currentDistId,
        uint256 amountPerNFT
    ) {
        inProgress    = distInProgress;
        cursor        = distCursor;
        total         = distInProgress ? distTotalSupply : totalSupply();
        currentDistId = distCurrentId;
        amountPerNFT  = distAmountPerNFT;
    }

    function getUserDashboard(address user) external view returns (
        uint256 timeUntilNextDist,
        uint256 timeUntilClaimDeadline,
        bool    claimWindowExpired,
        uint256 pendingStep,
        uint256 totalClaimedStep,
        uint256 totalBurnedStep,
        uint256 rewardPoolBalance
    ) {
        uint256 nextDist = lastDistributionTime + DISTRIBUTION_INTERVAL;
        timeUntilNextDist = block.timestamp >= nextDist ? 0 : nextDist - block.timestamp;

        if (distributions.length > 0) {
            uint256 deadline = distributions[distributions.length - 1].timestamp + CLAIM_DEADLINE;
            if (block.timestamp >= deadline) {
                claimWindowExpired    = true;
                timeUntilClaimDeadline = 0;
            } else {
                claimWindowExpired    = false;
                timeUntilClaimDeadline = deadline - block.timestamp;
            }
        }

        {
            uint256 start = lastClaimedDistIndex[user];
            if (start < oldestActivDistId) start = oldestActivDistId;
            uint256 len   = distributions.length;
            for (uint256 d = start; d < len; ) {
                DistributionRecord memory dist = distributions[d];
                if (dist.timestamp > lastClaimedTimestamp[user]) {
                    if (block.timestamp < dist.timestamp + CLAIM_DEADLINE) {
                        pendingStep += userPendingRewards[user][d];
                    }
                }
                unchecked { ++d; }
            }
        }

        totalClaimedStep = totalClaimed[user];
        totalBurnedStep  = totalBurnedNFT[user];
        rewardPoolBalance = nftRewardPool + totalPendingRewards;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // ─── DAO-gated migration ───────────────────────────────────────────────
    event AssetsMigrated(address indexed to, uint256 daiAmount, uint256 stepAmount);

    /**
     * @notice Transfer the treasury's DAI + STEP balances to a successor
     *         contract. Only the registry may invoke this, and only after
     *         a passed migration proposal has cleared its veto window and
     *         timelock. NFT ownership is unaffected — holders keep their
     *         tokens regardless of which treasury is registry-current.
     */
    function migrateAssetsTo(address newContract) external {
        if (msg.sender != address(REGISTRY)) revert NotAuthorized();
        if (newContract == address(0)) revert ZeroAddress();
        uint256 daiBal  = DAI.balanceOf(address(this));
        IERC20 stepToken = IERC20(address(_step()));
        uint256 stepBal = stepToken.balanceOf(address(this));
        if (daiBal  > 0) DAI.safeTransfer(newContract, daiBal);
        if (stepBal > 0) stepToken.safeTransfer(newContract, stepBal);
        emit AssetsMigrated(newContract, daiBal, stepBal);
    }
}
