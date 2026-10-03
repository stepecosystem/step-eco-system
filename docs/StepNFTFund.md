# StepNFTFund — Deep Dive

> Source: [`contracts/StepNFTFund.sol`](../contracts/StepNFTFund.sol) · 1,459 lines · `Ownable`, `ReentrancyGuard`
> Live: [`0xaA739Ce109C72f775212Ed5fd1177120d295b26f`](https://polygonscan.com/address/0xaA739Ce109C72f775212Ed5fd1177120d295b26f) · Polygon mainnet · registered in StepRegistry under `NFT_FUND`
> Tests: [`contracts-test/test/08-nft-fund.test.js`](../contracts-test/test/08-nft-fund.test.js)

StepNFTFund is the custodian of the **20 % slice** that [StepSubscription](StepSubscription.md) routes on every payment. It gives the [StepNFTTreasury](StepNFTTreasury.md) collection two things it did not have: a **buy-back desk** that guarantees holders an exit, and a **daily yield** for the upper tiers.

---

## Two vaults that are never netted

Every STEP that arrives through `depositSplit` is divided by `saleShareBps` (default **5000 = 50 / 50**) into two strictly separated balances:

| Vault | Purpose | Funded by |
|---|---|---|
| **Sale vault** (`saleVaultStep`) | pays holders who sell an NFT back | its share of deposits, `donateToSaleVault`, and re-sale top-ups |
| **Yield vault** (`yieldVaultStep`) | daily reward to NFTs priced ≥ 400 DAI | its share of deposits, `donateToYieldVault`, and rewards swept from the original collection |

The contract never spends one vault on the other. `vaultBalances()` exposes both, the distributed-but-unclaimed liability, the actual STEP balance and any surplus — and the test suite checks after every scenario that **balance = sale + yield + pending, to the wei**.

---

## The buy-back desk

### Selling back — `sellToFund(tokenId, minStepOut)`

- A holder sells an NFT for **50 % of its current price** — its mint-curve price, or the higher tier this contract last re-sold it at.
- The NFT is taken into custody **immediately** and **re-listed at the day price** (the price the collection is minting at right now), so it is buyable even while the payout is pending.
- The payout is priced in STEP at the spot rate **when it clears**, not when it was requested.
- If the sale vault cannot cover it, the order waits in a **strict FIFO queue**; a later order can never jump an earlier one. Deposits automatically try to settle the head of the queue, and anyone can call `settleQueue(n)`.
- A seller whose order is still unpaid can `cancelSellOrder` and take the NFT back. Once paid, the sale is final.

The collection charges its own **10 % DAI transfer levy** (on the mint price) to the sending side of every move; `quoteSellback` and `cancelFeeDai` report exactly what must be approved.

### Re-selling listed NFTs — `buyListed(tokenId, maxPriceDai)`

A listed NFT sells at the **day price**, regardless of the id it was minted under. The buyer's DAI is applied in three steps:

1. the collection's transfer levy is carved out;
2. the rest is converted to STEP, and whatever the sale vault is **short of paying the first outstanding order** is moved into the vault, which then settles that one order;
3. everything left is split **90 / 10** across the same two wallets a fresh mint pays.

Worked example: a 400-DAI NFT was sold to the desk, so its seller is owed 200 DAI; the vault holds 50 DAI; the day price is 800.

```
  800  price the buyer pays
 - 40  transfer levy (10 % of the 400-DAI mint price)
 -150  into the vault, taking it 50 → 200 and clearing the order
 ─────
  610  split 90 / 10  →  549 + 61
```

`quoteBuyListed` returns this breakdown before the transaction.


### Tier promotion

A re-sold NFT **joins the tier it re-sold at** (`tierOf`). A low-id token re-sold at 400 DAI or more is enrolled in the yield split for good (`promotedTokens`), so the id it was minted under never holds it back.

---

## The yield vault

`distributeYield()` — callable by anyone, at most once per **24 hours**:

- **Eligibility:** every minted id ≥ 301 (the 400-DAI tier and up), plus promoted tokens, **minus tokens held in the fund's own custody** (they earn nothing).
- **Even split:** the vault is divided equally per eligible NFT; indivisible dust rolls into the next round.
- **Resumable:** ids are credited in batches of 400 with a persisted cursor, so a round can never be too large to finish. While a round is open, custody changes are refused so the snapshotted eligible count stays exact.
- **Honest liabilities:** only what was actually credited to a live holder becomes a liability; shares for ids with no owner return to the vault.
- **Claim window:** holders `claimYield()` within **30 days**; anything older is burned rather than paid — the same rule as StepNFTTreasury.

`claimTreasuryRewards()` sweeps whatever the original collection has credited to the fund (for tokens in its custody) into the yield vault, so those rewards reach holders instead of expiring.

---

## Administration and migration

| Path | Who | What |
|---|---|---|
| `setSaleShareBps(bps)` | owner | change how **future** deposits divide between the vaults (≤ 100 %) |
| `migrateAssetsTo(newContract)` | **StepRegistry only** — i.e. a passed DAO migration proposal (vote → veto window → timelock) | move both balances to a successor and retire this contract |
| `migrateEscrowedNFTs(n)` | anyone, after a migration | forward custodied NFTs to the successor in bounded batches |

The owner has **no path to move vault funds or custodied NFTs**. After a migration the contract stops taking deposits (they are forwarded), stops buying back, stops distributing and stops paying claims, so its ledger always describes exactly the balances that moved.

---

## Security rationale recap

- **Strictly separated vaults** with a balance that reconciles to the wei.
- **Strict FIFO** buy-back queue, settled at clearing-time prices; unpaid sellers can always withdraw.
- **Resumable, gas-bounded** distribution; custody frozen while a round is open.
- **Anti-sandwich floor** (95 % of a live quote) on every DAI → STEP conversion; price caps for buyers (`maxPriceDai`) and payout floors for sellers (`minStepOut`).
- **DAO-gated migration** as the only way value can leave other than through the documented flows.
- **`nonReentrant`** on every value-moving entry point; custom errors throughout.
