// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStepCoin is IERC20 {
    function mint(address to, uint256 amount) external;
    function burnFromDex(address from, uint256 amount) external;
}

interface IStepRegistry {
    function get(bytes32 key) external view returns (address);
    function KEY_STEP_COIN() external view returns (bytes32);
    function KEY_STEP_NET() external view returns (bytes32);
    function KEY_NFT_TREASURY() external view returns (bytes32);
    function KEY_CLUB_TREASURY() external view returns (bytes32);
    function hasAcceptedCurrentTerms(address user) external view returns (bool);
}

interface IStepClub {
    function notifyStepClubDeposit(uint256 amount) external;
}

/**
 * @title  StepDex
 * @notice Single-asset bonding-curve AMM that backs the STEP utility token
 *         with a DAI reserve. Every STEP minted into circulation is
 *         exchanged at this contract for an equivalent reserve in DAI, and
 *         every STEP burned via `sellStep` releases its DAI share.
 *
 *         Design properties:
 *           • Price is a pure function of `daiReserve / totalSupply`;
 *             no oracle dependency, no admin price control.
 *           • Buy split: 96 % to the buyer, 2 % to the Club pool (loyalty
 *             rewards), and the remaining 2 % is the price-impact buffer.
 *           • Sell split: 98 % to the seller; the residual 2 % stays in
 *             reserve, monotonically improving the floor for remaining
 *             holders.
 *           • A minimum price floor (`MIN_PRICE`) prevents division-by-zero
 *             during early-life states. Triggering the floor emits an
 *             on-chain event so off-chain monitoring can alert immediately.
 *           • System callers (StepNet, StepNFTTreasury) bypass slippage
 *             defaults; user-facing calls (buyStepPublic, sellStep, sellAll)
 *             require the caller to accept the published Terms-of-Service.
 *           • DAO-gated asset migration with no privileged backdoor.
 */
