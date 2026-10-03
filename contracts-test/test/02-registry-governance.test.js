const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

// ─────────────────────────────────────────────────────────────────────────────
// StepRegistry — DAO governance lifecycle.
//
// The review flagged the full createProposal → vote → veto → execute path as the
// most dangerous untested surface. This suite exercises the happy path, the
// timelock windows, the controller veto, the proposer/voter eligibility gates,
// and the anti-flash-recruit snapshot cap.
// ─────────────────────────────────────────────────────────────────────────────

const DAY = 24 * 60 * 60;
const VOTING_PERIOD = 7 * DAY;
const VETO_WINDOW = 7 * DAY;

async function deployGov() {
  const [controller, proposer, voter, outsider, newDev] = await ethers.getSigners();

  const Registry = await (await ethers.getContractFactory("StepRegistry")).deploy(controller.address);
  const Coin = await (await ethers.getContractFactory("StepCoin")).deploy(await Registry.getAddress());
  const Dao = await (await ethers.getContractFactory("MockDAO")).deploy();

  // Bootstrap wiring. STEP_COIN is needed for whitelist-execution proposals.
  await Registry.setInitial(await Registry.KEY_STEP_COIN(), await Coin.getAddress());
  await Registry.setInitial(await Registry.KEY_DEV_TREASURY(), controller.address); // some non-zero start

  // Point both StepNet and StepNetView at the mock, then turn the DAO on.
  await Registry.setStepNet(await Dao.getAddress());
  await Registry.setStepNetView(await Dao.getAddress());
  await Registry.activateDao();

  return { Registry, Coin, Dao, controller, proposer, voter, outsider, newDev };
}

// Make `proposer` able to propose and `voter` able to carry the vote.
async function seedElectorate(Dao, proposer, voter, { box0Count = 10, weaker = 9 } = {}) {
  await Dao.setActiveBox0Count(box0Count);
  await Dao.setBox5(proposer.address, true);
  const now = await time.latest();
  // voter registered well before any proposal → eligible.
  await Dao.setVoter(voter.address, weaker, now - DAY);
  await Dao.setBox0(proposer.address, true);
}

describe("StepRegistry — governance happy path", () => {
  it("create → vote (pass) → wait timelocks → execute changes the address", async () => {
    const { Registry, Dao, proposer, voter, newDev } = await deployGov();
    await seedElectorate(Dao, proposer, voter);

    const KEY = await Registry.KEY_DEV_TREASURY();
    const tx = await Registry.connect(proposer).createProposal(KEY, newDev.address);
    const rc = await tx.wait();
    const id = 1n;

    // threshold = ceil(51% of 10) = 6; voter weight = 1 + weaker(9) capped @10 = 10 ≥ 6.
    await expect(Registry.connect(voter).vote(id)).to.emit(Registry, "ProposalPassed");

    // Cannot execute during voting.
    await expect(Registry.executeProposal(id)).to.be.reverted;

    // Advance past voting (7d) + veto window (7d), still within expiry.
    await time.increase(VOTING_PERIOD + VETO_WINDOW + DAY);

    await expect(Registry.executeProposal(id))
      .to.emit(Registry, "ProposalExecuted");
    expect(await Registry.get(KEY)).to.equal(newDev.address);
  });

  it("vote weight is capped at the creation-time snapshot (anti-flash-recruit)", async () => {
    const { Registry, Dao, proposer, voter, newDev } = await deployGov();
    // Snapshot box0Count = 3, but give the voter an absurd live weaker-side.
    await seedElectorate(Dao, proposer, voter, { box0Count: 3, weaker: 1_000_000 });

    const KEY = await Registry.KEY_DEV_TREASURY();
    await Registry.connect(proposer).createProposal(KEY, newDev.address);
    await Registry.connect(voter).vote(1n);

    // Weight must be capped to the snapshot (3), NOT 1 + 1,000,000.
    expect(await Registry.voterWeight(1n, voter.address)).to.equal(3n);
  });
});

