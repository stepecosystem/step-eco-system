# 📑 Contract Interface Reference

A complete, source-derived reference to the **external/public API, events, errors, and
key constants** of every production contract. For the narrative *why* behind each
mechanism, see the per-contract deep dives linked from [`docs/README.md`](README.md).

> All contracts are `SPDX-License-Identifier: UNLICENSED` · Solidity `0.8.35` · proprietary (see [`LICENSE`](../LICENSE)).
> Every value-moving entry-point is `nonReentrant`; failures use custom errors (no revert strings).

---

## StepNet — core engine
> [`contracts/StepNet.sol`](../contracts/StepNet.sol) · deep dive: [StepNet.md](StepNet.md)

**Constants / immutables:** `BOX_COUNT`, `BOX_PRICE_0`, `IMPORT_WINDOW`, `DAI`, `REGISTRY`, `originalDeployer`, `deployedAt`.

**External / public functions**
```solidity
// Activation & upgrades
function activateBox(address referrer) external;
function activateBoxFor(address forUser, address referrer) external;
function activateNextBoxManually() external;
function activateNextBoxManuallyFor(address forUser) external;
function processAutoUpgrades() external;

// Daily distribution cycle
function processDaily() external;
function processAllPendingUpdates(uint256 maxUsersPerBox) external;
function processExpiredReserves(uint256 maxUsers) external;
function checkAndBurnExpiredReserve(address ua) external;

// Rewards & wallet
function withdrawAllBoxReward(uint256 boxId) external;
function changeWallet(address newWallet) external;

// Club sync (StepNet ⇄ StepClub)
function setUserInClub(address ua, bool value) external;
function syncClubMembers(uint256 startIdx, uint256 endIdx) external;
function addStepReceivedFromClub(address ua, uint256 amount) external;
function addStepBurnedFromClub(address ua, uint256 amount) external;

// Tree / import / setup
function finalizeSetup() external;
function setImporter(address _imp) external;
function importSingleUser(ImportUserData calldata d) external;
function rebuildBox0Subtree(uint256 startIdx, uint256 endIdx) external;
function migrateAssetsTo(address newContract) external;

// Views
function getBoxData(address ua) external view;        function getUserClubData(address ua) external view;
function getBox0Subtree(address ua) external view;    function getBox0SubtreeWeakerSide(address ua) external view;
function getActiveBox0Count() external view;          function getActiveUsersCount() external view;
function getUserStartTimestamp(address ua) external view;
function hasBox0(address user) external view;         function hasBox5(address user) external view;
function getReserveTicketsLength(address ua) external view;
function getPendingUpdatesLength(uint256 boxId) external view;
function getPendingUpgradeListLength() external view;
```

**Events:** `BoxActivated`, `AutoUpgrade`, `PointsClaimed`, `DailyPointsBurned`, `DailyPoolDistributed`, `WalletChanged`, `BoxRewardsWithdrawn`, `ReserveBurned`, `DailyCycleComplete`, `ClubHistorySynced`, `BoxProcessedNoActivity`, `CycleStarted`, `AssetsMigrated`.

---

## StepNetLib — gas-optimized libraries
> [`contracts/StepNetLib.sol`](../contracts/StepNetLib.sol) · deep dive: [StepNetLib.md](StepNetLib.md)

Five linked libraries (`ReserveLib`, `WalletLib`, `PendingLib`, `ImportLib`, `ClubSyncLib`) powering reserve tickets, wallet migration, tree propagation, and batch import.

**Errors:** `ZeroAddress`, `SameWallet`, `NewWalletUsed`, `MaxChanges`, `NotRegistered`, `OnlyDeployer`, `BatchSizeInvalid`, `ImportClosed`.
**Events:** `WalletChanged`, `DailyPointsBurned`, `ClubHistorySynced`.

---

## StepNetView — read-only aggregator
> [`contracts/StepNetView.sol`](../contracts/StepNetView.sol) · deep dive: [StepNetView.md](StepNetView.md)

A stateless view layer that packs whole dashboards into single calls (no value movement).

