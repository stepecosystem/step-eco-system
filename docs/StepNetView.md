# StepNetView — Deep Dive

> Source: [`contracts/StepNetView.sol`](../contracts/StepNetView.sol) · 1,225 lines

StepNetView is a **pure read layer**. It holds no state, moves no value, and has no privileged functions. Its entire job is to make the dApp fast and cheap.

---

## Why a separate contract?

Two reasons:

1. **RPC efficiency.** A dashboard needs dozens of small values — balances, timers, team counts, club status, NFT rewards, price. Fetching each with its own `eth_call` is slow and rate-limit-prone. StepNetView packs them into a handful of aggregated calls (e.g. `getUserDashboard`, `getMasterDashboard`, `getClubDashboard`, `getGlobalStats`) so the frontend makes one round-trip instead of fifty.
2. **EIP-170 headroom.** All this read logic would push the core `StepNet` past the 24KB contract-size limit. Keeping reads in a separate, swappable contract lets the engine stay lean — and lets the view be upgraded (through governance) to expose new aggregates without redeploying the core.

---

## What it reads

StepNetView declares interfaces over `StepNet`, `StepClub`, `StepNFTTreasury`, and `StepDex`, resolves them through the registry, and composes their getters into UI-shaped structs:

- **User dashboards** — boxes owned, pending rewards per box, reserve, team left/right, points, timers.
- **Club** — membership status, pending club reward, cycle timers, club-wide stats.
- **NFT** — holdings, pending/claimed rewards, time-until-next-distribution.
- **Network/global** — member count, round count, live pool, total donated, last distribution time.
- **Governance inputs** — Box-0 subtree weaker side (the raw material for voting weight).

---

## Security rationale

There is almost nothing to attack here, which is the point:

- **No state** → no storage to corrupt.
- **No value transfer** → nothing to steal.
- **`view`-only** → cannot change anything even if mis-called.
- **Swappable** → if the dApp needs a new aggregate, governance can point the registry at an upgraded view without ever touching the value-bearing core contracts.

This separation of "logic that moves money" from "logic that reads data" is a deliberate blast-radius reduction: the large, frequently-iterated surface (reads) is kept entirely outside the trust boundary.
