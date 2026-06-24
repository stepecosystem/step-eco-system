<div align="center">

# 🌐 Step Eco System — Smart Contracts

### A fully on-chain Web3 ecosystem, live on Polygon — a DAI-backed token economy, a binary subscription network, an NFT treasury, a decentralized exchange, an AI-access layer, and DAO-governed upgrades.

[![Live dApp](https://img.shields.io/badge/Live%20dApp-net.stepnet.pro-a855f7?style=for-the-badge)](https://net.stepnet.pro)
[![Network](https://img.shields.io/badge/Network-Polygon%20Mainnet-8247E5?style=for-the-badge&logo=polygon)](https://polygonscan.com)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.35-363636?style=for-the-badge&logo=solidity)](https://soliditylang.org)
[![Status](https://img.shields.io/badge/Status-Live%20on%20Mainnet-22c55e?style=for-the-badge)]()

[![CI](https://github.com/stepecosystem/step-eco-system/actions/workflows/ci.yml/badge.svg)](https://github.com/stepecosystem/step-eco-system/actions/workflows/ci.yml)
[![Contract Tests](https://github.com/stepecosystem/step-eco-system/actions/workflows/contracts-test.yml/badge.svg)](https://github.com/stepecosystem/step-eco-system/actions/workflows/contracts-test.yml)
[![Tests](https://img.shields.io/badge/tests-48%20passing-22c55e.svg)](contracts-test/)
[![License](https://img.shields.io/badge/license-Proprietary-red.svg)](LICENSE)

</div>

---

> ⚖️ **Proprietary · All Rights Reserved.** This source is published for **transparency and audit only — not for reuse.** Copying, modifying, redeploying, or reusing any part of it (in whole or in part) without prior written permission is strictly prohibited. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

---

## 📜 Philosophy

> **Move Real · Earn Real · Build Forever.**

Step Eco System is a non-custodial, fully on-chain protocol. There is no admin key that can move user funds, no oracle that can be manipulated to misprice the token, and no privileged backdoor to the treasury. Every economic rule — token price, reward splits, distribution cadence — is an **immutable constant of the code**, and every administrative change must pass an on-chain **DAO vote + veto window + timelock**.

This repository contains the complete, production source of all nine contracts deployed to Polygon mainnet — the same code that secures real value today.

---

## 🗺️ Contract Suite

| Contract | Lines | Role |
|---|---:|---|
| [`StepNet.sol`](contracts/StepNet.sol) | 1,353 | **Core engine** — subscription "boxes" (0–5), the binary referral graph, and the deterministic daily distribution cycle |
| [`StepNetLib.sol`](contracts/StepNetLib.sol) | 909 | Gas-optimized libraries powering StepNet (reserve tickets, wallet migration, tree propagation, batch import) |
| [`StepNetView.sol`](contracts/StepNetView.sol) | 1,225 | Read-only aggregator — packs every dashboard, stat, and timer the dApp needs into single calls |
| [`StepCoin.sol`](contracts/StepCoin.sol) | 250 | **STEP token** — a DAI-backed, dynamic-supply ERC-20 with a deflationary 2% transfer levy |
| [`StepDex.sol`](contracts/StepDex.sol) | 325 | **Bonding-curve AMM** — STEP ⇄ DAI, where price = reserve ÷ supply, with a built-in price floor |
| [`StepNFTTreasury.sol`](contracts/StepNFTTreasury.sol) | 880 | Tiered ERC-721 collection with an on-chain STEP reward pool and legacy-NFT migration |
| [`StepClub.sol`](contracts/StepClub.sol) | 1,093 | Loyalty club — membership cycle, batched distributions, and auto-exit logic |
| [`StepRegistry.sol`](contracts/StepRegistry.sol) | 867 | **The DAO** — the single source of truth for every contract address, governed by Box-0-weighted voting |
| [`StepSubscription.sol`](contracts/StepSubscription.sol) | 362 | AI-service access plans, priced in USD and settled in STEP or DAI |

📖 **Each contract has a full deep-dive in [`/docs`](docs/) — section by section, with the security rationale behind every design choice.**

---

## 🚀 Deployed Addresses (Polygon Mainnet · chainId 137)

| Contract | Address |
|---|---|
| StepRegistry (DAO) | [`0x708fA8F368D15B8293cD6c0A29a790fC1c7F13Ce`](https://polygonscan.com/address/0x708fA8F368D15B8293cD6c0A29a790fC1c7F13Ce) |
| StepNet | [`0xeD4a3704d23a134C2219534C601a44fd677A77ff`](https://polygonscan.com/address/0xeD4a3704d23a134C2219534C601a44fd677A77ff) |
| StepNetView | [`0x944ffb44c6C1777aB599325514c7d14bD4f8c61D`](https://polygonscan.com/address/0x944ffb44c6C1777aB599325514c7d14bD4f8c61D) |
| StepCoin (STEP) | [`0x259c17323F9a38118a10D979f21F9eBafAE9c0F6`](https://polygonscan.com/address/0x259c17323F9a38118a10D979f21F9eBafAE9c0F6) |
| StepDex | [`0x512964f922Ec791a93b5E70ED3c9aC09ec4dCf10`](https://polygonscan.com/address/0x512964f922Ec791a93b5E70ED3c9aC09ec4dCf10) |
| StepNFTTreasury | [`0x49de1a6516A1eEDb6269224953F03e55F72Dc68c`](https://polygonscan.com/address/0x49de1a6516A1eEDb6269224953F03e55F72Dc68c) |
| StepClub | [`0x00d76a71f9c89C79406ed170583BEDb45f3c7AE6`](https://polygonscan.com/address/0x00d76a71f9c89C79406ed170583BEDb45f3c7AE6) |
| StepSubscription | [`0x40d14915073c76b7ba4601804413ac4646d123D6`](https://polygonscan.com/address/0x40d14915073c76b7ba4601804413ac4646d123D6) |

> Collateral asset: **DAI** on Polygon PoS — [`0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063`](https://polygonscan.com/address/0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063)

---

## 🏛️ How It Fits Together

```
                         ┌───────────────────────────┐
                         │       StepRegistry         │  ← the DAO: address book + governance
                         │  (vote · veto · timelock)  │
                         └─────────────┬─────────────┘
              every contract resolves its peers through the registry
   ┌───────────────┬───────────────┼───────────────┬───────────────┐
   ▼               ▼               ▼               ▼               ▼
┌────────┐    ┌─────────┐    ┌──────────┐    ┌──────────┐    ┌──────────────┐
│StepCoin│◄──►│ StepDex  │◄──►│ StepNet  │───►│ StepClub │    │StepNFTTreasury│
│ (STEP) │    │ (AMM)    │    │ (engine) │    │ (loyalty)│    │   (rewards)   │
└────────┘    └─────────┘    └────┬─────┘    └──────────┘    └──────────────┘
                                  │ uses
                          ┌───────▼────────┐   ┌──────────────────┐
                          │  StepNetLib    │   │ StepSubscription │  ← AI access
                          │  (libraries)   │   │  (USD plans)     │
                          └────────────────┘   └──────────────────┘
                          StepNetView ──► read-only views for the dApp (no state)
```

A subscription payment into `StepNet` fans out deterministically: part flows to a **daily redistribution pool** for active subscribers, part to the **NFT reward pool**, part to the **Club pool**, part to a **dev treasury**, and part is converted to **STEP** through the `StepDex` bonding curve — every split an immutable constant. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full value-flow and security model.

---

## 🔐 Security Model — At a Glance

- **No custody.** Contracts never hold user keys; users interact directly and non-custodially.
- **No backdoor.** Every address swap or treasury move requires a passed DAO proposal, a veto window, and a timelock — enforced by `StepRegistry`.
- **No oracle risk.** STEP's price is a *fact* (DAI reserve ÷ supply), not an external feed that can be manipulated.
- **Reentrancy-guarded** on every external entry-point that moves value.
- **Gas-bounded & resumable.** The daily distribution is a cursor-based state machine — no single transaction can be pushed to the block gas limit by a malicious actor, so distributions can never be griefed into a halt.
- **Custom errors** everywhere (no revert strings) for cheap, explicit failure.
- **Slippage-protected** AMM interactions (`minStepOut` derived from a live quote at call time).

---

## 🏛️ Governance Status — Live on Mainnet

The protocol is governed **on-chain today** — the DAO is active, not a roadmap promise:

| Stage | Status |
|---|---|
| Bootstrap — controller seeds the initial addresses | ✅ complete |
| **`activateDao()`** — controller mutation paths close; every change now requires vote → veto → timelock | ✅ **active** |
| `renounceControl()` — controller gives up its residual veto (final, one-way step) | ⏳ pending |

Since `activateDao()`, **there is no direct admin write path**: every address or parameter change must pass a Box-0-weighted DAO vote, a controller veto window, and a timelock. The controller retains only a *veto* — a circuit-breaker, not the power to mutate state — until `renounceControl()` completes the one-way path to full decentralization.

> **Don't trust — verify.** This is live, public state. Read it yourself in one command:
> ```bash
> node contracts-src/verify-onchain.js
> ```
> It prints `daoActive`, `controlRenounced`, the controller, and the levy whitelist straight from Polygon mainnet — or read them directly on [`StepRegistry` @ Polygonscan](https://polygonscan.com/address/0x708fA8F368D15B8293cD6c0A29a790fC1c7F13Ce#readContract).

---

## 🛠️ Tech Stack

- **Solidity 0.8.35** · **OpenZeppelin Contracts v5**
- **Hardhat** (compile · test · deploy · verify)
- **Polygon PoS** (chainId 137), EVM target `paris`, `viaIR` enabled

---

## ⚙️ Build & Test

```bash
git clone https://github.com/stepecosystem/step-eco-system.git
cd step-eco-system
npm install

npm run compile   # compile all 9 contracts
npm test          # run the test suite
```

Beyond the top-level suite, [`contracts-test/`](contracts-test/) holds a deep Hardhat suite of **48 unit tests** that assert the money paths directly — the bonding-curve math, the 2% levy, the full DAO governance lifecycle, StepNet activation + daily-reward distribution, subscription billing, the NFT-treasury sale, and the loyalty club.

Requirements: **Node.js 20+**. Every push and pull request is automatically compiled and tested by GitHub Actions ([`ci.yml`](.github/workflows/ci.yml) · [`contracts-test.yml`](.github/workflows/contracts-test.yml)).

For deployment, copy `.env.example` to `.env`, fill in your `PRIVATE_KEY` and RPC URLs, then run `scripts/deploy.js` with Hardhat. The `.env` file is gitignored and must never be committed.

---

## 📄 License

**Proprietary — © 2026 Step Eco System. All Rights Reserved.** See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

This repository is **not open source.** It is published for the sole purposes of **transparency, security review, and auditability** — a permission to *look*, not a license to *use*. Every source file is marked `SPDX-License-Identifier: UNLICENSED`.

Without prior written permission you **may not**:

- copy, reproduce, or republish the code beyond viewing it;
- modify, adapt, refactor, or create derivative works;
- distribute, sublicense, sell, or share it with third parties;
- deploy, redeploy, or operate it on any network;
- reuse any part, pattern, or mechanism in another project;
- use it to train, fine-tune, or evaluate any AI/ML system; or
- remove or alter any copyright or license notice.

You **may** read and audit the code, and quote limited portions for good-faith security review or research with attribution. For any other use, written permission is required: **stepecosystemteam@gmail.com**.

---

## 📬 Connect

- 🚀 dApp: **[net.stepnet.pro](https://net.stepnet.pro)**
- 🌐 Website: **[stepnet.pro](https://stepnet.pro)**
- ✉️ Team: **stepecosystemteam@gmail.com**
- 🔐 Security: see [`SECURITY.md`](SECURITY.md)

---

<div align="center">

**Step Eco System** — a transparent, on-chain economy, verifiable by anyone, block by block. 🌱

</div>
