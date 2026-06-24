# StepNetLib — Deep Dive

> Source: [`contracts/StepNetLib.sol`](../contracts/StepNetLib.sol) · 909 lines

StepNetLib is not a single contract but a **collection of libraries** plus the shared `User` / `ImportUserData` struct definitions. It exists for two reasons:

1. **EIP-170.** StepNet's logic is far larger than the 24KB contract size limit. Moving heavy routines into libraries (linked or `DELEGATECALL`ed) keeps the deployed core under the cap.
2. **Reuse & isolation.** Each concern lives in its own library with a single responsibility, which makes the core engine readable and each piece independently auditable.

---

## Shared types

- **`User`** — the full per-subscriber record: tree links (`upline`/`left`/`right`), per-box purchase counts and paid totals, `reservedForUpgrade`, club state, timestamps. Defined at file scope so `WalletLib` can operate on storage refs without redeclaring the type.
- **`ImportUserData`** — the calldata shape used by the one-time importer.

---

## The libraries

### `ReserveLib` — auto-upgrade ticket queue
Manages each user's queue of `ReserveTicket { amount, addedAt }`.
- `compact` / `_compact` — collapse consumed tickets so the queue stays small.
- `burnExpired` — burn tickets past the 90-day lifetime, **bounded per call** so the daily routine can never be stalled by a long queue.
- `consume` — spend reserve toward an upgrade.

### `WalletLib` — address migration
Implements `changeWallet` — moving a user's entire position to a new address. Called from StepNet via `DELEGATECALL` so it executes in StepNet's storage context while keeping the core bytecode small.

### `PendingLib` — the tree & distribution core
The busiest library.
- `propagate` — the up-the-tree walk that advances both daily team counters **and** the permanent Box-0 DAO counters in one pass, populating the touched-set (`dirtyUsers`).
- `processBatch` — drains queued `pendingUpdates` in bounded chunks.
- `distPhase0` — phase 0 of the daily cycle.
- `markPendingUpgrade` / `markDirty` / `clearDirtyBox` — the bookkeeping that makes touched-set distribution exact and gas-bounded.
- `rebuildBox0SubtreeBatch` — reconstructs the permanent subtree counters (used during import) in bounded batches.

### `ImportLib` — user seeding
`writeUser` — writes an imported user's full record during the one-time import window.

### `ClubSyncLib` — club consistency
`sync` — keeps StepNet's view of club membership consistent with `StepClub`.

---

## Why this matters for security

- **Bounded everywhere.** Every library routine that touches an unbounded set (tickets, pending updates, subtree rebuild) takes a batch/cursor parameter. There is no "loop over everyone" anywhere — the same anti-grief discipline as the core engine, enforced at the library level.
- **Storage-layout safe.** Libraries that run via `DELEGATECALL` operate on the exact same `User` struct, so there is no layout drift between core and library.
- **Single responsibility.** Each library is small enough to reason about in isolation, which is what makes the 7,400-line system auditable in practice.