**External / public functions**
```solidity
function getMasterDashboard(address ua) external view;   function getFullUserData(address ua) external view;
function getGlobalStats() external view;                 function getTimersDashboard(address ua) external view;
function getBox0Timer() external view;                   function getClubTimerData(address ua) external view;
function getDailyBoxStatus(uint256 boxId) external view; function getLastPointValue(uint256 boxId) external view;
function getActiveUsersPage(uint256 offset, uint256 limit) external view;
function getActiveBox0Count() external view;             function getActiveUsersCount() external view;
function getBox0WeakerSide(address ua) external view;    function getTotalWeakerSide(address ua) external view;
function getBoxPrice(uint256 boxId) external view;       function getNextReserveBurnTime(address ua) external view;
function getPendingUpdatesCount(uint256 boxId) external view; function getPendingUpgradeCount() external view;
function getUserDailyBurnedPoints(address ua) external view;  function getImportWindowStatus() external view;
function getUserStartTimestamp(address user) external view;   function hasBox0(address) external view; function hasBox5(address) external view;
function estimateBuy(uint256 daiAmount) external view;   function estimateSell(uint256 stepAmount) external view;
// Community message (admin-gated) + keeper helper
function updateCommunityMessage(string calldata msg_, string calldata ipfs_) external;
function transferMessageAdmin(address newAdmin) external;
function burnExpiredReservesBatch(address[] calldata userList) external;
```
**Events:** `CommunityMessageUpdated`, `MessageAdminTransferred`. **Errors:** `ZeroAddress`, `Unauthorized`, `InvalidBox`.

---

## StepCoin — the STEP token
> [`contracts/StepCoin.sol`](../contracts/StepCoin.sol) · deep dive: [StepCoin.md](StepCoin.md)

DAI-backed, dynamic-supply ERC-20 with a deflationary **2% transfer levy** (exempt on mint/burn and for whitelisted system addresses). Standard ERC-20 methods (`transfer`, `approve`, …) are inherited.

**Constant:** `MAX_WHITELIST = 2`. **Immutables:** `REGISTRY`, `originalDeployer`.

```solidity
function mintInitialSupply() external;                 // one-time, mints supply to the DEX
function mint(address to, uint256 amount) external;    // DEX-only (bonding curve)
function burn(uint256 amount) external;
function burnFromDex(address from, uint256 amount) external;
function addToWhitelist(address account) external;     // registry/DAO-gated
function removeFromWhitelist(address account) external;
function getWhitelist() external view returns (address[2] memory);
function migrateAssetsTo(address newContract) external;
```
**Events:** `TokensBurned`, `InitialSupplyMinted`, `AddedToWhitelist`, `RemovedFromWhitelist`, `AssetsMigrated`.
**Errors:** `NotDex`, `ZeroAddress`, `AlreadyMinted`, `Unauthorized`, `WhitelistFull`, `NotWhitelisted`, `AlreadyWhitelisted`.

---

## StepDex — bonding-curve AMM
> [`contracts/StepDex.sol`](../contracts/StepDex.sol) · deep dive: [StepDex.md](StepDex.md)

STEP ⇄ DAI where **price = DAI reserve ÷ STEP supply**, with a price floor. Immutables: `REGISTRY`, `DAI`.

```solidity
function getPrice() public view returns (uint256);                       // DAI per STEP, 1e18
function estimateBuy(uint256 daiAmount) external view returns (uint256);  function estimateSell(uint256 stepAmount) external view returns (uint256);
function buyStep(uint256 daiAmount, uint256 minStepOut) external;         // system contracts only
function buyStepPublic(uint256 daiAmount, uint256 minStepOut) external;   // terms-gated
function sellStep(uint256 stepAmount, uint256 minDaiOut) external;        function sellAll(uint256 minDaiOut) external;
function donateLiquidity(uint256 daiAmount) external;                     function donateAndBurnStep(uint256 stepAmount) external;
function getDaiBalance() external view returns (uint256);                 function isInitialized() external view returns (bool);
function migrateAssetsTo(address newContract) external;
```
**Events:** `Buy`, `Sell`, `LiquidityDonated`, `StepDonatedAndBurned`, `PriceFloorActivated`, `AssetsMigrated`.
**Errors:** `ZeroAddress`, `NotAuthorized`, `ZeroAmount`, `NotSystemContract`, `NotInitialized`, `NoLiquidity`, `InsufficientDAI`, `SlippageExceeded`, `TermsNotAccepted`.

---

## StepNFTTreasury — tiered NFT + reward pool
> [`contracts/StepNFTTreasury.sol`](../contracts/StepNFTTreasury.sol) · deep dive: [StepNFTTreasury.md](StepNFTTreasury.md)

ERC-721 with a fixed tiered price curve, an on-chain STEP reward pool, and legacy-NFT migration. Immutables: `REGISTRY`, `DAI`, `wallet90`, `wallet10`.

**Constants:** `TOTAL_SUPPLY = 1000`, `SWAP_END_ID = 300`, `MAX_SWAPPABLE_TIER_ID = 300`, `MAX_BATCH_SWAP = 50`, `DISTRIBUTION_INTERVAL = 24 hours`, `CLAIM_DEADLINE = 30 days`, `DIST_BATCH_SIZE = 500`.

