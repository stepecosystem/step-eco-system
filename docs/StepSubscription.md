# StepSubscription — Deep Dive

> Source: [`contracts/StepSubscription.sol`](../contracts/StepSubscription.sol) · 556 lines · `ReentrancyGuard`
> Live: [`0x8B567B997B5e80840228D047C8796234992E667C`](https://polygonscan.com/address/0x8B567B997B5e80840228D047C8796234992E667C) · Polygon mainnet
> Tests: [`contracts-test/test/05-subscription.test.js`](../contracts-test/test/05-subscription.test.js)

StepSubscription is the **revenue conduit** for every subscription the ecosystem sells, including access to the AI products ([`AI-Products.md`](AI-Products.md)).

---

## Design: a conduit, not a vault

The contract **custodies nothing**. Every unit of value that enters leaves in the same transaction, in STEP, split on a fixed schedule:

| Share | Destination | How it is paid |
|---:|---|---|
| 19 % | development wallet | transfer |
| 51 % | owner wallet | transfer — also absorbs rounding dust, so the split is exhaustive |
| 10 % | StepClub live pool | approve + `donateToPool` (the club pulls) |
| 20 % | [StepNFTFund](StepNFTFund.md) | approve + `depositSplit` (the fund pulls) |

DAI payments are converted to STEP on [StepDex](StepDex.md) inside the same call, with a **95 % minimum-output floor** taken from a live quote, before the split. A test asserts the conduit's STEP balance is exactly zero after every payment.

`_splitStep` reverts with `NotInitialized` if either the club or the fund is unset, so revenue can never be stranded on the contract during wiring.

---

## Two ways to pay

### 1. Priced off-chain, receipted on-chain — `payDai` / `payStep`

```solidity
function payDai(uint256 amount, bytes32 ref) external;
function payStep(uint256 amount, bytes32 ref) external;
event Payment(address indexed payer, bytes32 indexed ref, address indexed token, uint256 amountIn, uint256 stepRouted);
```

The application quotes a price, the user pays it here with a `ref` identifying what was bought (plan, invoice, order hash), and the `Payment` event is the receipt the application credits. **Changing a price is a configuration change, not a transaction** — the contract never has to be redeployed to reprice anything. `depositDai` / `depositStep` route value with no reference, and `flush()` (callable by anyone) splits anything left idle on the contract.

### 2. Self-serve on-chain plans — `subscribe` / `subscribeWithDai`

A wallet can buy one of four plans directly from the contract with no backend involved; the months land in `paidExpiry` in the same transaction.

| Plan | Length | Price per month | Total (DAI) |
|---:|---:|---:|---:|
| 0 | 1 month | 6.99 | 6.99 |
| 1 | 3 months | 5.99 | 17.97 |
| 2 | 6 months | 4.99 | 29.94 |
| 3 | 12 months | 3.99 | 47.88 |

- `quote(plan)` returns the DAI price and the STEP equivalent at the live spot price; `subscribe(plan, maxStep)` enforces `maxStep` as a slippage guard.
- Purchases **extend** from the later of *now* and the current expiry, so buying early never burns time already held.
- `accessStatus(wallet) → (active, paidEnd)` is the on-chain answer to *"is this wallet's access live?"*.

---

## Club exits become subscription time

```solidity
function grantFromClubExit(address user, uint256 gapDai) external returns (uint32 monthsGranted);
```

Callable **only** by `clubAuthority` (StepClub). `monthsForGap` converts the forfeited cap-gap into whole months greedily, longest plan first; a gap too small to buy a month grants nothing and does not revert.

---

## Built-in guarantees

- **The split is a constant.** 19 / 51 / 10 / 20 is fixed at compile time and exhaustive — no setting can change it.
- **Nothing to withdraw.** The contract never holds a balance; every payment leaves in the transaction that brought it.
- **Access only grows.** Every purchase or grant extends from the later of *now* and the current expiry.
- **Club exits are trustless.** Only StepClub can call `grantFromClubExit`, atomically inside its own exit flow.

### Operational settings

Receiver addresses (`setDevWallet`, `setOwnerWallet`, `setNftFund`), the club authority, an optional low-privilege `granter` for recording access bought through `payDai` / `payStep`, and the plan denominations (`setPlan`) are restricted to the contract owner. Every change emits an event, so it is publicly visible on-chain the moment it happens, and [`contracts-src/verify-onchain.js`](../contracts-src/verify-onchain.js) prints the live configuration.

---

## Security rationale recap

- **Exhaustive, constant split** — 19/51/10/20 can never drift, and no dust is left behind.
- **Pull-based legs** for the club and the fund, approved for the exact amount and reset to zero afterwards.
- **Levy-aware accounting** — STEP credits are measured as balance deltas, because a non-whitelisted transfer burns 2 %.
- **Anti-sandwich floor** (95 % of a live quote) on every DAI → STEP conversion.
- **Slippage guard** on STEP-priced plans; **additive expiry** on every purchase or grant.
- **`nonReentrant`** on every value-moving entry point; custom errors throughout.
