const { expect } = require("chai");
const { ethers } = require("hardhat");

// StepClub — the subscriber reward pool. Membership is driven exclusively by
// StepNet (the `onlyStepNet` gate, resolved through the registry). These tests
// pin the constructor guards, the StepNet-only access control, and a basic
// add-member happy path by registering the test deployer as "StepNet".
describe("StepClub", function () {
  let deployer, stepNetEoa, alice, bob;
  let Registry, Coin, Club;

  beforeEach(async function () {
    [deployer, stepNetEoa, alice, bob] = await ethers.getSigners();

    Registry = await (await ethers.getContractFactory("StepRegistry")).deploy(deployer.address);
    Coin     = await (await ethers.getContractFactory("StepCoin")).deploy(await Registry.getAddress());

    // Register a known STEP coin and point KEY_STEP_NET at an EOA we control so
    // we can exercise both sides of the `onlyStepNet` gate.
    await Registry.setInitial(await Registry.KEY_STEP_COIN(), await Coin.getAddress());
    await Registry.setInitial(await Registry.KEY_STEP_NET(),  stepNetEoa.address);

    // subscription address only needs to be non-zero for the constructor; the
    // paths under test never call into it.
    Club = await (await ethers.getContractFactory("StepClub")).deploy(
      await Registry.getAddress(), await Coin.getAddress());
  });

  describe("constructor", function () {
    it("rejects a zero registry or zero subscription", async function () {
      const Factory = await ethers.getContractFactory("StepClub");
      await expect(Factory.deploy(ethers.ZeroAddress, await Coin.getAddress()))
        .to.be.revertedWithCustomError(Club, "ZeroAddress");
      await expect(Factory.deploy(await Registry.getAddress(), ethers.ZeroAddress))
        .to.be.revertedWithCustomError(Club, "ZeroAddress");
    });

    it("starts empty (no members, distribution timer un-anchored)", async function () {
      expect(await Club.memberCount()).to.equal(0n);
      expect(await Club.isMember(alice.address)).to.equal(false);
      expect(await Club.lastDistributionTime()).to.equal(0n);
    });
  });

  describe("StepNet-only membership", function () {
    it("the registered StepNet can add a member", async function () {
      await Club.connect(stepNetEoa).addMember(alice.address);
      expect(await Club.isMember(alice.address)).to.equal(true);
      expect(await Club.memberCount()).to.equal(1n);
    });

    it("rejects addMember / removeMember from a non-StepNet caller", async function () {
      await expect(Club.connect(bob).addMember(alice.address))
        .to.be.revertedWithCustomError(Club, "Unauthorized");
      await expect(Club.connect(bob).removeMember(alice.address))
        .to.be.revertedWithCustomError(Club, "Unauthorized");
    });
  });

  describe("user guards", function () {
    it("claimForUser only works for the caller's own address", async function () {
      await expect(Club.connect(bob).claimForUser(alice.address))
        .to.be.revertedWithCustomError(Club, "Unauthorized");
    });

    it("exit reverts for a non-member", async function () {
      await expect(Club.connect(bob).exit())
        .to.be.revertedWithCustomError(Club, "NotMember");
    });

    it("donateToPool rejects a zero amount", async function () {
      await expect(Club.connect(alice).donateToPool(0))
        .to.be.revertedWithCustomError(Club, "ZeroAmount");
    });
  });
});