describe("StepRegistry — guards & timelocks", () => {
  it("rejects proposals from non-Box5 callers", async () => {
    const { Registry, Dao, voter, newDev } = await deployGov();
    await Dao.setActiveBox0Count(10);
    const KEY = await Registry.KEY_DEV_TREASURY();
    await expect(Registry.connect(voter).createProposal(KEY, newDev.address))
      .to.be.revertedWithCustomError(Registry, "NotEligibleToPropose");
  });

  it("rejects changing immutable coupled keys (STEP_DEX) via createProposal", async () => {
    const { Registry, Dao, proposer, newDev } = await deployGov();
    await Dao.setBox5(proposer.address, true);
    const KEY = await Registry.KEY_STEP_DEX();
    await expect(Registry.connect(proposer).createProposal(KEY, newDev.address))
      .to.be.revertedWithCustomError(Registry, "KeyIsImmutable");
  });

  it("rejects voters who registered AFTER proposal creation", async () => {
    const { Registry, Dao, proposer, outsider, newDev } = await deployGov();
    await Dao.setActiveBox0Count(10);
    await Dao.setBox5(proposer.address, true);

    const KEY = await Registry.KEY_DEV_TREASURY();
    await Registry.connect(proposer).createProposal(KEY, newDev.address);

    // outsider becomes box0 but with a start timestamp AFTER createdAt.
    const now = await time.latest();
    await Dao.setVoter(outsider.address, 100, now + 1);
    await expect(Registry.connect(outsider).vote(1n))
      .to.be.revertedWithCustomError(Registry, "VoterNotPreExisting");
  });

  it("a proposal that never reaches threshold cannot be executed", async () => {
    const { Registry, Dao, proposer, voter, newDev } = await deployGov();
    // box0Count = 100 → threshold = 51; voter weight only 1 + 1 = 2 < 51.
    await seedElectorate(Dao, proposer, voter, { box0Count: 100, weaker: 1 });

    const KEY = await Registry.KEY_DEV_TREASURY();
    await Registry.connect(proposer).createProposal(KEY, newDev.address);
    await Registry.connect(voter).vote(1n);

    await time.increase(VOTING_PERIOD + VETO_WINDOW + DAY);
    await expect(Registry.executeProposal(1n))
      .to.be.revertedWithCustomError(Registry, "ProposalNotPassed");
  });

  it("controller can veto a passed proposal inside the veto window, blocking execution", async () => {
    const { Registry, Dao, controller, proposer, voter, newDev } = await deployGov();
    await seedElectorate(Dao, proposer, voter);

    const KEY = await Registry.KEY_DEV_TREASURY();
    const before = await Registry.get(KEY);
    await Registry.connect(proposer).createProposal(KEY, newDev.address);
    await Registry.connect(voter).vote(1n);

    // Move past voting end, into the veto window.
    await time.increase(VOTING_PERIOD + DAY);
    await expect(Registry.connect(controller).vetoProposal(1n))
      .to.emit(Registry, "ProposalVetoed");

    // Past the veto window, execution must fail (proposal is vetoed).
    await time.increase(VETO_WINDOW);
    await expect(Registry.executeProposal(1n))
      .to.be.revertedWithCustomError(Registry, "ProposalNotPassed");
    expect(await Registry.get(KEY)).to.equal(before); // unchanged
  });

  it("non-controller cannot veto", async () => {
    const { Registry, Dao, proposer, voter, newDev } = await deployGov();
    await seedElectorate(Dao, proposer, voter);
    const KEY = await Registry.KEY_DEV_TREASURY();
    await Registry.connect(proposer).createProposal(KEY, newDev.address);
    await Registry.connect(voter).vote(1n);
    await time.increase(VOTING_PERIOD + DAY);
    await expect(Registry.connect(proposer).vetoProposal(1n))
      .to.be.revertedWithCustomError(Registry, "Unauthorized");
  });
});
