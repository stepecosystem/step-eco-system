# 📖 Glossary

Plain-language definitions of the domain terms used across the contracts and docs.

| Term | Meaning |
|---|---|
| **STEP** | The protocol's native ERC-20, minted/burned against a DAI reserve. Its price is derived, not floated. |
| **DAI** | The collateral asset (on Polygon PoS). All value entering the system is denominated in DAI. |
| **Levy** | The deflationary **2%** burned on STEP transfers between non-exempt addresses. Mints, burns, and whitelisted system addresses are exempt. |
| **Bonding-curve AMM (StepDex)** | The exchange where `price = DAI reserve ÷ STEP supply`. Buying mints STEP and adds reserve; selling burns STEP and returns reserve. |
| **Price floor** | A lower bound on STEP price enforced by StepDex so the curve can't be pushed below a guaranteed value. |
| **Box (0–5)** | A subscription tier in StepNet. Activating a box enrolls a user at that level; higher boxes unlock more of the daily reward pool. |
| **Box-0** | The entry tier and the unit of *network weight* — both reward share and **governance voting power** are measured from the Box-0 subtree. |
| **Binary referral graph** | The two-sided (left/right) tree every user is placed into under their referrer. |
| **Weaker leg / weaker side** | The smaller of a user's left vs right Box-0 subtree counts. Rewards and voting weight scale with the *weaker* leg, so balanced building is rewarded and Sybil stuffing one side is not. |
| **Point** | The unit of daily reward accrual within a box. Points convert to a DAI value at distribution time (`pointPrice`). |
| **DAILY_CAP** | The per-day cap (15) on points a user can earn on one side before the excess is burned — an anti-runaway mechanism. |
| **Daily distribution cycle (`processDaily`)** | The once-per-24h, gas-bounded, **resumable** routine that prices points and pays the day's pool. A cursor persists progress so no single transaction can be griefed to the gas limit. |
| **Reserve ticket** | A time-boxed credit toward a future box upgrade; expires and is burned (`processExpiredReserves`) if unused. |
| **Auto-upgrade** | Automatic promotion to the next box once a user's accrual qualifies. |
| **Cap (lifetime entitlement)** | `totalPaidAllBoxes` — the ceiling on what a subscriber can earn; prevents gaming lifetime rewards via repeated exit/rejoin. |
| **StepClub** | The loyalty club: members share a STEP pool in batched 30-day rounds, with auto-exit at cap and a trustless exit-to-subscription conversion. |
| **Exit-to-subscription** | On club exit, the forfeited cap-gap (in DAI) is converted on-chain into free subscription months — no payment, no admin trust. |
| **StepSubscription** | USD-priced access plans (1/3/6/12 months) settled in STEP or DAI; also the source of truth for "is this user's access active?". |
| **DAO (StepRegistry)** | The on-chain governance + address book. After `activateDao()`, every address/parameter change must pass vote → veto → timelock. |
| **Controller** | The bootstrap admin. Before `activateDao` it seeds addresses; after, it holds only a **veto** until `renounceControl()` removes even that (one-way). |
| **Veto window** | The period after a proposal passes during which the controller can block it — a circuit-breaker, not a mutation power. |
| **Timelock** | A mandatory delay before a passed, un-vetoed proposal can execute, giving the community time to react. |
| **Dynamic threshold / quorum** | The voting bar that scales with the live Box-0 population, so it can't be cleared by a few accounts as the network grows. |
| **Terms-of-Service acceptance** | An on-chain acknowledgement (`acceptTerms`) that value-moving contracts require via `requireTermsAccepted`. |
| **Levy whitelist** | A 2-slot registry list of addresses exempt from the STEP levy, changeable only through a DAO proposal. |
| **Treasury / wallet90 / wallet10** | Destinations for protocol revenue and NFT-sale STEP splits (90% / 10%). |
