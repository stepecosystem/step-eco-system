// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

/**
 * @title  StepRegistry
 * @notice On-chain address book and governance hub for the Step Ecosystem.
 *
 *         Bootstrap: the controller wires initial addresses. After
 *         `activateDao()`, every sensitive change routes through a
 *         proposal -> veto window -> timelock flow; no deployer override
 *         remains and there is no address that can move or freeze user funds.
 *
 *         DESIGN NOTE — no pause / kill switch (intentional):
 *         The money-bearing contracts ship without an emergency-stop. This is
 *         a deliberate credibly-neutral choice: a pause is itself a privileged
 *         attack surface, and the failure modes it usually guards against are
 *         designed out instead (gas-checkpointed distributions, pull-payments,
 *         reentrancy guards, a non-zero AMM price floor). Legitimate change is
 *         delivered through DAO-timelocked governance, not a unilateral switch.
 *         Full rationale: see GOVERNANCE-AND-SAFETY.md.
 */
interface IStepNetDAO {
    function getActiveBox0Count() external view returns (uint256);
    function getBox0WeakerSide(address user) external view returns (uint256);
    function hasBox0(address user) external view returns (bool);
    /// @notice Required for the proposal-creation gate (Box 5 only).
    /// Voting still uses hasBox0; only proposal creation is restricted.
    function hasBox5(address user) external view returns (bool);
    function getTotalWeakerSide(address user) external view returns (uint256);
    /// @notice Needed for the voter-eligibility check (must be registered before proposal creation).
    function getUserStartTimestamp(address user) external view returns (uint256);
}

interface IStepCoinWhitelist {
    function addToWhitelist(address account) external;
    function removeFromWhitelist(address account) external;
}

interface IMigratableAssets {
    function migrateAssetsTo(address newContract) external;
}

/**
 * @title  StepRegistry
 * @notice Central directory + on-chain governance hub for the Step
 *         Ecosystem. Every system contract resolves its peers through this
 *         registry, and every parameter or asset move that affects users
 *         flows through a DAO proposal here.
 *
 *         Two governance surfaces live on this contract:
 *           • Pointer / whitelist proposals (createProposal) — change a
 *             registry address or update the STEP whitelist.
 *           • Asset migration proposals (proposeMigration) — atomically
 *             change up to two registry pointers AND move the liquid DAI +
 *             STEP held by the old contracts to their successors, all
 *             behind a timelock.
 *
 *         Anti-abuse invariants:
 *           • Proposer must hold the top subscription tier (Box 5) — the
 *             cost of reaching that tier makes spam proposals economically
 *             irrational.
 *           • Voter weight is `1 + min(left, right)` of the voter's
 *             permanent Box-0 subtree counters, capped by the snapshot of
 *             total Box-0 subscribers at proposal creation. This blocks
 *             "flash-recruit and inflate" attacks without requiring full
 *             ERC20Votes checkpointing.
 *           • Voters must have existed in the system before the proposal
 *             was created.
 *           • All structural changes wait through a veto window during
 *             which the controller may abort, then a timelock before
 *             execution.
 *
 *         End-user gating: every value-bearing entry point in the
 *         ecosystem requires the caller to have on-chain acknowledged the
 *         Terms-of-Service hash registered here. See `updateTermsHash`,
 *         `acceptTerms`, `hasAcceptedCurrentTerms`.
 */
