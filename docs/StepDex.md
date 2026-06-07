# StepDex — Deep Dive

> Source: [`contracts/StepDex.sol`](../contracts/StepDex.sol) · 325 lines · `ReentrancyGuard`

StepDex is the bonding-curve AMM that gives STEP its price. It is the *only* contract allowed to mint STEP, and the reserve it holds is what makes STEP "DAI-backed".

---

## The pricing identity

```
price = daiReserve / stepSupply
```

- **Buy:** deposit DAI → DAI added to `daiReserve` → an equivalent amount of STEP is minted to the buyer.
- **Sell:** STEP is burned (`burnFromDex`) → a proportional amount of DAI leaves the reserve to the seller.

Because both reserve and supply move together on every trade, the price curve is continuous and there is **no external oracle** anywhere in the path — nothing to manipulate, nothing to feed a stale value.

---

## Two classes of caller

StepDex deliberately separates *internal* and *public* trade paths:

| Function | Caller | Purpose |
|---|---|---|
| `buyStep` | system contracts only (`onlySystemContract`) | The path StepNet/NFT/Club use to convert protocol DAI into STEP during activations and rewards. |
| `buyStepPublic` / `sellStep` / `sellAll` | any user (`requireTermsAccepted`) | The public market — users buy and sell directly. |

The `onlySystemContract` modifier checks the caller against the registry's known protocol addresses, so the privileged mint path can only be triggered by other audited contracts, never an arbitrary EOA.

---

## Slippage protection

Every buy/sell takes a `minStepOut` / `minDaiOut`. Callers (including internal ones) derive this from a **live `estimateBuy` / `estimateSell` quote at call time** and a tolerance floor. This is the system's defence against sandwich attacks: if the executed price drifts past tolerance, the trade reverts with `SlippageExceeded` rather than filling at an attacker-shifted price.

---

## The price floor

`_getPriceAndDetectFloor` and `PriceFloorActivated` implement a safety floor: if the reserve/supply ratio would drive price below a protective threshold, the floor engages. This protects holders from a degenerate state where price collapses toward zero, while keeping the curve honest in normal operation.

---

## Club hook

On buys, a portion can be routed to the Club treasury (`notifyStepClubDeposit`) — the DEX is wired into the loyalty layer so that market activity feeds the ecosystem pools, not just the trader.

---

## Security rationale recap

- **Reentrancy-guarded** on every trade.
- **Privileged mint path gated** to system contracts via the registry.
- **Slippage floors** on every swap (anti-MEV).
- **Price floor** prevents reserve-drain death spirals.
- **Terms-of-service enforced** on public trades (`requireTermsAccepted`).
- **No oracle, no admin price-set** — price is purely mechanical.
