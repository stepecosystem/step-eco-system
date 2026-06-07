# Contributing

Thank you for your interest in Step Eco System.

> **License note:** this project is **proprietary** (see [`LICENSE`](LICENSE)). The source is published for transparency, review, and auditability — not for reuse. By submitting any contribution you agree it may be incorporated under the project's proprietary license.

## How you can help

- **Report bugs** — open an issue with clear reproduction steps. For *security* bugs, follow [`SECURITY.md`](SECURITY.md) instead of opening a public issue.
- **Suggest improvements** — open an issue describing the idea and its motivation.
- **Documentation** — corrections and clarifications to the docs are very welcome.

## Local setup

```bash
git clone https://github.com/stepecosystem/step-eco-system.git
cd step-eco-system
npm install
npm run compile   # compile all contracts
npm test          # run the test suite
```

Requirements: Node.js 20+, npm.

## Pull requests

Before opening a PR, please make sure:

1. `npm run compile` succeeds with no new warnings.
2. `npm test` passes.
3. New behavior is covered by a test.
4. Commits are clear and scoped.

CI will automatically compile and test every PR.

## Code style

- Match the surrounding Solidity style: NatSpec on public/external functions, custom errors (not revert strings), explicit visibility, and clear section banners.
- Keep gas-bounded/resumable patterns intact — never introduce an unbounded loop over a user-growable set.
