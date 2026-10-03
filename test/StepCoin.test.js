const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("StepCoin", function () {
  let registry, step, owner, dex, alice;

  beforeEach(async function () {
    [owner, dex, alice] = await ethers.getSigners();

    const Registry = await ethers.getContractFactory("StepRegistry");
    registry = await Registry.deploy(owner.address);

    const StepCoin = await ethers.getContractFactory("StepCoin");
    step = await StepCoin.deploy(await registry.getAddress());

    // Point the registry's DEX key at the `dex` signer so we can exercise the
    // DEX-only mint/burn authority without deploying the full AMM.
    await registry.setInitial(await registry.KEY_STEP_DEX(), dex.address);
  });

  it("has the correct name and symbol", async function () {
    expect(await step.name()).to.equal("StepCoin");
    expect(await step.symbol()).to.equal("STEP");
  });

  it("caps the fee-exempt whitelist at 2", async function () {
    expect(await step.MAX_WHITELIST()).to.equal(2n);
  });

  it("lets ONLY the registry-current DEX mint", async function () {
    const amount = ethers.parseEther("100");
    // A random account cannot mint.
    await expect(step.connect(alice).mint(alice.address, amount))
      .to.be.revertedWithCustomError(step, "NotDex");
    // The DEX can.
    await step.connect(dex).mint(alice.address, amount);
    expect(await step.balanceOf(alice.address)).to.equal(amount);
  });

  it("restricts mintInitialSupply to the original deployer, once", async function () {
    await expect(step.connect(alice).mintInitialSupply())
      .to.be.revertedWithCustomError(step, "Unauthorized");

    await step.connect(owner).mintInitialSupply();
    expect(await step.initialSupplyMinted()).to.equal(true);

    await expect(step.connect(owner).mintInitialSupply())
      .to.be.revertedWithCustomError(step, "AlreadyMinted");
  });

  it("only allows the registry to manage the whitelist", async function () {
    await expect(step.connect(alice).addToWhitelist(alice.address))
      .to.be.revertedWithCustomError(step, "Unauthorized");
  });
});
