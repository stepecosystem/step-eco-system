// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IStepRegistry {
    function get(bytes32 key) external view returns (address);
    function KEY_STEP_DEX() external view returns (bytes32);
}

/**
 * @title  StepCoin (STEP)
 * @notice The native, DAI-backed utility token of the StepNet ecosystem.
 *         STEP is a dynamic-supply ERC-20 whose price is never an oracle
 *         guess but a fact — DAI reserve ÷ circulating supply — because every
 *         unit in circulation is matched by DAI held in the StepDex
 *         bonding-curve reserve. Its core properties:
 *           • Mint authority is restricted to the registry-current DEX —
 *             tokens enter circulation exclusively through the bonding
 *             curve AMM that backs each mint with a corresponding DAI
 *             reserve.
 *           • Burn authority is split between the holder (`burn`) and the
 *             DEX (`burnFromDex`), keeping supply faithfully tied to the
 *             underlying reserve.
 *           • A 2 % transfer levy is burned on every non-system transfer.
 *             Together with the bonding curve, this creates a continuously
 *             deflationary supply schedule.
 *           • A DAO-managed whitelist (capacity 2) exempts core protocol
 *             contracts from the levy so internal accounting stays exact.
 *         Migration of registry pointers requires a passed DAO proposal,
 *         a veto window, and a timelock; no privileged backdoor exists.
 */
