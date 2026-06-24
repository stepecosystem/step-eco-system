# StepNet contract tests

Hardhat harness that unit-tests the production contracts. At test time the local
`contracts/` directory is assembled from the production sources at the repo root
([`../contracts`](../contracts)) plus the test-only mocks in
[`../contracts-src/mocks/`](../contracts-src/mocks) (`MockERC20`, `MockClub`,
`MockNFT`, `MockDAO`) — so the real code and the mocks compile together but the
mocks are never deployed to mainnet. The assembled `contracts/` is gitignored
(no copies committed, no drift); CI recreates it on every run.

## Run

```bash
cd contracts-test
npm install
npx hardhat test
```

## Compiler note

The mainnet bytecode targets `evmVersion: paris` (see
`../step-ecosystem/hardhat.config.recommended.js`). These tests target `cancun`
because OpenZeppelin 5.6's `Bytes.sol` uses the `mcopy` opcode — this is
logic-equivalent for our contracts and only affects the EVM target, not Solidity
semantics.

## Coverage so far

- **`01-dex-and-levy.test.js`** — StepDex bonding-curve math (price formula,
  96% buy mint, ~96% sell payout, price monotonic non-decreasing) and the
  StepCoin 2% levy (burned on EOA transfers, exempt on mint/burn). Asserts exact
  on-chain behaviour, including that with the whitelist empty (as on mainnet) the
  DEX→club hop on a buy is itself taxed 2%.
- **`02-registry-governance.test.js`** — full DAO lifecycle: create → vote →
  veto → execute, timelock windows, proposer (Box-5) and voter eligibility
  gates, the anti-flash-recruit snapshot weight cap, and controller veto.
- **`03-stepnet-activation.test.js`** — StepNet with all 5 StepNetLib libraries
  linked: deploy + `finalizeSetup`, the Box-0 activation split (82% to the tier
  pool, 18% converted to STEP and paid out to user/dev/nft/club), tree
  placement, and a full `processDaily` cycle (TooEarly guard + completion).
- **`04-stepnet-rewards.test.js`** — `processDaily` reward-point *correctness*:
  with founder→(alice,bob) the founder holds 1 weaker-side point and is paid the
  whole 41 DAI pool (exactly 36.9 claimable + 4.1 upgrade reserve); leaf
  subscribers earn nothing; and the founder can withdraw the reward as STEP,
  zeroing the pending balance (double-withdraw reverts).
- **`05-subscription.test.js`** — `StepSubscription` on the full wiring (live DEX
  price + StepNet trial timestamps): the four plans and DAI quoting,
  `subscribeWithDai` (revenue routed to the treasury, user marked PAID, early
  renewal stacks days), the STEP slippage guard, `grantSubscription` (owner +
  low-privilege granter + guards), `monthsForGap` (130 DAI → 30 months), the
  trustless club-exit conversion, and the owner-only admin gates.
- **`06-nft-treasury.test.js`** — `StepNFTTreasury` wired as a real system
  contract: the tiered price curve, a real `buy()` that swaps DAI→STEP on the
  live DEX and splits the STEP 90/10 to the treasury wallets, the Terms gate, the
  `maxPrice` guard, and owner-only admin.
- **`07-club.test.js`** — `StepClub` constructor guards, the `onlyStepNet`
  membership gate (add/remove), an add-member happy path, and the user-facing
  guards (`claimForUser`, `exit`, `donateToPool`).
- Shared deploy/wiring lives in `test/_helpers.js`.

48 tests passing.

## Not yet covered (next)

- The DAILY_CAP=15 points burn (needs a >=32-node balanced tree to drive a
  weaker-side above the cap).
- Higher-tier upgrades, the upgrade reserve lifecycle, and auto-upgrade.
- `StepClub` distribution rounds and the exit-to-subscription cap math.
- Migration flow (`proposeMigration` / `voteMigration` / asset move).
