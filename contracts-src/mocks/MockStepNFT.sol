// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Test-only stand-in for the StepNFTTreasury collection, shaped
 *         exactly the way StepNFTFund uses it. NOT for mainnet.
 *
 *  • `getPrice` is the production mint curve, copied verbatim, so tier
 *    boundaries (200 / 300 / 400 …) behave as they do on-chain.
 *  • `getCurrentPrice` is the "day price": the price of `nextBuyId`, zero
 *    once sold out — the same rule as production.
 *  • `transferFrom` charges the collection's 10 % transfer levy in DAI on the
 *    `from` side, because StepNFTFund's custody logic is built around paying
 *    it. A mock that moved tokens for free would pass tests the real
 *    collection fails.
 *  • `ownerOf` reverts for an id that was never minted, like ERC-721.
 */
contract MockStepNFT {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1000;
    uint256 public constant TRANSFER_FEE_PCT = 10;

    IERC20 public immutable DAI;
    IERC20 public immutable STEP;
    address public immutable wallet90;
    address public immutable wallet10;

    uint256 public nextBuyId = 1;

    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @notice STEP this collection's own reward engine owes each address.
    mapping(address => uint256) public pendingOf;

    error NotMinted();
    error NotAuthorized();
    error WrongOwner();

    constructor(address dai_, address step_, address wallet90_, address wallet10_) {
        DAI = IERC20(dai_);
        STEP = IERC20(step_);
        wallet90 = wallet90_;
        wallet10 = wallet10_;
    }

    // ─── Production pricing ──────────────────────────────────────────────────
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

    // ─── Minimal ERC-721 surface ─────────────────────────────────────────────
    function ownerOf(uint256 id) external view returns (address o) {
        o = _owners[id];
        if (o == address(0)) revert NotMinted();
    }

    function approve(address to, uint256 id) external {
        if (_owners[id] != msg.sender) revert NotAuthorized();
        getApproved[id] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 id) external {
        if (_owners[id] != from) revert WrongOwner();
        if (msg.sender != from && getApproved[id] != msg.sender && !isApprovedForAll[from][msg.sender]) {
            revert NotAuthorized();
        }
        uint256 fee = (getPrice(id) * TRANSFER_FEE_PCT) / 100;
        DAI.safeTransferFrom(from, wallet10, fee);
        getApproved[id] = address(0);
        _owners[id] = to;
    }

    // ─── Reward engine (what StepNFTFund sweeps) ─────────────────────────────
    function claimRewards() external {
        uint256 amt = pendingOf[msg.sender];
        pendingOf[msg.sender] = 0;
        if (amt > 0) STEP.safeTransfer(msg.sender, amt);
    }

    // ─── Test helpers ────────────────────────────────────────────────────────
    function mint(address to, uint256 id) external {
        _owners[id] = to;
    }

    function setNextBuyId(uint256 id) external {
        nextBuyId = id;
    }

    function creditReward(address who, uint256 amount) external {
        pendingOf[who] += amount;
    }
}