```solidity
function buy(uint256 maxPrice) external;                              function buyMultiple(uint256 quantity, uint256 maxTotalPrice) external;
function getPrice(uint256 id) public pure returns (uint256);         function getCurrentPrice() external view returns (uint256);
function swapNFT(uint256 oldTokenId) external;                       function swapNFTBatch(uint256[] calldata oldTokenIds) external;
function distributeRewards() external;                              function claimRewards() external;
function addToRewardPool(uint256 amount) external;                   function donateToRewardPool(uint256 amount) external;
function setOldNFTContract(address _oldNFT, uint256 _maxOldTokenId) external; function setBaseURI(string calldata newURI) external;
function renounceOwnership() public;                                 function migrateAssetsTo(address newContract) external;
// Views: getRewardInfo, getUserDashboard, getDistributionStatus, getDistributions,
//        getTimeUntilNextDistribution, pendingOf, pendingOfPaginated, totalClaimedOf,
//        swapPoolInfo, getCurrentStepBalance, nextId.
```
**Events:** `Bought`, `StepDistributed`, `RewardsDeposited`, `RewardsDistributed`, `RewardClaimed`, `NFTSwapped`, `BatchNFTSwapped`, `OldNFTContractSet`, `TransferFeeCollected`, `TokensBurned`, `DistributionBatchProcessed`, `ExpiredRewardsBurned`, `BaseURIUpdated`, `AssetsMigrated`.
**Errors:** `SoldOut`, `PriceExceedsMax`, `NotEnoughLeft`, `InvalidQuantity`, `TooEarly`, `NoRewards`, `NothingToClaim`, `NotSwappableTier`, `SwapPoolFull`, `AlreadySwapped`, `TokenMintedAfterSnapshot`, `OldNFTNotSet`, `OldNFTAlreadySet`, `NotOldNFTOwner`, `DistributionInProgress`, `NothingToDistribute`, `ReservedAlreadyMinted`, `TermsNotAccepted`, `NotStepNet`, `NotAuthorized`, `ZeroAddress`, `ZeroAmount`, `NoNFTs`.

---

## StepClub — the loyalty club
> [`contracts/StepClub.sol`](../contracts/StepClub.sol) · deep dive: [StepClub.md](StepClub.md)

Membership cycle, batched distributions, auto-exit, and trustless exit-to-subscription. Immutables: `REGISTRY`, `SUBSCRIPTION`.

**Constants:** `DISTRIBUTION_INTERVAL = 30 days`, `CLAIM_DEADLINE = 10 days`, `DIST_BATCH_SIZE = 500`, `JOIN_FLUSH_BATCH = 200`.

```solidity
// Membership (StepNet-only)
function addMember(address ua) external;          function removeMember(address ua) external;
function transferMembership(address oldAddr, address newAddr) external;  function setClubHistory(address ua, uint256 received, uint256 burned) external;
// Distribution (keeper / anyone)
function processClubDistribution() external;       function donateToPool(uint256 amount) external;
function flushJoinQueueManual() external;          function flushRemovalQueueManual() external;
function sweepExpiredPending(address[] calldata accounts) external;
function checkAndExitIfAtCap(address ua) external; function checkAndExitIfAtCapBatch(address[] calldata accounts) external;
// User
function claim() external;                          function claimForUser(address ua) external;
function exit() external;                           function exitToSubscription() external returns (uint32);
function migrateAssetsTo(address newContract) external;
// Views: getClubDashboard, getClubStats, getClubPendingReward, getClubTimerData, getJoinQueueInfo, expiringPendingLength.
```
**Events:** `MemberAdded`, `MemberRemoved`, `MemberQueued`, `MembershipTransferred`, `PoolReceived`, `PoolDonated`, `ClubDistributionStarted`, `ClubDistributionFinalized`, `ClubDistributionSkipped`, `RewardClaimed`, `RewardBurned`, `VoluntaryExitCapCredit`, `ExitedToSubscription`, `ExpiringPendingQueued`, `AssetsMigrated`.
**Errors:** `NotMember`, `AlreadyMember`, `NoPendingReward`, `NothingToBurn`, `TooEarly`, `DistributionInProgress`, `InsufficientGas`, `NewAddrHasHistory`, `Unauthorized`, `NotAuthorized`, `ZeroAddress`, `ZeroAmount`.

---

## StepSubscription — AI-access plans
> [`contracts/StepSubscription.sol`](../contracts/StepSubscription.sol) · deep dive: [StepSubscription.md](StepSubscription.md)

USD-priced access plans, settled in STEP or DAI. Immutables: `STEP`, `DAI`, `DEX`, `NET`.
**Constants:** `TRIAL_DURATION = 30 days`, `MONTH = 30 days`, `PLAN_COUNT = 4`.

