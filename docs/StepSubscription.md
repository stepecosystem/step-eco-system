# StepSubscription — Deep Dive

> Source: [`contracts/StepSubscription.sol`](../contracts/StepSubscription.sol) · 362 lines · `ReentrancyGuard`

StepSubscription is the AI-access layer. It sells time-based access plans priced in **USD** but settled on-chain in **STEP** or **DAI**, and it is the destination for loyalty credit when a member exits the Club.

---

## Plans priced in USD, paid in crypto

Plans are defined by `setPlan(plan, months, monthlyUsd)` and read via `getPlans`. The contract converts a USD price into a live token amount at purchase time:

- `planTotalUsd(plan)` → the total USD cost of a plan.
- `quote(plan)` → returns both the USD figure **and** the equivalent STEP amount, computed against the bonding-curve price at call time.

This keeps pricing intuitive for users (stable USD) while settling trustlessly in crypto.

---

## Two ways to pay

| Function | Pays in | Notes |
|---|---|---|
| `subscribe(plan, maxStep)` | STEP | `maxStep` is a slippage guard — the user can't be charged more STEP than they approved, even if price moves. |
| `subscribeWithDai(plan)` | DAI | Direct DAI settlement. |

Both are `nonReentrant`.

---

## Loyalty → utility bridge

```solidity
function grantFromClubExit(address user, uint256 gapDai) external returns (uint32 monthsGranted);
```

When `StepClub` gracefully exits a member at cap, it calls this to convert the member's residual value (`gapDai`) into **subscription months** (`monthsForGap` does the conversion). The call is gated to the configured club authority (`setClubAuthority`). This is what makes Club membership end in *value received* rather than value lost.

A separate `grantSubscription(user, months)` lets an authorized granter (`setGranter`) issue access directly — e.g. for promotions — again behind an authority check.

---

## Access checks

`accessStatus(user)` returns whether a user currently has active access and until when — the function off-chain AI services call to authorize a request. Expiry is tracked per user and extended (not reset) when a user renews, so stacking plans is additive.

---

## Owner surface

`Ownable`-style admin (`setTreasury`, `setClubAuthority`, `setGranter`, `setPlan`, `transferOwnership`) is limited to configuration — pricing, plan definitions, and which addresses may grant. It cannot touch user funds or fabricate access outside the defined plan/authority rules.

---

## Security rationale recap

- **Slippage-guarded STEP payments** (`maxStep`).
- **Authority-gated grants** (`grantFromClubExit` / `grantSubscription`) — only the Club/granter can mint access, never an arbitrary caller.
- **Additive expiry** — renewals extend, never overwrite.
- **Reentrancy-guarded** purchase paths.
- **USD-stable pricing** settled trustlessly via the live bonding-curve quote.
