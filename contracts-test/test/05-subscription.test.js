const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { E, deployFull } = require("./_helpers");

// StepSubscription — paid access layer (DAI/STEP payment, grants, club-exit
// conversion). Deployed on top of the full StepNet wiring so the live DEX
// price feed and StepNet trial timestamps are real.
describe("StepSubscription", function () {
  let ctx, Sub, treasury, owner, alice, bob;
  const MONTH = 30n * 24n * 60n * 60n;

  beforeEach(async function () {
    ctx = await deployFull();
    owner = ctx.deployer; alice = ctx.alice; bob = ctx.bob; treasury = ctx.carol;
    Sub = await (await ethers.getContractFactory("StepSubscription")).deploy(
      await ctx.Coin.getAddress(),
      await ctx.DAI.getAddress(),
      await ctx.Dex.getAddress(),
      await ctx.Net.getAddress(),
      treasury.address
    );
  });

  describe("defaults & pricing", function () {
    it("ships the four documented plans (1/3/6/12 mo) and DAI totals", async function () {
      expect(await Sub.planTotalUsd(0)).to.equal(E("6.99"));        // 1 × 6.99
      expect(await Sub.planTotalUsd(1)).to.equal(E(String(5.99 * 3)));
      expect(await Sub.planTotalUsd(3)).to.equal(E(String(3.99 * 12)));
    });

    it("quote() reflects the live DEX price (STEP amount > 0)", async function () {
      const [usd, stepAmount] = await Sub.quote(0);
      expect(usd).to.equal(E("6.99"));
      expect(stepAmount).to.be.gt(0n);
    });
  });

  describe("subscribeWithDai", function () {
    it("pulls the plan's DAI straight to the treasury and marks the user PAID", async function () {
      await ctx.DAI.mint(alice.address, E("6.99"));
      await ctx.DAI.connect(alice).approve(await Sub.getAddress(), E("6.99"));

      const before = await ctx.DAI.balanceOf(treasury.address);
      await Sub.connect(alice).subscribeWithDai(0);
      expect(await ctx.DAI.balanceOf(treasury.address) - before).to.equal(E("6.99"));

      const [active, reason] = await Sub.accessStatus(alice.address);
      expect(active).to.equal(true);
      expect(reason).to.equal(2); // 2 = paid
    });

    it("extends from the current expiry, so buying early never burns days", async function () {
      await ctx.DAI.mint(alice.address, E("100"));
      await ctx.DAI.connect(alice).approve(await Sub.getAddress(), E("100"));
      await Sub.connect(alice).subscribeWithDai(0); // +1 month
      const e1 = await Sub.paidExpiry(alice.address);
      await Sub.connect(alice).subscribeWithDai(0); // +1 month, stacked
      expect(await Sub.paidExpiry(alice.address)).to.equal(e1 + MONTH);
    });
  });

  describe("subscribe (STEP) slippage guard", function () {
    it("reverts when the required STEP exceeds maxStep", async function () {
      await expect(Sub.connect(alice).subscribe(0, 0))
        .to.be.revertedWithCustomError(Sub, "SlippageExceeded");
    });
  });

  describe("grantSubscription (trusted comp)", function () {
    it("owner can grant free months", async function () {
      await Sub.grantSubscription(alice.address, 3);
      const [, reason] = await Sub.accessStatus(alice.address);
      expect(reason).to.equal(2);
    });

    it("rejects a non-owner / non-granter caller", async function () {
      await expect(Sub.connect(bob).grantSubscription(alice.address, 1))
        .to.be.revertedWithCustomError(Sub, "NotGranter");
    });

    it("an authorised low-privilege granter can grant", async function () {
      await Sub.setGranter(bob.address);
      await Sub.connect(bob).grantSubscription(alice.address, 1);
      expect(await Sub.paidExpiry(alice.address)).to.be.gt(0n);
    });

    it("rejects a zero-month grant", async function () {
      await expect(Sub.grantSubscription(alice.address, 0))
        .to.be.revertedWithCustomError(Sub, "ZeroMonths");
    });
  });

  describe("club-exit conversion", function () {
    it("monthsForGap greedily maximises months (130 DAI -> 30 months)", async function () {
      expect(await Sub.monthsForGap(E("130"))).to.equal(30);
      expect(await Sub.monthsForGap(E("7"))).to.equal(1);  // exactly one monthly
      expect(await Sub.monthsForGap(E("6"))).to.equal(0);  // below cheapest plan
    });

    it("only the club authority may grant from a club exit", async function () {
      await expect(Sub.connect(bob).grantFromClubExit(alice.address, E("130")))
        .to.be.revertedWithCustomError(Sub, "NotClubAuthority");

      await Sub.setClubAuthority(bob.address);
      await Sub.connect(bob).grantFromClubExit(alice.address, E("130"));
      const [, reason] = await Sub.accessStatus(alice.address);
      expect(reason).to.equal(2);
    });
  });

  describe("admin guards", function () {
    it("setPlan / transferOwnership are owner-gated", async function () {
      await expect(Sub.connect(bob).setPlan(0, 1, E("9.99")))
        .to.be.revertedWithCustomError(Sub, "NotOwner");
      await expect(Sub.connect(bob).transferOwnership(bob.address))
        .to.be.revertedWithCustomError(Sub, "NotOwner");
    });

    it("owner can re-price a plan", async function () {
      await Sub.setPlan(0, 2, E("9.99"));
      expect(await Sub.planTotalUsd(0)).to.equal(E(String(9.99 * 2)));
    });
  });
});
