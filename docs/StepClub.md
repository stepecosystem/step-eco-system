# StepClub — Deep Dive

> Source: [`contracts/StepClub.sol`](../contracts/StepClub.sol) · 1,093 lines · `ReentrancyGuard`

StepClub is the loyalty layer. Activating box 2 or higher in `StepNet` enrolls a subscriber, and the Club runs its own reward pool and distribution cycle on top of the core network.

---

## Membership lifecycle

- **Join** — `addMember` (called only by StepNet, `onlyStepNet`) enrolls a user; joins are processed through a **join queue** (`_flushJoinQueue` / `flushJoinQueueManual`) so a burst of new members is handled in bounded batches.
- **Leave** — `removeMember` (also `onlyStepNet`) and an internal removal queue (`_flushRemovalQueue` / `flushRemovalQueueManual`) handle exits the same way.
- **Transfer** — `transferMembership` moves club state when a user migrates wallets, keeping it consistent with StepNet's `changeWallet`.
- **Import** — `importMember` seeds prior members during the migration window.

Every queue is **drained in bounded chunks**, never all-at-once, so membership churn can never exceed the gas limit.

---

## The reward pool

The pool is fed by:
- the **5% Club slice** on every box activation in StepNet (`receiveForPool`),
- direct donations (`donateToPool`),
- DEX-routed deposits (`notifyStepClubDeposit`).

Rewards accrue in STEP and are distributed through `processClubDistribution`, again a **bounded, resumable batch routine** (`_processBatch`) — the same anti-grief state-machine pattern used by the core engine.

---

## Auto-exit at cap

A distinctive feature: when a member reaches a defined cap, they are **gracefully exited** rather than left to accrue indefinitely.

- `checkAndExitIfAtCap` / `checkAndExitIfAtCapBatch` / `_doCheckAndExitIfAtCap` detect the condition.
- On exit, the member is **credited with AI-subscription time** via `StepSubscription.grantFromClubExit(user, gapDai)` — so loyalty converts into utility instead of simply ending.

This ties the Club back into the broader ecosystem: leaving the Club is not a dead end, it is a hand-off to the subscription layer.

---

## Pending-reward hygiene

`_burnPending` / `_drainExpiringPending` / `sweepExpiredPending` ensure that unclaimed/expiring rewards are handled deterministically and don't accumulate as dead weight — and, like everything else, the sweep is bounded per call.

---

## Security rationale recap

- **Privileged enrol/remove gated** to StepNet (`onlyStepNet`) — users can't self-inject into the club outside the network rules.
- **Every queue and distribution is bounded/resumable** — no gas-limit griefing.
- **Reentrancy-guarded** on all external value paths.
- **Graceful exit** converts capped membership into subscription credit rather than stranding value.
