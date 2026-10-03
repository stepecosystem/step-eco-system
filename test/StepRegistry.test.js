const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("StepRegistry", function () {
  let registry, controller, alice;

  beforeEach(async function () {
    [controller, alice] = await ethers.getSigners();
    const Registry = await ethers.getContractFactory("StepRegistry");
    registry = await Registry.deploy(controller.address);
  });

  it("derives address-book keys from stable string hashes", async function () {
    expect(await registry.KEY_STEP_COIN()).to.equal(
      ethers.keccak256(ethers.toUtf8Bytes("STEP_COIN"))
    );
    expect(await registry.KEY_STEP_DEX()).to.equal(
      ethers.keccak256(ethers.toUtf8Bytes("STEP_DEX"))
    );
  });

  it("stores and resolves an initial address", async function () {
    const key = await registry.KEY_STEP_DEX();
    await registry.setInitial(key, alice.address);
    expect(await registry.get(key)).to.equal(alice.address);
  });

  it("lets only the controller seed initial addresses", async function () {
    const key = await registry.KEY_STEP_DEX();
    await expect(registry.connect(alice).setInitial(key, alice.address))
      .to.be.reverted;
  });

  it("refuses to overwrite an already-set key", async function () {
    const key = await registry.KEY_STEP_DEX();
    await registry.setInitial(key, alice.address);
    await expect(registry.setInitial(key, controller.address))
      .to.be.revertedWithCustomError(registry, "AlreadySet");
  });

  it("records terms-of-service acceptance per address", async function () {
    expect(await registry.hasAcceptedCurrentTerms(alice.address)).to.equal(false);
    await registry.connect(alice).acceptTerms();
    expect(await registry.hasAcceptedCurrentTerms(alice.address)).to.equal(true);
  });
});