```solidity
function planTotalUsd(uint8 plan) public view returns (uint256);
function quote(uint8 plan) public view returns (uint256 usd, uint256 stepAmount);
function subscribe(uint8 plan, uint256 maxStep) external;     // pay in STEP (slippage-guarded)
function subscribeWithDai(uint8 plan) external;               // pay in DAI
function monthsForGap(uint256 gapDai) public view returns (uint32);
function grantFromClubExit(address user, uint256 gapDai) external returns (uint32);  // clubAuthority-only
function grantSubscription(address user, uint32 months) external returns (uint256);  // owner/granter
function setTreasury(address t) external;  function setClubAuthority(address c) external;  function setGranter(address g) external;
function setPlan(uint8 plan, uint32 months, uint256 monthlyUsd) external;  function transferOwnership(address n) external;
// Views: accessStatus(user), getPlans().
```
**Events:** `SubscribedWithDai`, `SubscriptionGranted`, `GrantedFromClubExit`, `TreasuryUpdated`, `PlanUpdated`, `ClubAuthorityUpdated`, `GranterUpdated`, `OwnershipTransferred`.
**Errors:** `NotOwner`, `BadPlan`, `ZeroAddress`, `PriceUnavailable`, `SlippageExceeded`, `NotClubAuthority`, `NotGranter`, `ZeroMonths`.

---

## StepRegistry — the DAO & address book
> [`contracts/StepRegistry.sol`](../contracts/StepRegistry.sol) · deep dive: [StepRegistry.md](StepRegistry.md)

The single source of truth for every contract address, governed by Box-0-weighted voting with a vote → veto → timelock flow. See the **Governance Status** section of the [README](../README.md) for the live on-chain stage.

**Constants:** `VOTING_PERIOD = 7 days`, `PROPOSAL_EXPIRY = 11 days`, `VETO_WINDOW = 7 days`; address keys `KEY_STEP_COIN`, `KEY_STEP_DEX`, `KEY_STEP_NET`, `KEY_STEP_NET_VIEW`, `KEY_NFT_TREASURY`, `KEY_CLUB_TREASURY`, `KEY_DEV_TREASURY`; `TERMS_OF_SERVICE`.

```solidity
// Address book
function get(bytes32 key) external view returns (address);     function getAllAddresses() external view;
// Bootstrap (controller, before DAO)
function setInitial(bytes32 key, address addr) external;       function setInitialBatch(bytes32[] calldata keys, address[] calldata addrs) external;
function setStepNet(address _stepNet) external;                function setStepNetView(address _stepNetView) external;
function scheduleChange(bytes32 key, address newAddress) external; function executeChange(bytes32 key) external; function cancelChange(bytes32 key) external;
// Decentralization (one-way)
function activateDao() external;   function transferControl(address newController) external;   function renounceControl() external;
// Governance — proposals
function createProposal(bytes32 key, address newAddress) external;
function createWhitelistAddProposal(address account) external;   function createWhitelistRemoveProposal(address account) external;
function vote(uint256 proposalId) external;   function vetoProposal(uint256 proposalId) external;   function executeProposal(uint256 proposalId) external;
// Governance — migration (paired)
function voteMigration(uint256 id) external;  function vetoMigration(uint256 id) external;  function executeMigration(uint256 id) external;
function setMigrationTimelock(uint256 newTimelock) external;
// Terms & views
function acceptTerms() external;   function hasAcceptedCurrentTerms(address user) external view returns (bool);
function getVotingPower(address user) external view;  function getCurrentThreshold() external view;  function getTotalBox0Count() external view;
function getProposal(uint256 proposalId) external view;  function getPendingChange(bytes32 key) external view;
```
**Events:** `AddressSet`, `ChangeScheduled`, `ChangeExecuted`, `ChangeCancelled`, `DaoActivated`, `ControlTransferred`, `ControlRenounced`, `StepNetUpdated`, `StepNetViewUpdated`, `ProposalCreated`, `Voted`, `ProposalPassed`, `ProposalExecuted`, `ProposalVetoed`, `WhitelistAddProposed`, `WhitelistRemoveProposed`, `WhitelistAddExecuted`, `WhitelistRemoveExecuted`, `TermsAccepted`, `MigrationProposed`, `MigrationVoted`, `MigrationPassed`, `MigrationVetoed`, `MigrationExecuted`, `MigrationTimelockUpdated`.
**Errors (selection):** `Unauthorized`, `DaoNotActive`, `KeyIsImmutable`, `NotEligibleToPropose`, `NotEligibleToVote`, `VoterNotPreExisting`, `AlreadyVoted`, `ProposalNotPassed`, `VetoWindowNotOpen`, `ControllerChangeBlockedAfterDaoActivation`, `ControlAlreadyRenounced`, `MustProposeAsPair`, `DelayNotPassed`, `TermsNotAccepted`.
