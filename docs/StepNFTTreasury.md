# StepNFTTreasury — Deep Dive

> Source: [`contracts/StepNFTTreasury.sol`](../contracts/StepNFTTreasury.sol) · 880 lines · `ERC721Enumerable, Ownable, ReentrancyGuard`

A tiered NFT collection that is also a **yield instrument**: holders share an on-chain STEP reward pool that is fed by protocol activity.

---

## The collection

Standard `ERC721Enumerable` with tier pricing exposed via `getPrice(id)` / `getCurrentPrice()`. Minting is through `buy` / `buyMultiple`, both `requireTermsAccepted` and `nonReentrant`, with a `maxPrice` / `maxTotalPrice` slippage guard so a buyer can never be charged more than they agreed to.

---

## The reward pool

The pool (`nftRewardPool`) is fed by:
- the **3% NFT slice** on every box activation in StepNet (`addToRewardPool`),
- direct donations (`donateToRewardPool`).

`distributeRewards` snapshots holders and allocates the pool across them, and `claimRewards` lets holders withdraw. Both are written as **bounded, resumable routines** — `distributeRewards` records `DistributionRecord`s and `pendingOfPaginated` lets a holder with many distributions claim in pages — so neither distribution nor claiming can exceed the gas limit no matter how large the holder base grows.

`getTimeUntilNextDistribution` exposes the interval timer to the dApp.

---

## Legacy migration — one-way, capped, eligibility-checked

`swapNFT` / `swapNFTBatch` migrate the previous-generation NFTs into this treasury:

- **Eligibility:** only the qualifying legacy tiers ($100 / $200) can swap; higher tiers stay on the old contract by design.
- **Capped:** a migration snapshot (`maxOldTokenId`) blocks any NFT minted *after* the cutoff, so the migration set is fixed and cannot be gamed by minting new legacy tokens.
- **One-way:** `_consumeSwap` consumes the old token as it issues the new one; there is no round-trip.
- **Batched:** `swapNFTBatch` processes many tokens per call within bounded limits.

---

## Transfer fee

`_collectTransferFee` / the `_update` override apply a fee on secondary transfers, feeding value back into the ecosystem rather than leaking it on every trade.

---

## On `Ownable`

The treasury is `Ownable` for narrow operational settings (e.g. `setBaseURI`, `setOldNFTContract`), and supports `renounceOwnership`. The economically meaningful wiring — which token, which DEX, which Club — is still resolved through the **registry**, so owner power is limited to metadata/config, never to user funds or the reward math.

---

## Security rationale recap

- **Slippage-guarded mints** (`maxPrice` / `maxTotalPrice`).
- **Bounded, paginated distribution & claiming** — no gas-limit griefing.
- **Migration is one-way, eligibility-checked, and snapshot-capped** — the set is fixed and ungameable.
- **Reentrancy-guarded** on all value paths.
- **Owner power scoped to config/metadata**, with economics resolved via the registry.
