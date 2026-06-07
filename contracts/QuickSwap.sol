// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory);
}

/**
 * @title  QuickSwap
 * @notice Single-transaction, drop-in router for the dApp's DAI<->POL swap.
 *
 *         It exposes the SAME three function signatures the UI already calls on
 *         a Uniswap-V2 router (`getAmountsOut`, `swapExactTokensForETH`,
 *         `swapExactETHForTokens`), so pointing the frontend's SWAP_ROUTER at
 *         this address is a zero-code-change swap — the wallet shows the exact
 *         same familiar function names and the user signs ONE transaction, just
 *         like today.
 *
 *         On each swap it skims a small, capped fee (`feeBps`) of the INPUT to
 *         `feeRecipient`, forwards the remainder to the real QuickSwap V2 router,
 *         and the router delivers the output STRAIGHT to the user. The fee is
 *         simply reflected in the quoted rate (getAmountsOut returns the
 *         post-fee figure), so there is no separate "fee" step and no transfer
 *         to an unfamiliar address for the user to approve.
 *
 *         Safety:
 *           • `MAX_FEE_BPS = 300` (3%) is an immutable hard cap.
 *           • `nonReentrant` on both swap paths.
 *           • Holds no funds between calls; `rescue*` only recovers accidental
 *             transfers.
 *           • Underlying ROUTER is immutable; only feeRecipient / feeBps /
 *             ownership are mutable, all owner-gated.
 */
contract QuickSwap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public owner;
    address public feeRecipient;               // where the platform fee goes
    uint256 public feeBps;                      // 50 = 0.5%
    uint256 public constant MAX_FEE_BPS = 300;  // 3% hard ceiling — immutable
    uint256 private constant BPS = 10_000;

    IV2Router public immutable ROUTER;          // real QuickSwap V2 router

    event FeeRecipientUpdated(address indexed feeRecipient);
    event FeeBpsUpdated(uint256 feeBps);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error FeeTooHigh();
    error ZeroAddress();
    error ZeroAmount();
    error NativeTransferFailed();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(address router, address feeRecipient_, uint256 feeBps_) {
        if (router == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        owner        = msg.sender;
        ROUTER       = IV2Router(router);
        feeRecipient = feeRecipient_;
        feeBps       = feeBps_;
    }

    // ─── Quote (post-fee) — identical signature to the V2 router ─────────────────
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory)
    {
        uint256 swapAmt = amountIn - (amountIn * feeBps) / BPS;
        return ROUTER.getAmountsOut(swapAmt, path);
    }

    // ─── DAI -> POL. Caller approves path[0] (DAI) to this contract. ─────────────
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external nonReentrant returns (uint256[] memory amounts)
    {
        if (amountIn == 0) revert ZeroAmount();
        IERC20 tokenIn = IERC20(path[0]);
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 fee = (amountIn * feeBps) / BPS;
        if (fee > 0) tokenIn.safeTransfer(feeRecipient, fee);
        uint256 swapAmt = amountIn - fee;

        tokenIn.forceApprove(address(ROUTER), swapAmt);
        // Output (POL) is sent straight to `to` by the underlying router.
        amounts = ROUTER.swapExactTokensForETH(swapAmt, amountOutMin, path, to, deadline);
    }

    // ─── POL -> DAI. Send POL as msg.value. ─────────────────────────────────────
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external payable nonReentrant returns (uint256[] memory amounts)
    {
        if (msg.value == 0) revert ZeroAmount();
        uint256 fee = (msg.value * feeBps) / BPS;
        if (fee > 0) {
            (bool ok, ) = feeRecipient.call{value: fee}("");
            if (!ok) revert NativeTransferFailed();
        }
        uint256 swapAmt = msg.value - fee;
        // Output (DAI) is sent straight to `to` by the underlying router.
        amounts = ROUTER.swapExactETHForTokens{value: swapAmt}(amountOutMin, path, to, deadline);
    }

    // ─── Admin: settable recipient + fee (capped) ───────────────────────────────
    function setFeeRecipient(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        feeRecipient = r;
        emit FeeRecipientUpdated(r);
    }

    function setFeeBps(uint256 b) external onlyOwner {
        if (b > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = b;
        emit FeeBpsUpdated(b);
    }

    function transferOwnership(address n) external onlyOwner {
        if (n == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, n);
        owner = n;
    }

    // ─── Rescue (accidental transfers only — no funds held between calls) ────────
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueNative(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    receive() external payable {}
}
