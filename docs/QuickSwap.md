# QuickSwap — Deep Dive

> Source: [`contracts/QuickSwap.sol`](../contracts/QuickSwap.sol) · 144 lines · `ReentrancyGuard`

QuickSwap is a thin, fee-capped wrapper around the **QuickSwap V2 (Uniswap V2-style) router**. It lets the dApp offer native ⇄ token swaps (e.g. POL ⇄ DAI) through a single, auditable entry point with a transparent platform fee.

---

## What it does

It forwards three router operations:
- `getAmountsOut` — quote a swap.
- `swapExactTokensForETH` — token → native.
- `swapExactETHForTokens` — native → token.

On each swap it takes a platform fee, routed to `feeRecipient`, then passes the user's funds to the underlying router with their `amountOutMin` (slippage protection preserved end-to-end) and `deadline`.

---

## The fee is capped in code

```solidity
uint256 public constant MAX_FEE_BPS = 300;  // 3% hard ceiling — immutable
```

`setFeeBps` reverts with `FeeTooHigh` for anything above 300 bps. This is the key trust property: the owner can tune the fee within a band, but **can never set a confiscatory fee** — the 3% ceiling is a compile-time constant, not a setting.

---

## Owner surface

`onlyOwner` covers `setFeeRecipient`, `setFeeBps` (capped), `transferOwnership`, and rescue functions (`rescueToken`, `rescueNative`) for funds accidentally sent to the contract. The rescue functions exist so stuck assets aren't lost forever; they do not give the owner a claim on funds that are mid-swap (those pass straight through with the user's `amountOutMin`).

---

## Security rationale recap

- **Hard fee ceiling** (`MAX_FEE_BPS = 300`, immutable) — no rug via fee.
- **Slippage preserved** — user's `amountOutMin` and `deadline` forwarded to the router unchanged.
- **Reentrancy-guarded** swaps.
- **Native transfer checked** — `NativeTransferFailed` on a failed POL send, so failures revert cleanly rather than silently losing funds.
- **Thin by design** — minimal surface area; it delegates the actual AMM math to the battle-tested QuickSwap router.
