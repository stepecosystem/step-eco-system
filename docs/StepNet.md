# StepNet — Deep Dive

> Source: [`contracts/StepNet.sol`](../contracts/StepNet.sol) · 1,353 lines · `ReentrancyGuard`

StepNet is the heart of the ecosystem: it sells subscription **boxes**, maintains the **binary referral graph**, and runs the **daily distribution** that routes subscription revenue back to active subscribers. It is the single source of truth for who owns which tier — off-chain AI/digital services authenticate users by reading this contract.

---

## 1. Subscription boxes

```solidity
function _boxPrice(uint8 id) private pure returns (uint256) {
    if (id == 0) return 25 ether;   // 25 DAI
    if (id == 1) return 75 ether;
    if (id == 2) return 100 ether;
    if (id == 3) return 300 ether;
    if (id == 4) return 500 ether;
    return 1000 ether;              // box 5
}
```

A user activates boxes in order (`activateBox`, `activateNextBoxManually`, and `…For` variants that let a sponsor activate on behalf of a user). Box 0 is the network entry point **and** the unit of DAO voting power.

### Where the money goes — `_activateBoxInternal`

```
 5%  → subscriber        (in STEP)
 5%  → dev treasury       (in STEP)
 3%  → NFT reward pool    (in STEP)
 5%  → Club pool          (in STEP)
─────  18% bought as STEP via the bonding curve (slippage-protected)
82%  → retained as DAI in pools[boxId].accumulatedDai  (the daily redistribution pool)
```

The 18% STEP purchase is wrapped in a tight `forceApprove → buyStep → forceApprove(0)` pattern with `minStepOut` from `_calcMinStepOut` — approval is granted for exactly the spend and immediately zeroed, and the buy is slippage-protected.

---

## 2. The binary graph

Each user has one `upline` and up to two children (`left`, `right`). On activation, the referrer link is set once and is immutable thereafter. Then `PendingLib.propagate` walks **up** the tree, advancing two independent sets of counters:

1. **Daily team points** — consumed by the rewards model each cycle.
2. **Permanent Box-0 subtree counters** (`box0LeftSubtree` / `box0RightSubtree`) — *never* consumed; used by the DAO to compute voting weight as `1 + min(left, right)`.

Because the propagation walk can be long, an **immediate window** (`IMMEDIATE_UPDATE_LEVELS = 70`) is processed inline and any remainder is queued in `pendingUpdates` to be drained by bounded batches — so a single activation deep in a large tree can never run out of gas.

---

## 3. The daily distribution — `processDaily()`

This is the most security-critical routine in the system, and it is built as a **resumable, gas-bounded state machine** rather than a single loop.

```
globalCycleStep:
  0       → ready (TooEarly interval guard)
  1       → flush pendingUpdates across all boxes
  2..7    → process box 0..5, one bounded batch of users per call
  8       → cycle complete; advance pools[*].lastDistributionTime
```

### Why a state machine?

A single loop over thousands of subscribers would eventually exceed the block gas limit and **permanently brick distributions**. By advancing a cursor a bounded batch at a time, the routine:

- can be completed across multiple transactions/blocks,
- **cannot be forced to the gas limit** by a malicious actor inflating any set,
- is **idempotent** — the `TooEarly` guard makes a redundant call a safe no-op,
- is **permissionless** — anyone can drive it; a keeper bot does so on schedule but the protocol never depends on a single caller.

### Touched-set, not full-set

The routine iterates only `dirtyUsers[boxId]` — the uplines whose team counters actually changed since that tier last distributed — never the entire subscriber base. This is **exact, not approximate**: any subscriber not in the set provably had no change to account for.

### Per-cycle price snapshot

STEP price is locked once at cycle start (`cycleStepPriceSnapshot`) and used for the whole cycle. Everyone in a round is therefore priced identically, which removes any timing/MEV advantage from being first or last in the batch.

### Reward weighting

A subscriber's daily reward is weighted by the **weaker side** of their team (`_weaker(left, right)`), the classic anti-gaming structure that rewards balanced network building rather than one-sided stacking.

---

## 4. Auto-upgrade reserve

```solidity
uint256 reserve = (dai_ * UPGRADE_RESERVE_PCT) / 100;   // 10%
u.reservedForUpgrade += reserve;
```

10% of each daily reward is set aside toward the user's next box. `processAutoUpgrades` later promotes users whose reserve has reached the next tier's price (`_executeAutoUpgrade`, bounded by `MAX_UPGRADES_PER_CALL`). Reserves left unused for `RESERVE_BURN_INTERVAL = 90 days` are burned back to liquidity by `processExpiredReserves`, which is bounded per call (`reserveBurnCursor` + `MAX_RESERVE_BATCH = 100`) so a deep ticket queue cannot stall the daily routine.

> **Implementation note:** the reserve-burn routine tracks a cursor so a full pass over all users completes in a predictable number of bounded calls and then stops — it does not re-scan endlessly.

---

## 5. Wallet migration & membership transfer

`changeWallet` lets a user move their entire position (boxes, reserves, tree links, club state) to a fresh address. Because rewriting all of that on-chain is heavy, the implementation is delegated to `WalletLib` via `DELEGATECALL` — this keeps StepNet's own bytecode under the **EIP-170 24KB limit** while preserving storage layout. O(1) reverse-indexes (`pendingUpdateIndex`, `pendingUpgradeIndex`) make removals during migration constant-time even at large scale.

---

## 6. One-time import window

`importSingleUser` / the `StepNetImporter` exist to migrate the prior generation of users into this deployment, gated by `onlyImporter` and an `IMPORT_WINDOW = 2 days` from deploy. After the window, the import path is closed — there is no permanent privileged user-creation route.

---

## 7. Club & registry wiring

StepNet resolves all peers (`_step`, `_dex`, `_nft`, `_dev`, `_club`) through the registry, so any of them can be governance-upgraded without touching StepNet. Activating box ≥ 2 enrolls the user in the Club (`_addToClub`); the club exit path (`_checkAndExitClub`) keeps the two contracts consistent.

---

## Security rationale recap

| Property | How |
|---|---|
| Can't brick distribution | Cursor-based, bounded-batch, resumable `processDaily` |
| Can't grief with gas | Touched-set iteration + per-call batch caps everywhere |
| Can't MEV the round | Per-cycle STEP price snapshot |
| Can't sandwich internal buys | `minStepOut` from live quote, 95% floor |
| Can't game the network | Weaker-leg reward weighting |
| Can't reenter | `ReentrancyGuard` on every value-moving entry-point |
| Can't create users forever | Import path closes after a 2-day window |
| Fits on-chain | Heavy logic delegated to libraries to stay under EIP-170 |
