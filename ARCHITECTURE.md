# Architecture & Economic Design

This document explains *how* Step Eco System works as a whole — the value flow, the binary network, the distribution engine, the governance model, and the security guarantees that tie the deployed contracts together. For a line-by-line walkthrough of any single contract, see its file in [`/docs`](docs/).

---

## 1. The Address Book: `StepRegistry`

Every contract in the system is **stateless about its peers**. Instead of hard-coding the address of, say, the DEX, each contract asks the `StepRegistry`:

```solidity
function _dex() internal view returns (IStepDex) {
    return IStepDex(REGISTRY.get(REGISTRY.KEY_STEP_DEX()));
}
```

This single indirection is the backbone of the security model. It means a contract can be *replaced* (e.g. to fix a bug or add a feature) **without redeploying the whole system** — but only through governance. The registry starts in a bootstrap phase controlled by a deployer, and then `activateDao()` permanently hands control to the DAO. After that, **the only way to change any address is a passed proposal**.

A registry pointer change requires:
1. **A proposal** (`createProposal`), votable by Box-0 holders.
2. **A vote** that crosses a dynamic threshold scaled to the live Box-0 population.
3. **A veto window** during which the deployer-controller can block a malicious proposal — and then later renounce even that.
4. **A timelock** before execution.

There is no `onlyOwner setEverything()` anywhere in the system. This is the property that lets the project credibly say: *no backdoor*.

---

## 2. The Token: `StepCoin` + `StepDex`

STEP is **not** a free-floating speculative token. Its price is a deterministic function of collateral:

```
price = daiReserve / circulatingSupply
```

- **Minting** happens *only* through the `StepDex` bonding curve, and every mint is backed by DAI deposited into the reserve. New STEP cannot appear without new DAI behind it.
- **Selling** STEP back through the DEX burns it and returns DAI from the reserve.
- A **2% levy** is burned on every ordinary transfer, and up to two addresses can be exempted only through a DAO proposal. Contracts that receive STEP credit what actually *arrives* (balance deltas), so internal accounting stays exact. Combined with the bonding curve, supply trends deflationary.
- A **price floor** mechanism in `StepDex` protects holders from a reserve/supply imbalance driving price to zero.

Because price is reserve ÷ supply, **there is no oracle to manipulate** and no way to "print" unbacked tokens. See [`docs/StepCoin.md`](docs/StepCoin.md) and [`docs/StepDex.md`](docs/StepDex.md).

---

## 3. The Core Engine: `StepNet`

### 3.1 Subscription "Boxes"

A user activates **boxes** 0 → 5, each a paid access tier:

| Box | Price (DAI) |
|---:|---:|
| 0 | 25 |
| 1 | 75 |
| 2 | 100 |
| 3 | 300 |
| 4 | 500 |
| 5 | 1,000 |

Box activations also include access time to the ecosystem's AI products (see [`docs/AI-Products.md`](docs/AI-Products.md)). Box 0 is special: it is the unit of **governance voting power** and the entry to the network.

### 3.2 Where each payment goes

When a box is activated for `paid` DAI, the split is an **immutable constant**:

```
 5%  → subscriber        (paid out in STEP)
 5%  → dev treasury       (paid out in STEP)
 3%  → NFT reward pool    (paid out in STEP)
 5%  → Club pool          (paid out in STEP)
─────
18%  → converted to STEP via the bonding curve (slippage-protected)
82%  → retained as DAI in that box tier's daily redistribution pool
```

The 82% is what flows back to active subscribers through the daily cycle.

### 3.3 The Binary Network

Every subscriber has exactly **one upline** and at most **two children** (left / right) — a strict binary tree. Daily rewards are weighted by the **weaker side** of a subscriber's team:

```
reward weight ∝ min(leftTeamActivity, rightTeamActivity)
```

This "weaker-leg" model is the classic anti-gaming structure: you are rewarded for *balanced* network building, not for stacking everyone on one side.

For governance, a **permanent, separate counter** tracks Box-0 subtree size on each side, and voting power is:

```
voting weight = 1 + min(box0LeftSubtree, box0RightSubtree)
```

Crucially, these DAO counters are **preserved across distributions**, whereas the day-to-day team points are intentionally consumed by the rewards model. The two counters serve different purposes and never interfere.

### 3.4 The Daily Distribution — a gas-bounded state machine

The naïve way to distribute to thousands of users is a single loop — which would eventually exceed the block gas limit and **brick the protocol**. Step Eco System instead implements `processDaily()` as a **resumable cursor machine**:

```
globalCycleStep:
  0  → ready / TooEarly guard
  1  → flush queued tree updates for all boxes
  2..7 → process box 0..5  (one batch of users per call)
  8  → cycle complete
```

Each call advances the cursor by a bounded batch. Key properties:

- **Touched-set iteration.** The routine iterates only `dirtyUsers[boxId]` — uplines whose team counters actually changed — never the full subscriber base. This is *exact*, not approximate.
- **Price snapshot.** STEP price is locked for the entire cycle (`cycleStepPriceSnapshot`) so everyone in a round is priced identically — neutralizing MEV/timing games.
- **Permissionless & idempotent.** Anyone can call it; on-chain `TooEarly` interval guards make a double-call a safe no-op. A keeper bot calls it on schedule, but the protocol does not *depend* on any single caller.
- **Auto-upgrade reserve.** 10% of a subscriber's daily reward is reserved toward their next box. If unused within 90 days, it is burned back to liquidity (`processExpiredReserves`) — bounded per call so no one can stall the routine with a deep ticket queue.

See [`docs/StepNet.md`](docs/StepNet.md) and [`docs/StepNetLib.md`](docs/StepNetLib.md) for the internals.

---

## 4. Loyalty: `StepClub`

