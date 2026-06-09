# StepNet contract tests

Hardhat harness that unit-tests the production contracts in [`../contracts-src`](../contracts-src)
directly — no copies, no drift. `contracts/` is a symlink to `../contracts-src`,
and test-only mocks live in `../contracts-src/mocks/` (`MockERC20`, `MockClub`,
`MockDAO`) so they compile alongside the real code but are never deployed to
mainnet.

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
- Shared deploy/wiring lives in `test/_helpers.js`.

22 tests passing.

## Not yet covered (next)

- The DAILY_CAP=15 points burn (needs a >=32-node balanced tree to drive a
  weaker-side above the cap).
- Higher-tier upgrades, the upgrade reserve lifecycle, and auto-upgrade.
- `StepClub`, `StepNFTTreasury`, `StepSubscription` (real contracts, not mocks).
- Migration flow (`proposeMigration` / `voteMigration` / asset move).
