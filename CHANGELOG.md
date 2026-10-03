# Changelog

All notable changes to the Step Eco System contracts are documented in this file.
The project adheres to [Semantic Versioning](https://semver.org).

## [1.1.0] — 2026-10-03

### Added
- **`StepSubscription`** — the live revenue conduit
  (`0x8B567B997B5e80840228D047C8796234992E667C`). Every subscription payment is
  converted to STEP and split 19 / 51 / 10 / 20 (development / owner / StepClub /
  StepNFTFund) in the same transaction; prices can be receipted on-chain with a
  payment reference, or bought from four on-chain plans.
- **`StepNFTFund`** — the NFT buy-back desk and daily yield vault
  (`0xaA739Ce109C72f775212Ed5fd1177120d295b26f`), registered under `NFT_FUND`.
- Both sources are identical to their Sourcify full-match deployments (apart from
  the license line).
- **31 new contract tests** — 15 for `StepSubscription` and 16 for `StepNFTFund`,
  with a production-shaped `MockStepNFT` and a pulling `MockSplitSink`. **76 tests**
  in total.
- **`verify-sources.js`** and a CI job proving that every file in `contracts/` is the
  verified source of a deployed contract.
- Documentation: the AI product family (Irona, Psyvora, Taskora, Sonexa), deep dives
  for both new contracts, a hard-guarantees section in `ARCHITECTURE.md`, and
  interface and glossary entries.
- Issue and pull-request templates.

### Improved
- `verify-onchain.js` covers `StepSubscription` and `StepNFTFund`, fails
  over across public RPC endpoints on every call, and marks any value it could not
  read explicitly.
- `contracts-test` assembles its own sources — `npm test` is all it takes.
- `scripts/deploy.js` comments and console output are in English.

### Removed
- The first-generation subscription contract, which is no longer in use.

## [1.0.0] — 2026-06

Initial public release of the production contract suite — the exact source
deployed to **Polygon mainnet (chainId 137)** and securing real value today.

### Contracts
- **StepNet / StepNetLib / StepNetView** — the core subscription engine: boxes
  0–5, the binary referral graph, and the deterministic daily distribution
  cycle, with gas-optimized libraries and read-only aggregation for the dApp.
- **StepCoin** — a DAI-backed, dynamic-supply ERC-20 with a deflationary 2%
  transfer levy.
- **StepDex** — a bonding-curve AMM (price = reserve ÷ supply) with a price floor.
- **StepNFTTreasury** — a tiered ERC-721 collection with an on-chain STEP reward
  pool and legacy-NFT migration.
- **StepClub** — the loyalty club: membership cycle, batched distributions, and
  auto-exit logic.
- **StepRegistry** — the DAO: the single source of truth for every contract
  address, governed by Box-0-weighted voting with a vote → veto → timelock flow.

### Security & quality
- No custody, no admin backdoor, no external price oracle — every economic rule
  is an immutable constant of the code.
- Reentrancy guards on every value-moving entry-point; custom errors throughout;
  slippage-protected AMM interactions.
- Deep Hardhat test suite (**48 unit tests**) asserting the protocol's money
  paths, run on every push and pull request via GitHub Actions.
