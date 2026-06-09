const { expect } = require("chai");
const { ethers } = require("hardhat");
const { E, deployFull, activate } = require("./_helpers");

// ─────────────────────────────────────────────────────────────────────────────
// StepNet — processDaily reward-POINT correctness (not just "a cycle completes").
//
// Setup: founder (the constructor-seeded root) gets two direct children, alice
// (left) and bob (right). After both Box-0 activations the founder holds
// teamLeftCount[0] = teamRightCount[0] = 1, so its weaker-side = 1 point. No
// other subscriber has any team yet, so dailyTotalPoints[0] = 1 and the founder
// is the sole earner.
//
// Pool[0] after two activations = 2 × 20.5 = 41 DAI.
//   pointPrice = accumulatedDai × 1e18 / totalPoints = 41e18 × 1e18 / 1
//   dai_       = pts(1) × pointPrice / 1e18           = 41 DAI
//   reserve    = 10% of dai_                          = 4.1 DAI  (→ upgrade reserve, founder is Box-0 only)
//   claimable  = dai_ − reserve                       = 36.9 DAI
// ─────────────────────────────────────────────────────────────────────────────

describe("StepNet — processDaily reward math", () => {
  it("pays the founder exactly 1 capped point of the pool (90% claimable, 10% reserved)", async () => {
    const ctx = await deployFull();
    const { Net, deployer, alice, bob } = ctx;

    await activate(ctx, alice, deployer); // founder.left
    await activate(ctx, bob, deployer);   // founder.right

    // Pre-distribution: the whole 82% of both fees sits in the Box-0 pool.
    expect((await Net.pools(0)).accumulatedDai).to.equal(E(41));

    await Net.processDaily();

    // 1 point × (41 DAI / 1 point) = 41 DAI; 90% claimable, 10% to reserve.
    expect(await Net.pendingBoxDaiRewards(deployer.address, 0)).to.equal(E(36.9));
    expect((await Net.users(deployer.address)).reservedForUpgrade).to.equal(E(4.1));

    // Pool fully distributed and recorded.
    expect((await Net.pools(0)).accumulatedDai).to.equal(0n);
    expect(await Net.lastRoundRewardPerBox(0)).to.equal(E(41));
  });

  it("a subscriber with no team earns nothing", async () => {
    const ctx = await deployFull();
    const { Net, deployer, alice, bob } = ctx;

    await activate(ctx, alice, deployer);
    await activate(ctx, bob, deployer);
    await Net.processDaily();

    // alice/bob are leaves — zero weaker-side, zero reward.
    expect(await Net.pendingBoxDaiRewards(alice.address, 0)).to.equal(0n);
    expect(await Net.pendingBoxDaiRewards(bob.address, 0)).to.equal(0n);
  });

  it("the founder can withdraw the accrued reward as STEP, zeroing the pending balance", async () => {
    const ctx = await deployFull();
    const { Net, Coin, deployer, alice, bob } = ctx;

    await activate(ctx, alice, deployer);
    await activate(ctx, bob, deployer);
    await Net.processDaily();

    const pending = await Net.pendingBoxDaiRewards(deployer.address, 0);
    expect(pending).to.equal(E(36.9));

    const stepBefore = await Coin.balanceOf(deployer.address);
    await expect(Net.withdrawAllBoxReward(0)).to.emit(Net, "BoxRewardsWithdrawn");

    // Pending reward is converted to STEP and the accounting entry is cleared.
    expect(await Coin.balanceOf(deployer.address)).to.be.gt(stepBefore);
    expect(await Net.pendingBoxDaiRewards(deployer.address, 0)).to.equal(0n);

    // Double-withdraw must revert — nothing left to claim.
    await expect(Net.withdrawAllBoxReward(0)).to.be.revertedWithCustomError(Net, "NoReward");
  });
});
