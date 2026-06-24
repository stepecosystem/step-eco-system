# 📖 Contract Deep Dives

Each document below walks through one contract section by section — what it does, *why* it is built that way, and the security rationale behind each design choice. Start with the [top-level README](../README.md) for the overview and [`ARCHITECTURE.md`](../ARCHITECTURE.md) for how everything fits together.

## Core
- [**StepNet**](StepNet.md) — the subscription engine, binary network, and daily distribution state machine
- [**StepNetLib**](StepNetLib.md) — the gas-optimized libraries behind StepNet
- [**StepNetView**](StepNetView.md) — the read-only aggregator for the dApp

## Token & Exchange
- [**StepCoin**](StepCoin.md) — the DAI-backed STEP token
- [**StepDex**](StepDex.md) — the bonding-curve AMM

## Ecosystem
- [**StepNFTTreasury**](StepNFTTreasury.md) — tiered NFTs + reward pool
- [**StepClub**](StepClub.md) — the loyalty club
- [**StepSubscription**](StepSubscription.md) — AI-access plans

## Governance
- [**StepRegistry**](StepRegistry.md) — the DAO and on-chain address book
