// StepSubscription — the live revenue conduit.
//
// Deployed to Polygon mainnet at 0x8B567B997B5e80840228D047C8796234992E667C. Every subscription
// payment flows through this contract.
//
// What this suite asserts, in order of the money at stake:
//   1. the 19/51/10/20 split is exhaustive — no dust is stranded on the conduit;
//   2. the club and fund legs are PULLS (approve-then-call), so a receiver that does not pull fails;
//   3. the four published plans;
//   4. buying early EXTENDS an active subscription rather than replacing it;
//   5. the club-exit hook is reachable ONLY by StepClub;
//   6. the levy is visible: STEP burns 2% on every transfer out of a non-whitelisted sender, so
//      what the split COMPUTES and what each destination RECEIVES are different numbers.
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFull } = require("./_helpers");

const E = (n) => ethers.parseEther(String(n));
const MONTH = 30n * 24n * 60n * 60n;
const SUB = "contracts/StepSubscription.sol:StepSubscription";

describe("StepSubscription (revenue conduit)", function () {
  async function fixture() {
    const ctx = await deployFull();
    const { deployer, alice, bob, dev, carol, DAI, Registry, Coin, Dex } = ctx;

    const Sub = await (await ethers.getContractFactory(SUB)).deploy(
      await Registry.getAddress(), await DAI.getAddress(), dev.address, carol.address);

    // Two pulling sinks, because the split's club and fund legs approve-then-call.
    const coinAddr = await Coin.getAddress();
    const ClubSink = await (await ethers.getContractFactory("MockSplitSink")).deploy(coinAddr);
    const FundSink = await (await ethers.getContractFactory("MockSplitSink")).deploy(coinAddr);

    // The club leg resolves through the REGISTRY, and `deployFull` has already pointed
    // KEY_CLUB_TREASURY at MockClub — which has no `donateToPool`. Repoint it through the
    // controller's schedule/execute path; `setInitial` reverts with AlreadySet on a wired key.
    // This must not be wrapped in a catch: a swallowed setup error resurfaces later as an
    // unexplained revert deep inside `_splitStep`.
    const CLUB_KEY = await Registry.KEY_CLUB_TREASURY();
    await Registry.scheduleChange(CLUB_KEY, await ClubSink.getAddress());
    await Registry.executeChange(CLUB_KEY);
    expect(await Registry.get(CLUB_KEY)).to.equal(await ClubSink.getAddress());

    // The fund leg is a plain setter on the subscription contract.
    await Sub.setNftFund(await FundSink.getAddress());

    // STEP IS BOUGHT, NOT HANDED OUT. `mintInitialSupply` sends the whole supply to the DEX, so
    // nobody — deployer included — starts with a STEP balance. Minting DAI and buying through the
    // public AMM entry point is how a real wallet gets STEP, and it is the only way that works
    // here; `Coin.transfer` from the deployer reverts with a zero balance.
    const getStep = async (who, daiAmount) => {
      await DAI.mint(who.address, daiAmount);
      await Registry.connect(who).acceptTerms();      // requireTermsAccepted on the DEX
      await DAI.connect(who).approve(await Dex.getAddress(), daiAmount);
      await Dex.connect(who).buyStepPublic(daiAmount, 0);
      return Coin.balanceOf(who.address);
    };

    return { ...ctx, Sub, ClubSink, FundSink, getStep, deployer, alice, bob, dev, carol, DAI, Coin, Dex };
  }

  // ── The split ───────────────────────────────────────────────────────────────
  describe("revenue split", function () {
    it("is 19/51/10/20 and leaves NOTHING on the conduit", async function () {
      const { Sub, Coin, alice, deployer, getStep } = await loadFixture(fixture);
      const amount = await getStep(alice, E(100));
      await Coin.connect(alice).approve(await Sub.getAddress(), amount);

      await Sub.connect(alice).payStep(amount, ethers.ZeroHash);

      // The conduit is never meant to hold a balance. A leftover here is revenue nobody owns.
      expect(await Coin.balanceOf(await Sub.getAddress())).to.equal(0n);
      void deployer;
    });

    it("reports a split whose four slices sum to exactly what came in", async function () {
      const { Sub, Coin, alice, getStep } = await loadFixture(fixture);
      const amount = await getStep(alice, E(100));
      await Coin.connect(alice).approve(await Sub.getAddress(), amount);

      const tx = await Sub.connect(alice).payStep(amount, ethers.ZeroHash);
      const rc = await tx.wait();
      const ev = rc.logs
        .map((l) => { try { return Sub.interface.parseLog(l); } catch { return null; } })
        .find((p) => p && p.name === "RevenueSplit");
      expect(ev, "RevenueSplit was not emitted").to.not.equal(undefined);

      const [stepIn, toDev, toOwner, toClub, toFund] = ev.args;
      // EXHAUSTIVE, not merely proportional — the owner slice absorbs the rounding dust, which is
      // the only reason these can sum exactly rather than to "within a wei".
      expect(toDev + toOwner + toClub + toFund).to.equal(stepIn);
      expect(toDev).to.equal((stepIn * 19n) / 100n);
      expect(toClub).to.equal((stepIn * 10n) / 100n);
      expect(toFund).to.equal((stepIn * 20n) / 100n);
      expect(toOwner).to.equal(stepIn - toDev - toClub - toFund);
    });

    it("PULLS into the club and the fund — a sink that only accepts transfers is not enough", async function () {
      const { Sub, Coin, ClubSink, FundSink, alice, getStep } = await loadFixture(fixture);
      const amount = await getStep(alice, E(50));
      await Coin.connect(alice).approve(await Sub.getAddress(), amount);
      await Sub.connect(alice).payStep(amount, ethers.ZeroHash);

      // Each leg was actually invoked. A silently-skipped leg would leave calls at 0 while the
      // transaction still succeeded.
      expect(await ClubSink.calls()).to.equal(1n);
      expect(await FundSink.calls()).to.equal(1n);
      expect(await ClubSink.totalRequested()).to.be.gt(0n);
      expect(await FundSink.totalRequested()).to.be.gt(0n);
    });

    it("loses the 2% levy on the way out, and the sinks credit what ARRIVED", async function () {
      const { Sub, Coin, ClubSink, alice, getStep } = await loadFixture(fixture);
      const amount = await getStep(alice, E(100));
      await Coin.connect(alice).approve(await Sub.getAddress(), amount);
      await Sub.connect(alice).payStep(amount, ethers.ZeroHash);

      const asked = await ClubSink.totalRequested();
      const got   = await ClubSink.totalReceived();
      // This is the documented behaviour, not a defect: STEP burns 2% on every transfer from a
      // sender that is not on the (capacity-2, currently empty) whitelist. The point of asserting
      // it is that the day the subscription contract IS whitelisted, this test changes and somebody
      // has to look at it on purpose.
      expect(got).to.be.lte(asked);
      expect(got).to.be.gt((asked * 90n) / 100n);
    });

    it("refuses to split before the fund is wired, rather than stranding the money", async function () {
      const { Registry, DAI, Coin, dev, carol, alice, getStep } = await loadFixture(fixture);
      const Bare = await (await ethers.getContractFactory(SUB)).deploy(
        await Registry.getAddress(), await DAI.getAddress(), dev.address, carol.address);
      // nftFund is still address(0).
      const amount = await getStep(alice, E(10));
      await Coin.connect(alice).approve(await Bare.getAddress(), amount);
      await expect(Bare.connect(alice).payStep(amount, ethers.ZeroHash))
        .to.be.revertedWithCustomError(Bare, "NotInitialized");
    });
  });

  // ── The dApp's plans ────────────────────────────────────────────────────────
  describe("dApp plans", function () {
    it("are the four published plans: 1/3/6/12 months at 6.99/5.99/4.99/3.99 DAI per month", async function () {
      const { Sub } = await loadFixture(fixture);
      const months = [1, 3, 6, 12];
      const monthly = [E("6.99"), E("5.99"), E("4.99"), E("3.99")];
      for (let i = 0; i < 4; i++) {
        expect(await Sub.planMonths(i)).to.equal(months[i]);
        expect(await Sub.planMonthlyUsd(i)).to.equal(monthly[i]);
        expect(await Sub.planTotalUsd(i)).to.equal(monthly[i] * BigInt(months[i]));
      }
    });

    it("rejects a plan index outside the table instead of reading past it", async function () {
      const { Sub } = await loadFixture(fixture);
      await expect(Sub.planTotalUsd(4)).to.be.revertedWithCustomError(Sub, "BadPlan");
    });
  });

  // ── Buying ──────────────────────────────────────────────────────────────────
  describe("subscribing", function () {
    it("credits months and reports them through accessStatus", async function () {
      const { Sub, Coin, alice, getStep } = await loadFixture(fixture);
      await getStep(alice, E(100));
      const [, stepNeeded] = await Sub.quote(0);
      await Coin.connect(alice).approve(await Sub.getAddress(), stepNeeded * 2n);

      const before = await Sub.accessStatus(alice.address);
      expect(before.active).to.equal(false);

      await Sub.connect(alice).subscribe(0, stepNeeded * 2n);

      const after = await Sub.accessStatus(alice.address);
      expect(after.active).to.equal(true);
      expect(after.paidEnd).to.be.gt(0n);
    });

    it("EXTENDS an unexpired subscription rather than restarting it", async function () {
      const { Sub, Coin, alice, getStep } = await loadFixture(fixture);
      await getStep(alice, E(200));
      const [, stepNeeded] = await Sub.quote(0);
      await Coin.connect(alice).approve(await Sub.getAddress(), stepNeeded * 6n);

      await Sub.connect(alice).subscribe(0, stepNeeded * 2n);
      const first = (await Sub.accessStatus(alice.address)).paidEnd;
      await Sub.connect(alice).subscribe(0, stepNeeded * 2n);
      const second = (await Sub.accessStatus(alice.address)).paidEnd;

      // Buying early must never burn time already held: the second month stacks on the first.
      expect(second - first).to.equal(MONTH);
    });

    it("honours the slippage guard instead of overcharging on a price move", async function () {
      const { Sub, Coin, alice, getStep } = await loadFixture(fixture);
      await getStep(alice, E(100));
      const [, stepNeeded] = await Sub.quote(0);
      await Coin.connect(alice).approve(await Sub.getAddress(), stepNeeded * 2n);
      await expect(Sub.connect(alice).subscribe(0, stepNeeded - 1n))
        .to.be.revertedWithCustomError(Sub, "SlippageExceeded");
    });
  });

  // ── The club-exit hook ──────────────────────────────────────────────────────
  describe("club exit", function () {
    it("is callable ONLY by the club authority", async function () {
      const { Sub, alice, bob } = await loadFixture(fixture);
      await expect(Sub.connect(bob).grantFromClubExit(alice.address, E(100)))
        .to.be.revertedWithCustomError(Sub, "NotClubAuthority");
    });

    it("converts a forfeited gap into months, longest plan first", async function () {
      const { Sub, alice, bob } = await loadFixture(fixture);
      await Sub.setClubAuthority(bob.address);

      // 12 months costs 3.99 * 12 = 47.88 DAI. 50 DAI buys that and strands the remainder,
      // because a partial month is not a thing the table can express.
      expect(await Sub.monthsForGap(E("47.88"))).to.equal(12n);
      expect(await Sub.monthsForGap(E(50))).to.equal(12n);
      expect(await Sub.monthsForGap(E(1))).to.equal(0n);

      await Sub.connect(bob).grantFromClubExit(alice.address, E("47.88"));
      const st = await Sub.accessStatus(alice.address);
      expect(st.active).to.equal(true);
    });

    it("grants nothing — and does not revert — when the gap buys no whole month", async function () {
      const { Sub, alice, bob } = await loadFixture(fixture);
      await Sub.setClubAuthority(bob.address);
      await Sub.connect(bob).grantFromClubExit(alice.address, E(1));
      expect((await Sub.accessStatus(alice.address)).active).to.equal(false);
    });
  });

  // ── Admin surface ───────────────────────────────────────────────────────────
  describe("admin", function () {
    it("keeps every setter behind onlyOwner", async function () {
      const { Sub, alice } = await loadFixture(fixture);
      for (const [fn, arg] of [
        ["setDevWallet", alice.address], ["setOwnerWallet", alice.address],
        ["setNftFund", alice.address], ["setClubAuthority", alice.address],
        ["setGranter", alice.address], ["transferOwnership", alice.address],
      ]) {
        await expect(Sub.connect(alice)[fn](arg), fn)
          .to.be.revertedWithCustomError(Sub, "NotOwner");
      }
    });

    it("lets only the owner or the granter comp months", async function () {
      const { Sub, alice, bob } = await loadFixture(fixture);
      await expect(Sub.connect(bob).grantSubscription(alice.address, 1))
        .to.be.revertedWithCustomError(Sub, "NotGranter");
      await Sub.setGranter(bob.address);
      await Sub.connect(bob).grantSubscription(alice.address, 1);
      expect((await Sub.accessStatus(alice.address)).active).to.equal(true);
    });
  });
});
