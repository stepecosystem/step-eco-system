# Documentation

Start with the [top-level README](../README.md) for the overview and [`ARCHITECTURE.md`](../ARCHITECTURE.md) for how everything fits together. Each deep dive below walks through one contract section by section — what it does, *why* it is built that way, and the security rationale behind each design choice.

## Ecosystem
- [**AI Products**](AI-Products.md) — Irona, Psyvora, Taskora and Sonexa in detail, and how wallet sign-in, on-chain payment and entitlement connect them to these contracts

## Core protocol
- [**StepNet**](StepNet.md) — the subscription engine, binary network, and daily distribution state machine
- [**StepNetLib**](StepNetLib.md) — the gas-optimized libraries behind StepNet
- [**StepNetView**](StepNetView.md) — the read-only aggregator for the dApp

## Token & exchange
- [**StepCoin**](StepCoin.md) — the DAI-backed STEP token
- [**StepDex**](StepDex.md) — the bonding-curve AMM

## Revenue & rewards
- [**StepSubscription**](StepSubscription.md) — the live revenue conduit (19 / 51 / 10 / 20 split) and on-chain plans
- [**StepNFTFund**](StepNFTFund.md) — NFT buy-back desk and daily yield vault
- [**StepNFTTreasury**](StepNFTTreasury.md) — tiered NFT collection and reward pool
- [**StepClub**](StepClub.md) — the loyalty club

## Governance
- [**StepRegistry**](StepRegistry.md) — the DAO and on-chain address book

## Reference
- [**Interface Reference**](Reference.md) — every contract's external API, events, errors and constants in one place
- [**Glossary**](Glossary.md) — plain-language definitions of the domain terms