contract StepDex is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStepCoin;

    error ZeroAddress();
    error NotAuthorized();
    error ZeroAmount();
    error NotSystemContract();
    error NotInitialized();
    error NoLiquidity();
    error InsufficientDAI();
    error SlippageExceeded();
    error TermsNotAccepted();

    uint256 private constant BUY_USER_PERCENT    = 96;
    uint256 private constant BUY_CLUB_PERCENT    = 2;
    uint256 private constant SELL_USER_PERCENT   = 98;
    uint256 private constant PERCENT_DENOMINATOR = 100;
    uint256 private constant PRECISION           = 1e18;

    uint256 private constant STEP_TRANSFER_FEE_PCT = 2;
    /// @dev Hard price floor (1e10 = 0.00000001 DAI per STEP). Used only
    ///      to keep the DEX live in edge states where reserve / supply
    ///      would otherwise round to zero; activation is emitted on-chain
    ///      via `PriceFloorActivated` so monitoring can flag it.
    uint256 private constant MIN_PRICE = 1e10;

    IStepRegistry public immutable REGISTRY;
    IERC20        public immutable DAI;

    uint256 public daiReserve;

    event Buy(address indexed buyer, uint256 daiIn, uint256 stepToUser, uint256 stepToClub);
    event Sell(address indexed seller, uint256 stepIn, uint256 daiOut);
    event LiquidityDonated(address indexed donor, uint256 daiAmount);
    event StepDonatedAndBurned(address indexed donor, uint256 stepRequested, uint256 stepActuallyBurned);
    /// @notice Emitted when the spot price would round to zero and the
    ///         hard floor (MIN_PRICE) is used instead. A non-zero rate of
    ///         this event in production is a strong signal that off-chain
    ///         monitors should pause user-facing trade flow until the
    ///         reserve is refilled or a migration is executed.
    event PriceFloorActivated(uint256 daiReserve, uint256 stepSupply, uint256 flooredPrice);

    constructor(address _registry, address _dai)
    {
        if (_registry == address(0) || _dai == address(0)) revert ZeroAddress();
        REGISTRY = IStepRegistry(_registry);
        DAI      = IERC20(_dai);
    }

    function _step() internal view returns (IStepCoin) {
        return IStepCoin(REGISTRY.get(REGISTRY.KEY_STEP_COIN()));
    }

    function _clubTreasury() internal view returns (address) {
        return REGISTRY.get(REGISTRY.KEY_CLUB_TREASURY());
    }

    // ─── System-only modifier (StepNet / StepNFTTreasury calls) ──────────────────
    modifier onlySystemContract() {
        address net = REGISTRY.get(REGISTRY.KEY_STEP_NET());
        address nft = REGISTRY.get(REGISTRY.KEY_NFT_TREASURY());
        if (msg.sender != net && msg.sender != nft) revert NotSystemContract();
        _;
    }

    /// @notice Caller must have on-chain acknowledged the registry's current
    ///         Terms-of-Service hash. Applied to direct user trades only —
    ///         system contracts (StepNet, NFT treasury) bypass via the
    ///         `onlySystemContract` path because their callers (the user)
    ///         have already been gated upstream.
    modifier requireTermsAccepted() {
        if (!REGISTRY.hasAcceptedCurrentTerms(msg.sender)) revert TermsNotAccepted();
        _;
    }

    // ─── VIEW ──────────────────────────────────────────────────────────────
    /**
     * @notice Spot STEP price in DAI (PRECISION = 1e18).
     * @dev    Never returns zero. When `daiReserve / totalSupply` rounds to
     *         zero, the floor (MIN_PRICE) is returned so user-facing flows
     *         do not lock; off-chain monitoring is notified via
     *         `PriceFloorActivated` (emitted inside `_getPriceAndDetectFloor`
     *         on actual state-changing trades).
     */
    function getPrice() public view returns (uint256 price) {
        IStepCoin step = _step();
        if (address(step) == address(0)) revert NotInitialized();
        uint256 stepSupply = step.totalSupply();
        if (stepSupply == 0) return 1e10;
        price = (daiReserve * PRECISION) / stepSupply;
        if (price == 0) price = MIN_PRICE;
    }

    // ─── System entry points (called by other system contracts) ────────────

    /// @notice System-only AMM buy. Used by StepNet and StepNFTTreasury to
    ///         convert DAI from subscription / NFT sales into STEP for the
    ///         protocol-managed splits.
    function buyStep(uint256 daiAmount, uint256 minStepOut) external nonReentrant onlySystemContract {
        _executeBuy(msg.sender, daiAmount, minStepOut);
    }

    /// @notice Donate DAI directly into the AMM reserve. Used internally by
    ///         StepNet when burning expired upgrade reserves; also callable
    ///         by any address to permanently improve the price floor.
    function donateLiquidity(uint256 daiAmount) external nonReentrant {
        if (daiAmount == 0) revert ZeroAmount();
        DAI.safeTransferFrom(msg.sender, address(this), daiAmount);
        daiReserve += daiAmount;
        emit LiquidityDonated(msg.sender, daiAmount);
    }

    // ─── DAO-gated migration ───────────────────────────────────────────────
    event AssetsMigrated(address indexed to, uint256 daiAmount, uint256 stepAmount);

    /**
     * @notice Move the AMM's entire DAI + STEP reserve to a successor
     *         contract. Only the registry may invoke this, and only after
     *         a passed migration proposal has cleared its veto window and
     *         timelock. No deployer-only backdoor exists.
     */
    function migrateAssetsTo(address newContract) external {
        if (msg.sender != address(REGISTRY)) revert NotAuthorized();
        if (newContract == address(0)) revert ZeroAddress();

        uint256 daiBal  = DAI.balanceOf(address(this));
        uint256 stepBal = _step().balanceOf(address(this));

        if (daiBal  > 0) DAI.safeTransfer(newContract, daiBal);
        if (stepBal > 0) IERC20(address(_step())).safeTransfer(newContract, stepBal);

        daiReserve = 0;
        emit AssetsMigrated(newContract, daiBal, stepBal);
    }

    // ─── User-facing entry points ──────────────────────────────────────────

    /// @notice Public buy — any user can call.
    function buyStepPublic(uint256 daiAmount, uint256 minStepOut) external requireTermsAccepted nonReentrant {
        _executeBuy(msg.sender, daiAmount, minStepOut);
    }

    /// @notice Sell STEP for DAI.
    function sellStep(uint256 stepAmount, uint256 minDaiOut) external requireTermsAccepted nonReentrant {
        if (stepAmount == 0) revert ZeroAmount();
        _executeSell(msg.sender, stepAmount, minDaiOut);
    }

    /// @notice Sell entire STEP balance.
    function sellAll(uint256 minDaiOut) external requireTermsAccepted nonReentrant {
        IStepCoin step       = _step();
        uint256   stepAmount = step.balanceOf(msg.sender);
        if (stepAmount == 0) revert ZeroAmount();
        _executeSell(msg.sender, stepAmount, minDaiOut);
    }

    /// @notice Donate STEP into this contract and burn it on-the-fly.
    ///         Useful for community-driven deflation events.
    function donateAndBurnStep(uint256 stepAmount) external nonReentrant {
        if (stepAmount == 0) revert ZeroAmount();
        IStepCoin step      = _step();
        uint256   balBefore = step.balanceOf(address(this));
        step.transferFrom(msg.sender, address(this), stepAmount);
        uint256   received  = step.balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();
        step.burnFromDex(address(this), received);
        emit StepDonatedAndBurned(msg.sender, stepAmount, received);
    }

    // ─── Internal ──────────────────────────────────────────────────────────

    /// @dev Same calculation as `getPrice` but emits `PriceFloorActivated`
    ///      from a state-mutating context whenever the floor is engaged.
    ///      Keeping the event out of the `view` getter avoids forcing
    ///      indexer-level inference of "did the floor just trigger".
    function _getPriceAndDetectFloor() internal returns (uint256 price) {
        IStepCoin step = _step();
        if (address(step) == address(0)) revert NotInitialized();
        uint256 stepSupply = step.totalSupply();
        if (stepSupply == 0) return MIN_PRICE;
        uint256 raw = (daiReserve * PRECISION) / stepSupply;
        if (raw == 0) {
            emit PriceFloorActivated(daiReserve, stepSupply, MIN_PRICE);
            return MIN_PRICE;
        }
        return raw;
    }

    function _executeBuy(address buyer, uint256 daiAmount, uint256 minStepOut) internal {
        if (daiAmount == 0) revert ZeroAmount();
        address club = _clubTreasury();
        if (club == address(0)) revert NotInitialized();

        uint256 price = _getPriceAndDetectFloor();
        if (price == 0) revert NoLiquidity();

        DAI.safeTransferFrom(buyer, address(this), daiAmount);
        daiReserve += daiAmount;

        uint256 stepRaw    = (daiAmount * PRECISION) / price;
        uint256 stepToUser = (stepRaw * BUY_USER_PERCENT) / PERCENT_DENOMINATOR;
        uint256 stepToClub = (stepRaw * BUY_CLUB_PERCENT) / PERCENT_DENOMINATOR;

        if (minStepOut > 0 && stepToUser < minStepOut) revert SlippageExceeded();

        IStepCoin step = _step();

        step.mint(buyer, stepToUser);

        if (stepToClub > 0) {
            step.mint(address(this), stepToClub);
            step.safeTransfer(club, stepToClub);
            IStepClub(club).notifyStepClubDeposit(stepToClub);
        }

        emit Buy(buyer, daiAmount, stepToUser, stepToClub);
    }

    function _executeSell(address seller, uint256 stepAmount, uint256 minDaiOut) internal {
        if (stepAmount == 0) revert ZeroAmount();

        uint256 price = _getPriceAndDetectFloor();
        if (price == 0) revert NoLiquidity();

        IStepCoin step = _step();

        uint256 balanceBefore = step.balanceOf(address(this));
        step.transferFrom(seller, address(this), stepAmount);
        uint256 received = step.balanceOf(address(this)) - balanceBefore;

        if (received == 0) revert ZeroAmount();

        uint256 fullValue = (received * price) / PRECISION;
        uint256 daiToUser = (fullValue * SELL_USER_PERCENT) / PERCENT_DENOMINATOR;

        if (daiReserve < daiToUser) revert InsufficientDAI();

        if (minDaiOut > 0 && daiToUser < minDaiOut) revert SlippageExceeded();

        step.burnFromDex(address(this), received);
        daiReserve -= daiToUser;
        DAI.safeTransfer(seller, daiToUser);

        emit Sell(seller, stepAmount, daiToUser);
    }

    // ─── View helpers ──────────────────────────────────────────────────────
    function getDaiBalance() external view returns (uint256) {
        return daiReserve;
    }

    function isInitialized() external view returns (bool) {
        return address(_step()) != address(0) && _clubTreasury() != address(0);
    }

    /// @notice Estimate DAI received for selling `stepAmount` STEP.
    ///         Accounts for the 2 % deflationary levy that applies when the
    ///         user transfers their STEP into this contract.
    function estimateSell(uint256 stepAmount) external view returns (uint256 daiOut) {
        uint256 price = getPrice();
        if (price == 0) return 0;
        uint256 effectiveStep = (stepAmount * (PERCENT_DENOMINATOR - STEP_TRANSFER_FEE_PCT)) / PERCENT_DENOMINATOR;
        daiOut = (effectiveStep * price * SELL_USER_PERCENT) / (PRECISION * PERCENT_DENOMINATOR);
    }

    /// @notice Estimate STEP received for spending `daiAmount` DAI.
    /// @dev    The 2 % token levy is intentionally not applied here: a buy
    ///         delivers STEP via `_mint` directly to the buyer, and mints
    ///         are levy-free by construction (see StepCoin._update). This
    ///         is a deliberate asymmetry with `estimateSell`.
    function estimateBuy(uint256 daiAmount) external view returns (uint256 stepOut) {
        uint256 price = getPrice();
        if (price == 0) return 0;
        stepOut = (daiAmount * PRECISION * BUY_USER_PERCENT) / (price * PERCENT_DENOMINATOR);
    }
}