contract StepCoin is ERC20 {

    // ─── Errors ────────────────────────────────────────────────────────────
    error NotDex();
    error ZeroAddress();
    error AlreadyMinted();
    error Unauthorized();
    error WhitelistFull();
    error NotWhitelisted();
    error AlreadyWhitelisted();

    // ─── Constants ─────────────────────────────────────────────────────────
    uint256 private constant INITIAL_SUPPLY  = 1_000_000 * 1e18;
    uint256 private constant FEE_PERCENT     = 2;
    uint256 private constant FEE_DENOMINATOR = 100;

    /// @notice Hard cap on the number of fee-exempt system addresses.
    uint256 public constant MAX_WHITELIST = 2;

    // ─── Immutables ────────────────────────────────────────────────────────
    IStepRegistry public immutable REGISTRY;

    /// @notice The sole address allowed to call `mintInitialSupply`.
    address public immutable originalDeployer;

    // ─── State ─────────────────────────────────────────────────────────────
    bool public initialSupplyMinted;

    /// @notice Addresses exempt from the 2 % transfer levy. Updated only
    ///         via passed DAO proposals.
    mapping(address => bool) public isWhitelisted;

    /// @notice Fixed-size enumerable mirror of the whitelist.
    address[MAX_WHITELIST] public whitelistedAddresses;

    /// @notice Number of slots currently occupied in the whitelist.
    uint256 public whitelistCount;

    // ─── Events ────────────────────────────────────────────────────────────────
    event TokensBurned(address indexed from, uint256 amount);
    event InitialSupplyMinted(address indexed dex, uint256 amount);
    event AddedToWhitelist(address indexed account);
    event RemovedFromWhitelist(address indexed account);

    // ─── Constructor ───────────────────────────────────────────────────────
    constructor(address registry_) ERC20("StepCoin", "STEP") {
        if (registry_ == address(0)) revert ZeroAddress();
        REGISTRY         = IStepRegistry(registry_);
        originalDeployer = msg.sender;
        // No address is whitelisted by default; the DAO seats the system
        // contracts via two passed proposals after initial deployment.
    }

    // ─── Internal helpers ──────────────────────────────────────────────────

    function _dex() internal view returns (address) {
        return REGISTRY.get(REGISTRY.KEY_STEP_DEX());
    }

    /// @dev The registry is the only address allowed to invoke DAO-gated
    ///      functions on this contract — proposal execution flows through
    ///      `StepRegistry`, so `msg.sender == registry` proves DAO consent.
    function _registry() internal view returns (address) {
        return address(REGISTRY);
    }

    // ─── Whitelist management (DAO-gated) ──────────────────────────────────

    /**
     * @notice Add an address to the fee-exempt whitelist.
     * @dev    Reachable only via a successful DAO proposal executed by
     *         the registry. Capacity is hard-capped at MAX_WHITELIST.
     */
    function addToWhitelist(address account) external {
        if (msg.sender != _registry()) revert Unauthorized();
        if (account == address(0))      revert ZeroAddress();
        if (isWhitelisted[account])     revert AlreadyWhitelisted();
        if (whitelistCount >= MAX_WHITELIST) revert WhitelistFull();

        isWhitelisted[account] = true;

        // Insert into the first free slot.
        for (uint256 i = 0; i < MAX_WHITELIST; i++) {
            if (whitelistedAddresses[i] == address(0)) {
                whitelistedAddresses[i] = account;
                break;
            }
        }
        whitelistCount++;
        emit AddedToWhitelist(account);
    }

    /**
     * @notice Remove an address from the fee-exempt whitelist.
     * @dev    Reachable only via a successful DAO proposal.
     */
    function removeFromWhitelist(address account) external {
        if (msg.sender != _registry()) revert Unauthorized();
        if (!isWhitelisted[account])   revert NotWhitelisted();

        isWhitelisted[account] = false;

        for (uint256 i = 0; i < MAX_WHITELIST; i++) {
            if (whitelistedAddresses[i] == account) {
                whitelistedAddresses[i] = address(0);
                break;
            }
        }
        whitelistCount--;
        emit RemovedFromWhitelist(account);
    }

    /// @notice Return the full whitelist as a fixed-size array (capacity
    ///         MAX_WHITELIST). Empty slots are `address(0)`.
    function getWhitelist() external view returns (address[MAX_WHITELIST] memory) {
        return whitelistedAddresses;
    }

    // ─── Mint / Burn ───────────────────────────────────────────────────────

    /**
     * @notice Mint the one-shot initial supply to the DEX bonding-curve
     *         contract. May only be called once, and only by the
     *         `originalDeployer` address fixed at construction.
     * @dev    Security notes:
     *           • The destination is read from the registry, not supplied
     *             as an argument, so the deployer cannot redirect tokens.
     *           • The registry itself is immutable on this contract, so a
     *             compromised deployer cannot retarget the destination.
     *           • `initialSupplyMinted` is a one-way latch — re-mint is
     *             impossible regardless of any future state.
     *         Operational recommendations: hold `originalDeployer` in a
     *         multisig and call this in the same deployment transaction
     *         that wires the DEX address into the registry.
     */
    function mintInitialSupply() external {
        if (msg.sender != originalDeployer) revert Unauthorized();
        if (initialSupplyMinted)            revert AlreadyMinted();
        address dex = _dex();
        if (dex == address(0))              revert ZeroAddress();
        initialSupplyMinted = true;
        _mint(dex, INITIAL_SUPPLY);
        emit InitialSupplyMinted(dex, INITIAL_SUPPLY);
    }

    /// @notice DEX-only mint. Each unit of STEP minted is backed by DAI
    ///         deposited into the AMM reserve at the same call.
    function mint(address to, uint256 amount) external {
        if (msg.sender != _dex()) revert NotDex();
        _mint(to, amount);
    }

    /// @notice Holder-initiated burn.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice DEX-only burn (used when sellers withdraw STEP for DAI; the
    ///         AMM burns the redeemed STEP to keep supply backed 1:1).
    function burnFromDex(address from, uint256 amount) external {
        if (msg.sender != _dex()) revert NotDex();
        _burn(from, amount);
    }

    // ─── DAO-gated migration ───────────────────────────────────────────────
    //  Paired migrations (KEY_STEP_COIN + KEY_STEP_DEX) iterate `migrateAssetsTo`
    //  on both old contracts. The ERC-20 ledger of STEP is immutable storage
    //  on this contract regardless of which DEX is registry-current, so this
    //  function performs no balance move by design; it exists so the
    //  iterator can step through the COIN slot without reverting. Any STEP
    //  that may have been transferred *to this contract address* by accident
    //  is forwarded to the new contract as part of the migration.
    event AssetsMigrated(address indexed to, uint256 daiAmount, uint256 stepAmount);

    function migrateAssetsTo(address newContract) external {
        if (msg.sender != _registry()) revert Unauthorized();
        if (newContract == address(0)) revert ZeroAddress();
        // Sweep any incidental self-held STEP into the successor.
        uint256 selfStepBal = balanceOf(address(this));
        if (selfStepBal > 0) {
            _update(address(this), newContract, selfStepBal);
        }
        emit AssetsMigrated(newContract, 0, selfStepBal);
    }

    // ─── Transfer hook (2 % deflationary levy) ─────────────────────────────

    function _update(address from, address to, uint256 amount) internal override {
        // Mints (from = 0) and burns (to = 0) are levy-free by definition.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        if (amount == 0) {
            super._update(from, to, amount);
            return;
        }

        // Whitelisted system contracts move STEP without the levy so internal
        // accounting (subscription rewards, treasury sweeps) is exact.
        if (isWhitelisted[from] || isWhitelisted[to]) {
            super._update(from, to, amount);
            return;
        }

        // Apply the 2 % deflationary levy (minimum 1 wei).
        uint256 fee = (amount * FEE_PERCENT) / FEE_DENOMINATOR;
        if (fee == 0) fee = 1;

        uint256 net = amount - fee;

        super._update(from, address(0), fee); // burn the levy
        emit TokensBurned(from, fee);

        super._update(from, to, net);
    }
}
