# StepRegistry — Deep Dive

> Source: [`contracts/StepRegistry.sol`](../contracts/StepRegistry.sol) · 867 lines

StepRegistry is two things at once: the **address book** every other contract reads to find its peers, and the **DAO** that governs every change to that book. It is the contract that lets the project credibly claim *no backdoor*.

---

## The address book

Every contract resolves peers through `get(key)` rather than storing hard-coded addresses:

```solidity
address dex = REGISTRY.get(REGISTRY.KEY_STEP_DEX());
```

This indirection is what makes the system **upgradeable without a master key**: a contract can be replaced by pointing its key at a new address — but only via a passed proposal.

It also stores **terms-of-service acceptance** (`acceptTerms` / `hasAcceptedCurrentTerms`), which the value-moving contracts check via their `requireTermsAccepted` modifiers.

---

## The lifecycle: bootstrap → DAO

The registry is deliberately *not* born decentralized — bootstrapping a live system needs a setup phase — but it is designed to **become** decentralized and never go back:

1. **Bootstrap.** A controller sets initial addresses (`setInitial` / `setInitialBatch`, `setStepNet`, `setStepNetView`) and may schedule/execute early changes (`scheduleChange` / `executeChange`), all `onlyControllerBeforeDao`.
2. **`activateDao()`.** Once called, the controller-only mutation paths are closed and governance takes over.
3. **`renounceControl()`.** The controller can permanently give up even the residual veto, completing the decentralization.

After step 2, **the only way to change an address is a proposal.**

---

## How governance works

### Voting power
Voting weight comes from the binary network's **permanent Box-0 subtree counters** in StepNet:

```
voting weight = 1 + min(box0LeftSubtree, box0RightSubtree)
```

So influence is earned by building a *balanced* Box-0 network — the same weaker-leg fairness principle as the reward model, applied to governance.

### Proposal types
`ProposalType { ADDRESS_CHANGE, WL_ADD, WL_REMOVE }` — covering address swaps and STEP-levy whitelist changes. There are convenience creators (`createProposal`, `createPairedNetProposal` for swapping StepNet + StepNetView atomically, `createWhitelistAddProposal`, `createWhitelistRemoveProposal`).

### The defence-in-depth flow
1. **Propose** → a `Proposal` with a snapshot of the rules.
2. **Vote** (`vote`) → must cross a **dynamic threshold** scaled to the live Box-0 population (`_thresholdOf` / `_liveThreshold`), so the bar tracks real network size and can't be cleared by a handful of accounts as the network grows.
3. **Veto window** (`vetoProposal`, controller-only, before renouncing) → a circuit-breaker against a malicious proposal that somehow gathered votes.
4. **Timelock** → a delay before `executeProposal` can apply the change, giving the community time to react.

Only after all four does `_executeProposal` write the new address.

---

## Why this is the keystone

Every other security claim in the system rests on this contract:
- "No admin can move funds" → because funds-moving contracts obey addresses **only** the DAO can change.
- "Contracts can be fixed without a rug" → because upgrades go through vote + veto + timelock, visible on-chain the whole time.
- "Influence can't be bought cheaply" → because voting weight is the weaker leg of a real Box-0 network, not a token balance that can be flash-borrowed.

---

## Security rationale recap

- **One-way decentralization:** bootstrap → `activateDao` → `renounceControl`, never backwards.
- **Dynamic quorum:** threshold scales with the live Box-0 count.
- **Veto + timelock:** layered circuit-breakers before any change lands.
- **Sybil-resistant voting:** weight = weaker leg of the Box-0 subtree, not raw token holdings.
- **Reentrancy-guarded** voting/execution paths.
