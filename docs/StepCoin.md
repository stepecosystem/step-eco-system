# StepCoin (STEP) — Deep Dive

> Source: [`contracts/StepCoin.sol`](../contracts/StepCoin.sol) · 250 lines · `ERC20`

STEP is the native utility token of Step Eco System. Its defining property is that it is **DAI-backed with a dynamic supply** — the price is never a guess, it is a fact derived from collateral.

---

## Design in one sentence

> Tokens can only enter circulation through the bonding-curve DEX (each mint backed by DAI), can be burned by holders or the DEX, and pay a 2% deflationary levy on every ordinary transfer.

---

## Key constants

| Constant | Value | Why |
|---|---|---|
| `INITIAL_SUPPLY` | 1,000,000 STEP | Bootstraps the DEX reserve once, via `mintInitialSupply`. |
| `FEE_PERCENT` | 2 | The transfer levy, burned on each non-system transfer. |
| `MAX_WHITELIST` | 2 | Hard cap on fee-exempt system addresses — keeps the exemption surface tiny and auditable. |

---

## Authority model — who can do what

- **Mint** — *only* the registry-current `StepDex` (`mint`, guarded by `_dex()`). This is the single most important rule: **no STEP can be created except through the bonding curve, which backs every mint with DAI.** There is no owner mint.
- **Initial supply** — `mintInitialSupply()` can be called once, only by `originalDeployer`, and only to seed the DEX. `initialSupplyMinted` makes it irreversible.
- **Burn** — split between the holder (`burn`) and the DEX (`burnFromDex`), so supply stays faithfully tied to the reserve as users sell back.
- **Whitelist** — managed through the DAO/registry path, capacity 2. Whitelisted system contracts are exempt from the 2% levy so internal protocol accounting stays exact.

---

## The 2% levy — `_update` override

The levy is enforced in the ERC-20 `_update` hook, so it applies uniformly to every transfer path:

- Mints and burns pass through untaxed (no `from`/`to` levy on supply changes).
- Transfers **to or from** a whitelisted system address are untaxed — otherwise the protocol would tax itself moving funds internally, corrupting reward math.
- Every other transfer burns 2% and moves 98%, making ordinary circulation continuously deflationary.

This is why the whitelist is capped and DAO-gated: it is the *only* exemption to the deflationary rule, so its surface must stay minimal.

---

## Migration safety

`migrateAssetsTo` exists for an emergency/upgrade path, but — like everything else — it is reachable only through the governed registry flow, never an arbitrary owner call. The contract emits `AssetsMigrated` for full transparency.

---

## Security rationale recap

- **No unbacked inflation:** mint is DEX-only, DAI-backed.
- **No oracle:** price lives in `StepDex` as reserve ÷ supply.
- **Tight exemption surface:** levy whitelist capped at 2 and DAO-gated.
- **Gas-efficient failures:** custom errors (`NotDex`, `Unauthorized`, …) instead of revert strings.