contract StepRegistry {

    // ─── Errors ────────────────────────────────────────────────────────────────
    error Unauthorized();
    error ZeroAddress();
    error NoPendingChange();
    error DelayNotPassed();
    error AlreadyExecuted();
    error ControlAlreadyRenounced();
    error SameAddress();
    error AlreadySet();
    error DaoNotActive();
    error StepNetNotSet();
    error StepNetViewNotSet();
    error NotEligibleToVote();
    error VoterNotPreExisting();
    error NotEligibleToPropose();
    error ProposalNotFound();
    error VotingEnded();
    error AlreadyVoted();
    error ProposalNotPassed();
    error ProposalAlreadyExecuted();
    error ProposalExpired();
    error ActiveProposalExists();
    error ControllerChangeBlockedAfterDaoActivation();
    error LengthMismatch();
    error StepCoinNotSet();
    error KeyIsImmutable();
    error VetoWindowNotOpen();
    error AlreadyVetoed();
    error ProposalNotEnded();
    error MustProposeAsPair();
    // Terms-of-Service error
    error TermsNotAccepted();

    // ─── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant VOTING_PERIOD   = 7 days;
    uint256 public constant PROPOSAL_EXPIRY = 11 days;
    uint256 public constant VETO_WINDOW     = 7 days;
    uint256 public migrationTimelock = 7 days;

    bytes32 public constant KEY_STEP_COIN     = keccak256("STEP_COIN");
    bytes32 public constant KEY_STEP_DEX      = keccak256("STEP_DEX");
    bytes32 public constant KEY_STEP_NET      = keccak256("STEP_NET");
    bytes32 public constant KEY_STEP_NET_VIEW = keccak256("STEP_NET_VIEW");
    bytes32 public constant KEY_NFT_TREASURY  = keccak256("NFT_TREASURY");
    bytes32 public constant KEY_CLUB_TREASURY = keccak256("CLUB_TREASURY");
    bytes32 public constant KEY_DEV_TREASURY  = keccak256("DEV_TREASURY");
    bytes32 public constant KEY_WL_ADD    = keccak256("WHITELIST_ADD");
    bytes32 public constant KEY_WL_REMOVE = keccak256("WHITELIST_REMOVE");

    // ─── State ─────────────────────────────────────────────────────────────────
    address public controller;
    bool    public controlRenounced;

    mapping(bytes32 => address) public addresses;

    struct PendingChange {
        address newAddress;
        uint256 scheduledAt;
        bool    executed;
    }
    mapping(bytes32 => PendingChange) public pendingChanges;

    IStepNetDAO public stepNet;
    IStepNetDAO public stepNetView;
    bool        public daoActive;
    uint256     public proposalCount;

    enum ProposalType { ADDRESS_CHANGE, WL_ADD, WL_REMOVE }

    struct Proposal {
        bytes32      key;
        address      newAddress;
        address      proposer;
        uint256      createdAt;
        uint256      votingEndsAt;
        uint256      totalVoteWeight;
        uint256      voterCount;
        /// @dev Snapshot of `getActiveBox0Count()` at creation; serves as
        ///      the threshold denominator and the per-voter weight cap.
        uint256      snapshotBox0Count;
        bool         executed;
        bool         passed;
        bool         vetoed;
        ProposalType proposalType;
        uint256      pairedProposalId;
    }

    mapping(uint256 => Proposal)                    public proposals;
    mapping(uint256 => mapping(address => bool))    public hasVoted;
    mapping(uint256 => mapping(address => uint256)) public voterWeight;
    mapping(bytes32 => uint256)                     public activeProposalForKey;

    // ════════════════════════════════════════════════════════════════════════
    //  Terms of Service
    //
    //  Every external participant must acknowledge the short on-chain terms
    //  text below before their first value-bearing interaction. The text is
    //  embedded as a constant string in this contract — no off-chain
    //  document, no hash, no URI. The user reads `TERMS_OF_SERVICE`, signs
    //  one transaction (`acceptTerms()`), and is recorded on-chain as having
    //  consented. The record is permanent and serves as enforceable proof
    //  of informed consent in any subsequent legal proceeding.
    // ════════════════════════════════════════════════════════════════════════

    /// @notice The full Terms of Service. By calling `acceptTerms()` from
    ///         your wallet you agree to the entirety of this text.
    string public constant TERMS_OF_SERVICE =
        "Step Ecosystem Terms of Service. "
        "By submitting this transaction I confirm that: "
        "(1) I have read and understood the smart-contract source code and "
        "tokenomics of the Step Ecosystem; "
        "(2) my participation is the result of my own independent research "
        "and decision, and I have not relied on any statement, projection, "
        "or guarantee made by the protocol, its developers, its deployer, "
        "my referrer, or any other party; "
        "(3) the boxes I may activate are subscriptions to digital and "
        "AI-driven services, not investment products or securities; "
        "(4) I accept the financial risk inherent to participation, "
        "including the possibility of total loss of any funds I commit; "
        "(5) participation is legal under the laws of my jurisdiction and "
        "I have reached the age of majority; "
        "(6) I release the protocol, its developers, its deployer, my "
        "referrer, all other participants, and all affiliated parties from "
        "any and all claims, demands, damages, losses, and liabilities of "
        "any kind arising out of my participation; "
        "(7) I will indemnify every party named in clause (6) against any "
        "third-party claim arising from my use of the protocol; "
        "(8) every blockchain transaction is final and irreversible.";

    mapping(address => uint256) public acceptedTermsAt;

    // ─── Events ────────────────────────────────────────────────────────────────
    event AddressSet(bytes32 indexed key, address indexed addr);
    event ChangeScheduled(bytes32 indexed key, address indexed newAddr, uint256 executeAfter);
    event ChangeExecuted(bytes32 indexed key, address indexed newAddr);
    event ChangeCancelled(bytes32 indexed key);
    event ControlTransferred(address indexed oldController, address indexed newController);
    event ControlRenounced(address indexed lastController);
    event DaoActivated();
    event StepNetUpdated(address indexed stepNetAddr);
    event StepNetViewUpdated(address indexed stepNetViewAddr);
    event ProposalCreated(uint256 indexed proposalId, bytes32 indexed key, address indexed newAddress, address proposer, ProposalType proposalType, uint256 snapshotBox0Count);
    event Voted(uint256 indexed proposalId, address indexed voter, uint256 weight, uint256 newTotal);
    event ProposalPassed(uint256 indexed proposalId, uint256 totalWeight, uint256 threshold);
    event ProposalExecuted(uint256 indexed proposalId, bytes32 indexed key, address indexed newAddress);
    event ProposalVetoed(uint256 indexed proposalId, address indexed vetoer);
    event WhitelistAddProposed(uint256 indexed proposalId, address indexed account);
    event WhitelistRemoveProposed(uint256 indexed proposalId, address indexed account);
    event WhitelistAddExecuted(uint256 indexed proposalId, address indexed account);
    event WhitelistRemoveExecuted(uint256 indexed proposalId, address indexed account);

    // ─── Terms-of-Service event ─────────────────────────────────────────────
    event TermsAccepted(address indexed user, uint256 timestamp);

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(address _controller) {
        if (_controller == address(0)) revert ZeroAddress();
        controller = _controller;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ─── Reentrancy Guard ─────────────────────────────────────────────────────
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert("ReentrancyGuard: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyController() {
        if (controlRenounced) revert ControlAlreadyRenounced();
        if (msg.sender != controller) revert Unauthorized();
        _;
    }
    modifier onlyControllerBeforeDao() {
        if (controlRenounced) revert ControlAlreadyRenounced();
        if (msg.sender != controller) revert Unauthorized();
        if (daoActive) revert ControllerChangeBlockedAfterDaoActivation();
        _;
    }

    // ─── Terms-of-Service ─────────────────────────────────────────────────────

    /**
     * @notice Acknowledge the on-chain `TERMS_OF_SERVICE` text. One
     *         transaction from the user's wallet — no arguments, no hash,
     *         no off-chain document. The block timestamp of acceptance is
     *         recorded permanently and constitutes legally enforceable
     *         proof of informed consent.
     * @dev    Required before any subscription activation, AMM trade, or
     *         NFT purchase. Acceptance is wallet-scoped and persists for
     *         the lifetime of the contract.
     */
    function acceptTerms() external {
        acceptedTermsAt[msg.sender] = block.timestamp;
        emit TermsAccepted(msg.sender, block.timestamp);
    }

    /// @notice Read-only check used by other system contracts (StepNet,
    ///         StepDex, StepNFTTreasury) to gate user-initiated entry points.
    function hasAcceptedCurrentTerms(address user) external view returns (bool) {
        return acceptedTermsAt[user] != 0;
    }

    // ─── Controller setup ─────────────────────────────────────────────────────
    function setInitial(bytes32 key, address addr) external onlyController {
        if (addr == address(0)) revert ZeroAddress();
        if (addresses[key] != address(0)) revert AlreadySet();
        addresses[key] = addr;
        emit AddressSet(key, addr);
    }

    function setInitialBatch(bytes32[] calldata keys, address[] calldata addrs) external onlyController {
        if (keys.length != addrs.length) revert LengthMismatch();
        for (uint256 i = 0; i < keys.length; i++) {
            if (addrs[i] == address(0)) revert ZeroAddress();
            if (addresses[keys[i]] != address(0)) revert AlreadySet();
            addresses[keys[i]] = addrs[i];
            emit AddressSet(keys[i], addrs[i]);
        }
    }

    function scheduleChange(bytes32 key, address newAddress) external onlyControllerBeforeDao {
        if (newAddress == address(0)) revert ZeroAddress();
        if (addresses[key] == newAddress) revert SameAddress();
        pendingChanges[key] = PendingChange({newAddress: newAddress, scheduledAt: block.timestamp, executed: false});
        emit ChangeScheduled(key, newAddress, block.timestamp);
    }

    function executeChange(bytes32 key) external onlyControllerBeforeDao {
        PendingChange storage c = pendingChanges[key];
        if (c.newAddress == address(0)) revert NoPendingChange();
        if (c.executed) revert AlreadyExecuted();
        c.executed = true;
        addresses[key] = c.newAddress;
        emit ChangeExecuted(key, c.newAddress);
    }

    function cancelChange(bytes32 key) external onlyController {
        delete pendingChanges[key];
        emit ChangeCancelled(key);
    }

    function transferControl(address newController) external onlyController {
        if (newController == address(0)) revert ZeroAddress();
        if (newController == controller) revert SameAddress();
        emit ControlTransferred(controller, newController);
        controller = newController;
    }

    function renounceControl() external onlyController {
        if (!daoActive) revert DaoNotActive();
        if (address(stepNet) == address(0)) revert StepNetNotSet();
        emit ControlRenounced(controller);
        controlRenounced = true;
        controller = address(0);
    }

    function setStepNet(address _stepNet) external onlyControllerBeforeDao {
        if (_stepNet == address(0)) revert ZeroAddress();
        stepNet = IStepNetDAO(_stepNet);
        emit StepNetUpdated(_stepNet);
    }

    function setStepNetView(address _stepNetView) external onlyControllerBeforeDao {
        if (_stepNetView == address(0)) revert ZeroAddress();
        stepNetView = IStepNetDAO(_stepNetView);
        addresses[KEY_STEP_NET_VIEW] = _stepNetView;
        emit StepNetViewUpdated(_stepNetView);
    }

    function activateDao() external onlyController {
        if (address(stepNet) == address(0)) revert StepNetNotSet();
        if (address(stepNetView) == address(0)) revert StepNetViewNotSet();
        daoActive = true;
        emit DaoActivated();
    }

    /// @dev Shared proposal-construction routine. Enforces DAO readiness,
    ///      proposer eligibility (Box 5), and snapshots the threshold
    ///      denominator atomically with proposal creation.
    function _newProposal(
        bytes32      key,
        address      newAddress,
        ProposalType pType
    ) internal returns (uint256 proposalId) {
        if (!daoActive) revert DaoNotActive();
        if (address(stepNet) == address(0)) revert StepNetNotSet();
        if (address(stepNetView) == address(0)) revert StepNetViewNotSet();
        if (newAddress == address(0)) revert ZeroAddress();

        IStepNetDAO dao = stepNetView;
        // Spam-DoS guard: proposal creation requires the top tier so spam
        // attempts are economically irrational.
        if (!dao.hasBox5(msg.sender)) revert NotEligibleToPropose();

        uint256 existingId = activeProposalForKey[key];
        if (existingId != 0) {
            Proposal storage existing = proposals[existingId];
            bool expired = block.timestamp > existing.createdAt + PROPOSAL_EXPIRY;
            if (!expired && !existing.executed) revert ActiveProposalExists();
            delete activeProposalForKey[key];
        }

        unchecked { ++proposalCount; }
        proposalId = proposalCount;

        // Snapshot the denominator now so it cannot be flash-inflated.
        uint256 snap = dao.getActiveBox0Count();

        proposals[proposalId] = Proposal({
            key:               key,
            newAddress:        newAddress,
            proposer:          msg.sender,
            createdAt:         block.timestamp,
            votingEndsAt:      block.timestamp + VOTING_PERIOD,
            totalVoteWeight:   0,
            voterCount:        0,
            snapshotBox0Count: snap,
            executed:          false,
            passed:            false,
            vetoed:            false,
            proposalType:      pType,
            pairedProposalId:  0
        });

        activeProposalForKey[key] = proposalId;
    }

    // ─── Proposal entry points ─────────────────────────────────────────────

    /**
     * @notice Propose changing a single registry pointer (whitelist or
     *         non-coupled service address).
     * @dev    KEY_STEP_COIN / KEY_STEP_DEX are immutable from this entry —
     *         their addresses are coupled and may only move via
     *         `proposeMigration` (paired). KEY_STEP_NET is also paired
     *         (with KEY_STEP_NET_VIEW); the view layer is allowed to move
     *         alone.
     */
    function createProposal(bytes32 key, address newAddress) external returns (uint256 proposalId) {
        if (key == KEY_STEP_COIN || key == KEY_STEP_DEX) revert KeyIsImmutable();
        if (key == KEY_STEP_NET) revert MustProposeAsPair();
        if (addresses[key] == newAddress) revert SameAddress();
        proposalId = _newProposal(key, newAddress, ProposalType.ADDRESS_CHANGE);
        emit ProposalCreated(proposalId, key, newAddress, msg.sender, ProposalType.ADDRESS_CHANGE, proposals[proposalId].snapshotBox0Count);
    }

    function createPairedNetProposal(
        address newStepNet,
        address newStepNetView
    ) external returns (uint256 netProposalId, uint256 viewProposalId) {
        if (newStepNet     == address(0)) revert ZeroAddress();
        if (newStepNetView == address(0)) revert ZeroAddress();
        if (addresses[KEY_STEP_NET]      == newStepNet)     revert SameAddress();
        if (addresses[KEY_STEP_NET_VIEW] == newStepNetView) revert SameAddress();

        netProposalId  = _newProposal(KEY_STEP_NET,      newStepNet,     ProposalType.ADDRESS_CHANGE);
        viewProposalId = _newProposal(KEY_STEP_NET_VIEW, newStepNetView, ProposalType.ADDRESS_CHANGE);

        proposals[netProposalId].pairedProposalId  = viewProposalId;
        proposals[viewProposalId].pairedProposalId = netProposalId;

        emit ProposalCreated(netProposalId,  KEY_STEP_NET,      newStepNet,     msg.sender, ProposalType.ADDRESS_CHANGE, proposals[netProposalId].snapshotBox0Count);
        emit ProposalCreated(viewProposalId, KEY_STEP_NET_VIEW, newStepNetView, msg.sender, ProposalType.ADDRESS_CHANGE, proposals[viewProposalId].snapshotBox0Count);
    }

    function createWhitelistAddProposal(address account) external returns (uint256 proposalId) {
        bytes32 key = keccak256(abi.encodePacked(KEY_WL_ADD, account));
        proposalId  = _newProposal(key, account, ProposalType.WL_ADD);
        emit ProposalCreated(proposalId, key, account, msg.sender, ProposalType.WL_ADD, proposals[proposalId].snapshotBox0Count);
        emit WhitelistAddProposed(proposalId, account);
    }

    function createWhitelistRemoveProposal(address account) external returns (uint256 proposalId) {
        bytes32 key = keccak256(abi.encodePacked(KEY_WL_REMOVE, account));
        proposalId  = _newProposal(key, account, ProposalType.WL_REMOVE);
        emit ProposalCreated(proposalId, key, account, msg.sender, ProposalType.WL_REMOVE, proposals[proposalId].snapshotBox0Count);
        emit WhitelistRemoveProposed(proposalId, account);
    }

    /**
     * @notice Cast a vote on a pointer/whitelist proposal.
     * @dev    Voter weight = `1 + getBox0WeakerSide(voter)` (permanent
     *         subtree counters), capped by `snapshotBox0Count`. This is a
     *         soft cap derived from the snapshot of total Box-0 subscribers
     *         at proposal-creation time; it closes the recruit-and-inflate
     *         attack without requiring ERC20Votes-style checkpointing.
     */
    function vote(uint256 proposalId) external nonReentrant {
        if (!daoActive) revert DaoNotActive();
        if (address(stepNetView) == address(0)) revert StepNetViewNotSet();

        IStepNetDAO dao = stepNetView;

        Proposal storage p = proposals[proposalId];
        if (p.createdAt == 0)                                    revert ProposalNotFound();
        if (block.timestamp > p.votingEndsAt)                    revert VotingEnded();
        if (block.timestamp > p.createdAt + PROPOSAL_EXPIRY)     revert ProposalExpired();
        if (p.executed)                                          revert ProposalAlreadyExecuted();
        if (p.vetoed)                                            revert ProposalNotPassed();
        if (hasVoted[proposalId][msg.sender])                    revert AlreadyVoted();
        if (!dao.hasBox0(msg.sender))                            revert NotEligibleToVote();

        uint256 voterStartTime = dao.getUserStartTimestamp(msg.sender);
        if (voterStartTime == 0 || voterStartTime > p.createdAt) revert VoterNotPreExisting();

        uint256 liveWeight = 1 + dao.getBox0WeakerSide(msg.sender);
        uint256 weight = liveWeight > p.snapshotBox0Count
            ? p.snapshotBox0Count
            : liveWeight;

        hasVoted[proposalId][msg.sender]    = true;
        voterWeight[proposalId][msg.sender] = weight;
        p.totalVoteWeight += weight;
        p.voterCount      += 1;

        emit Voted(proposalId, msg.sender, weight, p.totalVoteWeight);

        if (!p.passed) {
            uint256 threshold = _thresholdOf(p.snapshotBox0Count);
            if (p.totalVoteWeight >= threshold) {
                p.passed = true;
                emit ProposalPassed(proposalId, p.totalVoteWeight, threshold);
            }
        }
    }

    function vetoProposal(uint256 proposalId) external onlyController nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (p.createdAt == 0)                                    revert ProposalNotFound();
        if (!p.passed)                                           revert ProposalNotPassed();
        if (p.executed)                                          revert ProposalAlreadyExecuted();
        if (p.vetoed)                                            revert AlreadyVetoed();
        if (block.timestamp <= p.votingEndsAt)                   revert ProposalNotEnded();
        if (block.timestamp > p.votingEndsAt + VETO_WINDOW)      revert VetoWindowNotOpen();

        p.vetoed = true;
        delete activeProposalForKey[p.key];

        if (p.pairedProposalId != 0) {
            Proposal storage paired = proposals[p.pairedProposalId];
            if (!paired.executed && !paired.vetoed) {
                paired.vetoed = true;
                delete activeProposalForKey[paired.key];
                emit ProposalVetoed(p.pairedProposalId, msg.sender);
            }
        }
        emit ProposalVetoed(proposalId, msg.sender);
    }

    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (p.createdAt == 0)                                    revert ProposalNotFound();
        if (!p.passed)                                           revert ProposalNotPassed();
        if (p.executed)                                          revert ProposalAlreadyExecuted();
        if (p.vetoed)                                            revert ProposalNotPassed();
        if (block.timestamp > p.createdAt + PROPOSAL_EXPIRY + VETO_WINDOW) revert ProposalExpired();
        if (block.timestamp <= p.votingEndsAt)                   revert ProposalNotEnded();
        if (block.timestamp <= p.votingEndsAt + VETO_WINDOW)     revert VetoWindowNotOpen();

        if (p.pairedProposalId != 0) {
            Proposal storage paired = proposals[p.pairedProposalId];
            if (!paired.passed || paired.vetoed) revert ProposalNotPassed();
            if (!paired.executed) {
                _executeProposal(p.pairedProposalId, paired);
            }
        }
        _executeProposal(proposalId, p);
    }

    function _executeProposal(uint256 proposalId, Proposal storage p) internal {
        p.executed = true;
        delete activeProposalForKey[p.key];

        if (p.proposalType == ProposalType.ADDRESS_CHANGE) {
            addresses[p.key] = p.newAddress;

            if (p.key == KEY_STEP_NET) {
                if (p.newAddress == address(0)) revert ZeroAddress();
                stepNet = IStepNetDAO(p.newAddress);
                emit StepNetUpdated(p.newAddress);
            }
            if (p.key == KEY_STEP_NET_VIEW) {
                if (p.newAddress == address(0)) revert ZeroAddress();
                stepNetView = IStepNetDAO(p.newAddress);
                addresses[KEY_STEP_NET_VIEW] = p.newAddress;
                emit StepNetViewUpdated(p.newAddress);
            }
            emit ChangeExecuted(p.key, p.newAddress);
            emit ProposalExecuted(proposalId, p.key, p.newAddress);

        } else if (p.proposalType == ProposalType.WL_ADD) {
            address stepCoin = addresses[KEY_STEP_COIN];
            if (stepCoin == address(0)) revert StepCoinNotSet();
            IStepCoinWhitelist(stepCoin).addToWhitelist(p.newAddress);
            emit WhitelistAddExecuted(proposalId, p.newAddress);
            emit ProposalExecuted(proposalId, p.key, p.newAddress);

        } else {
            address stepCoin = addresses[KEY_STEP_COIN];
            if (stepCoin == address(0)) revert StepCoinNotSet();
            IStepCoinWhitelist(stepCoin).removeFromWhitelist(p.newAddress);
            emit WhitelistRemoveExecuted(proposalId, p.newAddress);
            emit ProposalExecuted(proposalId, p.key, p.newAddress);
        }
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────
    function _thresholdOf(uint256 totalBox0Count) internal pure returns (uint256) {
        if (totalBox0Count == 0) return type(uint256).max;
        return (totalBox0Count * 51 + 99) / 100;
    }

    function _liveThreshold() internal view returns (uint256) {
        IStepNetDAO dao = address(stepNetView) != address(0) ? stepNetView : stepNet;
        if (address(dao) == address(0)) return type(uint256).max;
        return _thresholdOf(dao.getActiveBox0Count());
    }

    // ─── View functions ───────────────────────────────────────────────────────
    function get(bytes32 key) external view returns (address) {
        return addresses[key];
    }

    function getAllAddresses() external view returns (
        address stepCoin,
        address stepDex,
        address stepNetAddr,
        address nftTreasury,
        address clubTreasury,
        address devTreasury
    ) {
        stepCoin     = addresses[KEY_STEP_COIN];
        stepDex      = addresses[KEY_STEP_DEX];
        stepNetAddr  = addresses[KEY_STEP_NET];
        nftTreasury  = addresses[KEY_NFT_TREASURY];
        clubTreasury = addresses[KEY_CLUB_TREASURY];
        devTreasury  = addresses[KEY_DEV_TREASURY];
    }

    function getPendingChange(bytes32 key) external view returns (
        address newAddress,
        uint256 scheduledAt,
        uint256 executeAfter,
        uint256 timeRemaining,
        bool    executed
    ) {
        PendingChange memory c = pendingChanges[key];
        newAddress    = c.newAddress;
        scheduledAt   = c.scheduledAt;
        executeAfter  = c.scheduledAt;
        executed      = c.executed;
        timeRemaining = (c.newAddress == address(0) || block.timestamp >= executeAfter)
                        ? 0 : executeAfter - block.timestamp;
    }

    function getProposal(uint256 proposalId) external view returns (
        bytes32      key,
        address      newAddress,
        address      proposer,
        uint256      createdAt,
        uint256      votingEndsAt,
        uint256      totalVoteWeight,
        uint256      voterCount,
        bool         executed,
        bool         passed,
        bool         vetoed,
        uint256      snapshotThreshold,
        bool         canExecute,
        bool         inVetoWindow,
        uint256      pairedProposalId,
        ProposalType proposalType
    ) {
        Proposal storage p = proposals[proposalId];
        key                = p.key;
        newAddress         = p.newAddress;
        proposer           = p.proposer;
        createdAt          = p.createdAt;
        votingEndsAt       = p.votingEndsAt;
        totalVoteWeight    = p.totalVoteWeight;
        voterCount         = p.voterCount;
        executed           = p.executed;
        passed             = p.passed;
        vetoed             = p.vetoed;
        snapshotThreshold  = _thresholdOf(p.snapshotBox0Count);
        pairedProposalId   = p.pairedProposalId;
        proposalType       = p.proposalType;

        bool votingOver  = block.timestamp > p.votingEndsAt;
        bool vetoExpired = block.timestamp > p.votingEndsAt + VETO_WINDOW;
        bool notExpired  = block.timestamp <= p.createdAt + PROPOSAL_EXPIRY + VETO_WINDOW;
        inVetoWindow = p.passed && !p.executed && !p.vetoed && votingOver && !vetoExpired;
        canExecute   = p.passed && !p.executed && !p.vetoed && vetoExpired && notExpired;
    }

    function getCurrentThreshold() external view returns (uint256) {
        return _liveThreshold();
    }

    function getVotingPower(address user) external view returns (uint256) {
        IStepNetDAO dao = address(stepNetView) != address(0) ? stepNetView : stepNet;
        if (address(dao) == address(0)) return 0;
        if (!dao.hasBox0(user)) return 0;
        return 1 + dao.getBox0WeakerSide(user);
    }

    function getTotalBox0Count() external view returns (uint256) {
        IStepNetDAO dao = address(stepNetView) != address(0) ? stepNetView : stepNet;
        if (address(dao) == address(0)) return 0;
        return dao.getActiveBox0Count();
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                              MIGRATION MODULE
    //
    //  Asset-bearing pointer changes (with optional balance transfer) flow
    //  through this separate proposal family. Adds an explicit timelock on
    //  top of the standard veto window so the controller, the community,
    //  and integrators all have time to react to a passing migration before
    //  funds move.
    // ══════════════════════════════════════════════════════════════════════════

    error MigNotFound();
    error MigAlreadyExecuted();
    error MigVetoed();
    error MigNotPassed();
    error MigVetoWindowOpen();
    error MigTimelockNotPassed();
    error MigAlreadyVoted();
    error MigNotEligible();
    error MigVotingEnded();
    error MigPairRequired();

    struct Migration {
        bytes32  keyA;
        address  newA;
        bytes32  keyB;
        address  newB;
        bool     migrateAssets;
        address  proposer;
        uint256  createdAt;
        uint256  votingEndsAt;
        uint256  timelockEndsAt;
        uint256  totalVoteWeight;
        uint256  voterCount;
        uint256  snapshotBox0Count;    // total Box-0 holders snapshotted at proposal creation (quorum base)
        bool     passed;
        bool     vetoed;
        bool     executed;
        /// @dev `snapshotBox0Count` is included for both threshold
        ///      computation and per-voter weight capping, mirroring the
        ///      Proposal struct.
    }

    uint256 public migrationCount;
    mapping(uint256 => Migration)                public migrations;
    mapping(uint256 => mapping(address => bool)) public migHasVoted;

    event MigrationProposed(uint256 indexed id, bytes32 keyA, address newA, bytes32 keyB, address newB, bool migrateAssets, uint256 snapshotBox0Count);
    event MigrationVoted(uint256 indexed id, address indexed voter, uint256 weight, uint256 total);
    event MigrationPassed(uint256 indexed id, uint256 timelockEndsAt);
    event MigrationVetoed(uint256 indexed id, address indexed by);
    event MigrationExecuted(uint256 indexed id);
    event MigrationTimelockUpdated(uint256 oldVal, uint256 newVal);

    function setMigrationTimelock(uint256 newTimelock) external onlyController {
        emit MigrationTimelockUpdated(migrationTimelock, newTimelock);
        migrationTimelock = newTimelock;
    }

    function proposeMigration(
        bytes32 keyA, address newA,
        bytes32 keyB, address newB,
        bool migrateAssets
    ) external nonReentrant returns (uint256 id) {
        if (!daoActive) revert DaoNotActive();
        if (address(stepNet) == address(0)) revert StepNetNotSet();
        if (address(stepNetView) == address(0)) revert StepNetViewNotSet();
        if (newA == address(0)) revert ZeroAddress();

        IStepNetDAO dao = stepNetView;
        // Migration proposal creation also requires the top tier.
        if (!dao.hasBox5(msg.sender)) revert MigNotEligible();

        bool aIsCoinOrDex = (keyA == KEY_STEP_COIN || keyA == KEY_STEP_DEX);
        bool bIsCoinOrDex = (keyB == KEY_STEP_COIN || keyB == KEY_STEP_DEX);
        if (aIsCoinOrDex || bIsCoinOrDex) {
            bool validPair =
                ((keyA == KEY_STEP_COIN && keyB == KEY_STEP_DEX) ||
                 (keyA == KEY_STEP_DEX  && keyB == KEY_STEP_COIN)) &&
                newB != address(0);
            if (!validPair) revert MigPairRequired();
        }

        id = ++migrationCount;
        migrations[id] = Migration({
            keyA: keyA, newA: newA, keyB: keyB, newB: newB,
            migrateAssets: migrateAssets,
            proposer: msg.sender,
            createdAt: block.timestamp,
            votingEndsAt: block.timestamp + VOTING_PERIOD,
            timelockEndsAt: 0,
            totalVoteWeight: 0, voterCount: 0,
            snapshotBox0Count: dao.getActiveBox0Count(),
            passed: false, vetoed: false, executed: false
        });
        emit MigrationProposed(id, keyA, newA, keyB, newB, migrateAssets, migrations[id].snapshotBox0Count);
    }

    function voteMigration(uint256 id) external nonReentrant {
        Migration storage m = migrations[id];
        if (m.createdAt == 0)                  revert MigNotFound();
        if (block.timestamp > m.votingEndsAt)  revert MigVotingEnded();
        if (m.executed)                        revert MigAlreadyExecuted();
        if (m.vetoed)                          revert MigVetoed();
        if (migHasVoted[id][msg.sender])       revert MigAlreadyVoted();

        IStepNetDAO dao = stepNetView;
        if (address(dao) == address(0)) revert StepNetViewNotSet();
        if (!dao.hasBox0(msg.sender)) revert MigNotEligible();

        uint256 voterStart = dao.getUserStartTimestamp(msg.sender);
        if (voterStart == 0 || voterStart > m.createdAt) revert VoterNotPreExisting();

        // Same weight model as `vote`: live `getBox0WeakerSide` capped at
        // `snapshotBox0Count` to defeat post-creation recruit inflation.
        uint256 liveWeight = 1 + dao.getBox0WeakerSide(msg.sender);
        uint256 weight = liveWeight > m.snapshotBox0Count
            ? m.snapshotBox0Count
            : liveWeight;

        migHasVoted[id][msg.sender] = true;
        m.totalVoteWeight += weight;
        m.voterCount      += 1;
        emit MigrationVoted(id, msg.sender, weight, m.totalVoteWeight);

        if (!m.passed && m.totalVoteWeight >= _thresholdOf(m.snapshotBox0Count)) {
            m.passed = true;
            m.timelockEndsAt = m.votingEndsAt + VETO_WINDOW + migrationTimelock;
            emit MigrationPassed(id, m.timelockEndsAt);
        }
    }

    function vetoMigration(uint256 id) external onlyController nonReentrant {
        Migration storage m = migrations[id];
        if (m.createdAt == 0)                              revert MigNotFound();
        if (m.executed)                                    revert MigAlreadyExecuted();
        if (block.timestamp <= m.votingEndsAt)             revert MigVetoWindowOpen();
        if (block.timestamp > m.votingEndsAt + VETO_WINDOW) revert MigVetoWindowOpen();
        m.vetoed = true;
        emit MigrationVetoed(id, msg.sender);
    }

    function executeMigration(uint256 id) external nonReentrant {
        Migration storage m = migrations[id];
        if (m.createdAt == 0)                          revert MigNotFound();
        if (m.executed)                                revert MigAlreadyExecuted();
        if (m.vetoed)                                  revert MigVetoed();
        if (!m.passed)                                 revert MigNotPassed();
        if (block.timestamp <= m.votingEndsAt + VETO_WINDOW) revert MigVetoWindowOpen();
        if (block.timestamp < m.timelockEndsAt)        revert MigTimelockNotPassed();

        m.executed = true;

        if (m.migrateAssets) {
            address oldA = addresses[m.keyA];
            if (oldA != address(0)) IMigratableAssets(oldA).migrateAssetsTo(m.newA);
            if (m.keyB != bytes32(0)) {
                address oldB = addresses[m.keyB];
                if (oldB != address(0)) IMigratableAssets(oldB).migrateAssetsTo(m.newB);
            }
        }

        addresses[m.keyA] = m.newA;
        emit AddressSet(m.keyA, m.newA);
        if (m.keyB != bytes32(0)) {
            addresses[m.keyB] = m.newB;
            emit AddressSet(m.keyB, m.newB);
        }
        emit MigrationExecuted(id);
    }
}
