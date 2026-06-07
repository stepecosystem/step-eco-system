# Security Policy

The Step Eco System contracts secure real value on Polygon mainnet. We take security seriously and welcome responsible disclosure.

## Reporting a Vulnerability

**Please do NOT open a public GitHub issue for security vulnerabilities.**

Instead, email **stepecosystemteam@gmail.com** with:

- A description of the vulnerability and its potential impact.
- Step-by-step reproduction (a proof-of-concept is ideal).
- The affected contract(s) and, where possible, the relevant line(s).

We aim to acknowledge reports within 72 hours and to keep you updated as we investigate and remediate.

## Scope

In scope:
- All contracts under [`/contracts`](contracts/).
- The deployed mainnet instances listed in the [README](README.md).

Out of scope:
- The front-end dApp and off-chain infrastructure (report separately to the same address).
- Issues requiring a compromised owner/controller key or a malicious majority DAO vote (these are governed social/operational risks, not contract bugs).

## Design Posture

The contracts are built defensively by default:

- **No custody / no admin over funds** — every privileged change flows through the `StepRegistry` DAO (proposal → vote → veto window → timelock).
- **No oracle** — STEP price is a mechanical function of the DAI reserve and supply.
- **Reentrancy guards** on every value-moving entry-point.
- **Gas-bounded, resumable** distribution routines that cannot be griefed into a halt.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full security model.
