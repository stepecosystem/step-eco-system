# Changelog

All notable changes to the Step Eco System contracts are documented in this file.
The project adheres to [Semantic Versioning](https://semver.org).

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
- **StepSubscription** — USD-priced AI-service access plans, settled in STEP or DAI.

### Security & quality
- No custody, no admin backdoor, no external price oracle — every economic rule
  is an immutable constant of the code.
- Reentrancy guards on every value-moving entry-point; custom errors throughout;
  slippage-protected AMM interactions.
- Deep Hardhat test suite (**48 unit tests**) asserting the protocol's money
  paths, run on every push and pull request via GitHub Actions.
