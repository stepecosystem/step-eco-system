const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

// ─────────────────────────────────────────────────────────────────────────────
// StepNet — box activation split + processDaily cycle.
//
// Covers the "precise plan math" of an activation: of the 25 DAI Box-0 fee,
// 18% (5+5+3+5) is converted to STEP and split to user/dev/nft/club, and the
// remaining 82% accumulates in the tier's daily-distribution pool. Also a smoke
// test that a full processDaily cycle completes.
//
// StepNet links 5 libraries (Reserve/Wallet/Pending/Import/ClubSync); we deploy
// them in dependency order (WalletLib needs ReserveLib) and link via the factory.
// ─────────────────────────────────────────────────────────────────────────────

const E = (n) => ethers.parseEther(String(n));
const PRECISION = 10n ** 18n;

async function deployLibs() {
  const Reserve = await (await ethers.getContractFactory("ReserveLib")).deploy();
  const reserveAddr = await Reserve.getAddress();
  const Wallet = await (
    await ethers.getContractFactory("WalletLib", {
      libraries: { "contracts/StepNetLib.sol:ReserveLib": reserveAddr },
    })
  ).deploy();
  const Pending = await (await ethers.getContractFactory("PendingLib")).deploy();
  const Import = await (await ethers.getContractFactory("ImportLib")).deploy();
  const ClubSync = await (await ethers.getContractFactory("ClubSyncLib")).deploy();
  return {
    "contracts/StepNetLib.sol:ReserveLib": reserveAddr,
    "contracts/StepNetLib.sol:WalletLib": await Wallet.getAddress(),
    "contracts/StepNetLib.sol:PendingLib": await Pending.getAddress(),
    "contracts/StepNetLib.sol:ImportLib": await Import.getAddress(),
    "contracts/StepNetLib.sol:ClubSyncLib": await ClubSync.getAddress(),
  };
}

async function deployFull() {
  const [deployer, alice, bob, dev] = await ethers.getSigners();

  const DAI = await (await ethers.getContractFactory("MockERC20")).deploy("Mock DAI", "DAI", 18);
  const Registry = await (await ethers.getContractFactory("StepRegistry")).deploy(deployer.address);
  const Coin = await (await ethers.getContractFactory("StepCoin")).deploy(await Registry.getAddress());
  const Dex = await (await ethers.getContractFactory("StepDex")).deploy(
    await Registry.getAddress(),
    await DAI.getAddress()
  );
  const libs = await deployLibs();
  const Net = await (
    await ethers.getContractFactory("StepNet", { libraries: libs })
  ).deploy(await Registry.getAddress(), await DAI.getAddress());
  const Club = await (await ethers.getContractFactory("MockClub")).deploy();
  const NFT = await (await ethers.getContractFactory("MockNFT")).deploy();

  // Registry wiring (bootstrap, controller = deployer).
  const R = Registry;
  await R.setInitial(await R.KEY_STEP_COIN(), await Coin.getAddress());
  await R.setInitial(await R.KEY_STEP_DEX(), await Dex.getAddress());
  await R.setInitial(await R.KEY_STEP_NET(), await Net.getAddress());
  await R.setInitial(await R.KEY_NFT_TREASURY(), await NFT.getAddress());
  await R.setInitial(await R.KEY_CLUB_TREASURY(), await Club.getAddress());
  await R.setInitial(await R.KEY_DEV_TREASURY(), dev.address);

  // Genesis STEP into the DEX + seed the reserve so buys mint at a real price.
  await Coin.mintInitialSupply();
  const seed = E(1000);
  await DAI.mint(deployer.address, seed);
  await DAI.approve(await Dex.getAddress(), seed);
  await Dex.donateLiquidity(seed);

  // Turn StepNet on (requires step/dex/nft/dev/club all wired).
  await Net.finalizeSetup();

  return { deployer, alice, bob, dev, DAI, Registry, Coin, Dex, Net, Club, NFT };
}

// Helper: give `user` terms + DAI and activate Box-0 under `referrer`.
async function activate(ctx, user, referrer) {
  const { Registry, DAI, Net } = ctx;
  await Registry.connect(user).acceptTerms();
  await DAI.mint(user.address, E(25));
  await DAI.connect(user).approve(await Net.getAddress(), E(25));
  await Net.connect(user).activateBox(referrer.address);
}

describe("StepNet — deploy & init", () => {
  it("deploys with all 5 libraries linked and finalizes setup", async () => {
    const ctx = await deployFull();
    expect(await ctx.Net.initialized()).to.equal(true);
    // Founder (deployer) is pre-seeded as the tree root with one Box-0.
    expect(await ctx.Net.activeBox0Count()).to.equal(1n);
  });
});

describe("StepNet — Box-0 activation split (25 DAI)", () => {
  it("routes 82% to the tier pool and 18% to STEP conversion", async () => {
    const ctx = await deployFull();
    const { Net, deployer, alice } = ctx;

    const poolBefore = (await Net.pools(0)).accumulatedDai;
    await activate(ctx, alice, deployer);

    // forStep = (5+5+3+5)% = 18% of 25 = 4.5 DAI; pool gets the other 82% = 20.5.
    const poolAfter = (await Net.pools(0)).accumulatedDai;
    expect(poolAfter - poolBefore).to.equal(E(20.5));
  });

  it("registers the new user under the referrer and counts a Box-0", async () => {
    const ctx = await deployFull();
    const { Net, deployer, alice } = ctx;

    await activate(ctx, alice, deployer);

    expect(await Net.activeBox0Count()).to.equal(2n);
    // Alice is placed as a child of the founder, with the founder as upline.
    const aliceU = await Net.users(alice.address);
    expect(aliceU.upline).to.equal(deployer.address);
    const founderU = await Net.users(deployer.address);
    expect([founderU.left, founderU.right]).to.include(alice.address);
  });

  it("dev treasury receives STEP from the 5% dev share (net of 2% levy)", async () => {
    const ctx = await deployFull();
    const { Net, Coin, deployer, alice, dev } = ctx;

    expect(await Coin.balanceOf(dev.address)).to.equal(0n);
    await activate(ctx, alice, deployer);
    // Dev got a non-zero STEP payout (exact amount depends on curve price;
    // the point is the 5% dev leg actually delivers STEP).
    expect(await Coin.balanceOf(dev.address)).to.be.gt(0n);
  });
});

describe("StepNet — processDaily", () => {
  it("reverts TooEarly before the 24h interval, then completes a full cycle", async () => {
    const ctx = await deployFull();
    const { Net, deployer, alice, bob } = ctx;

    // Build a tiny tree so there is something to process.
    await activate(ctx, alice, deployer);
    await activate(ctx, bob, deployer);

    // First cycle can run anytime after deploy; run it to set the timer.
    await Net.processDaily();
    expect(await Net.globalCycleStep()).to.equal(0n); // cycle completed

    // Immediately running again is too early.
    await expect(Net.processDaily()).to.be.revertedWithCustomError(Net, "TooEarly");

    // After 24h it runs again and completes.
    await time.increase(24 * 60 * 60 + 1);
    await Net.processDaily();
    expect(await Net.globalCycleStep()).to.equal(0n);
  });
});
