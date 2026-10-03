# StepNet contract tests

Hardhat harness that unit-tests the production contracts. At test time the local
`contracts/` directory is assembled from the production sources at the repo root
([`../contracts`](../contracts)) plus the test-only mocks in
[`../contracts-src/mocks/`](../contracts-src/mocks) (`MockERC20`, `MockClub`,
`MockNFT`, `MockDAO`, `MockSplitSink`, `MockStepNFT`) — so the real code and the mocks compile together but the
mocks are never deployed to mainnet. The assembled `contracts/` is gitignored
(no copies committed, no drift); CI recreates it on every run.

## Run

```bash
cd contracts-test
npm ci
npm test        # assembles ./contracts, then runs hardhat test
```

## Compiler note

The mainnet bytecode targets `evmVersion: paris` (see the root
[`hardhat.config.js`](../hardhat.config.js)). These tests target `cancun`
because OpenZeppelin 5.6's `Bytes.sol` uses the `mcopy` opcode — this is
logic-equivalent for our contracts and only affects the EVM target, not Solidity
semantics.

## Coverage

- **`01-dex-and-levy.test.js`** — StepDex bonding-curve math (price formula,
  96% buy mint, ~96% sell payout, price monotonic non-decreasing) and the
  StepCoin 2% levy (burned on EOA transfers, exempt on mint/burn). Asserts exact
  on-chain behaviour, including the levy on the DEX→club hop of a buy.
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
- **`05-subscription.test.js`** — `StepSubscription`, the live revenue
  conduit: the 19/51/10/20 split is exhaustive and leaves nothing on the
  contract, the club and fund legs are pulls, the 2% levy is visible in what each
  destination receives, payment reverts until the fund is wired, the four
  published plans, additive expiry, the slippage guard, the club-exit hook and
  the owner/granter gates.
- **`06-nft-treasury.test.js`** — `StepNFTTreasury` wired as a real system
  contract: the tiered price curve, a real `buy()` that swaps DAI→STEP on the
  live DEX and splits the STEP 90/10 to the treasury wallets, the Terms gate, the
  `maxPrice` guard, and owner-only admin.
- **`07-club.test.js`** — `StepClub` constructor guards, the `onlyStepNet`
  membership gate (add/remove), an add-member happy path, and the user-facing
  guards (`claimForUser`, `exit`, `donateToPool`).
- **`08-nft-fund.test.js`** — `StepNFTFund` against `MockStepNFT` (production
  price curve, day-price rule and 10% DAI transfer levy): the 50/50 vault split
  and its owner-only retune, the treasury-reward sweep, buy-back with custody and
  immediate payout, strict FIFO queueing, seller cancellation, re-sale at the day
  price with queue top-up and the 90/10 split, tier promotion, the buyer price
  cap, yield to the ≥400-DAI tier only, the once-a-day guard, custody exclusion,
  the 30-day claim-or-burn rule, a resumable two-batch round with custody frozen
  mid-round, and the registry-only migration gate. Every scenario ends by
  checking that the fund's STEP balance equals its tracked liabilities, to the wei.
- Shared deploy/wiring lives in `test/_helpers.js`.

66 tests passing (plus 10 in the top-level suite).

## Planned coverage

- The DAILY_CAP=15 points burn (needs a >=32-node balanced tree to drive a
  weaker-side above the cap).
- Higher-tier upgrades, the upgrade reserve lifecycle, and auto-upgrade.
- `StepClub` distribution rounds and the exit-to-subscription cap math.
- Migration flow (`proposeMigration` / `voteMigration` / asset move).