Activating box 2 or higher enrolls a subscriber in the **Club** — a loyalty layer with its own STEP pool (fed by the 5% club slice on every activation). The Club runs its own batched distribution cycle, an auto-exit mechanism (a member who reaches a cap is gracefully removed and credited via `StepSubscription.grantFromClubExit`), and removal/join queues that are flushed in bounded batches — same anti-grief philosophy as the core engine. See [`docs/StepClub.md`](docs/StepClub.md).

---

## 5. The NFT Treasury: `StepNFTTreasury`

A tiered ERC-721 collection (Bronze → Gold and beyond). It holds an on-chain **STEP reward pool** (fed by the 3% NFT slice + direct donations) and distributes to holders on an interval, again via a bounded, resumable routine. It also supports **one-way migration** of legacy NFTs (only the eligible $100 / $200 tiers, capped by a migration snapshot) into the new treasury. See [`docs/StepNFTTreasury.md`](docs/StepNFTTreasury.md).

---

## 6. Subscriptions: `StepSubscription`

Subscriptions — including access to the AI products — are paid to **`StepSubscription`**, a conduit that custodies nothing. Every payment, in DAI or STEP, is converted to STEP and split in the same transaction:

```
19%  → development wallet
51%  → owner wallet          (absorbs rounding dust, so the split is exhaustive)
10%  → StepClub live pool    (pulled by the club)
20%  → StepNFTFund           (pulled by the fund)
```

Prices can be quoted by the application and receipted on-chain (`payDai` / `payStep` with a `ref`, emitting `Payment`), or bought directly from four on-chain plans (`subscribe` / `subscribeWithDai`, 1/3/6/12 months at 6.99/5.99/4.99/3.99 DAI per month). See [`docs/StepSubscription.md`](docs/StepSubscription.md) and [`docs/AI-Products.md`](docs/AI-Products.md).

---

## 7. The NFT Fund: `StepNFTFund`

The 20% subscription slice lands in **`StepNFTFund`**, which holds two vaults that are never netted against each other:

- a **sale vault** — a buy-back desk where a holder can sell an NFT for 50% of its current price. The NFT is re-listed at the collection's day price immediately; payouts that the vault cannot cover yet wait in a strict FIFO queue, and a re-sale tops the vault up for the head of that queue before splitting the rest 90/10 like a primary mint;
- a **yield vault** — a daily, resumable, gas-bounded distribution that pays NFTs priced at 400 DAI or more evenly per NFT, with the same 30-day claim-or-burn window as the treasury.

The owner can only retune how future deposits divide between the vaults; moving the funds requires a DAO migration through `StepRegistry`. See [`docs/StepNFTFund.md`](docs/StepNFTFund.md).

---

## 8. Read Layer: `StepNetView`

`StepNetView` holds **no state and moves no value**. It exists purely to pack the many small reads a dApp needs — dashboards, timers, stats, leaderboards — into single aggregated calls, so the frontend stays fast and RPC-cheap. Keeping it separate from `StepNet` also keeps the core engine's bytecode under the EIP-170 size limit. See [`docs/StepNetView.md`](docs/StepNetView.md).

---

## 9. Why this is hard to attack

| Threat | Mitigation |
|---|---|
| Admin rug / treasury theft | No owner key over funds; every move is DAO vote + veto + timelock |
| Oracle manipulation | STEP price = reserve ÷ supply; no external feed exists |
| Reentrancy | `ReentrancyGuard` on every value-moving entry-point |
| Gas-limit griefing of distribution | Cursor-based, bounded-batch, resumable state machines everywhere |
| Sandwich / MEV on internal buys | `minStepOut` from live quote (95% floor) + per-cycle price snapshot |
| One-sided network gaming | Weaker-leg reward weighting |
| Unbacked token inflation | Mint authority restricted to the DEX, each mint DAI-backed |
| Revenue stranded mid-split | Subscription split is exhaustive and reverts (`NotInitialized`) until every destination is wired |
| Buy-back queue-jumping | Strict FIFO settlement; payouts priced when they clear, not when requested |

---

## 10. Hard guarantees — what no one can change

Beyond the DAO, the most important protections are written into the code itself, where no key — the controller's included — can reach them:

| Module | Guaranteed by the code |
|---|---|
| Core (`StepRegistry`, `StepCoin`, `StepDex`, `StepNet`) | Every address change passes a DAO vote, a veto window and a timelock; STEP is minted only through the DEX against DAI; reward splits and the distribution cadence are constants |
| `StepSubscription` | The 19 / 51 / 10 / 20 split is a compile-time constant and exhaustive; the contract never holds a balance, so there is nothing to withdraw |
| `StepNFTFund` | Sale-vault and yield-vault funds, and every NFT in custody, can move only through a DAO migration (vote → veto window → timelock) |
| `StepNFTTreasury` | The reward pool can move only through a DAO migration, and no key can transfer a holder's NFT |

Operational settings — receiver addresses, plan denominations, the vault split for future deposits, metadata — emit an on-chain event on every change, so each one is publicly visible the moment it happens. `node contracts-src/verify-onchain.js` prints the live configuration of every module.

---

## 11. Deployment

`scripts/deploy.js` performs a full bring-up of the system: it deploys the libraries, the registry, the token, the DEX, the core engine, the view, the NFT treasury, the subscription conduit, the club and the NFT fund, wires every address into the registry (the fund under `NFT_FUND`), and connects the subscription split to the club and the fund. It deliberately stops before `finalizeSetup()`, which runs after the user import; the DAO is then activated on-chain by the controller with `activateDao()`. The deployer's key is loaded from the environment (`PRIVATE_KEY`) and is **never** committed to this repository.

---

<div align="center">

For the contract-by-contract deep dives, head to **[`/docs`](docs/)**.

</div>
