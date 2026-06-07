const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("QuickSwap", function () {
  let qs, owner, other, router, feeRecipient;

  beforeEach(async function () {
    [owner, other, router, feeRecipient] = await ethers.getSigners();
    const QuickSwap = await ethers.getContractFactory("QuickSwap");
    qs = await QuickSwap.deploy(router.address, feeRecipient.address, 50);
  });

  it("enforces a hard 3% fee ceiling", async function () {
    expect(await qs.MAX_FEE_BPS()).to.equal(300n);
  });

  it("rejects a constructor fee above the ceiling", async function () {
    const QuickSwap = await ethers.getContractFactory("QuickSwap");
    await expect(QuickSwap.deploy(router.address, feeRecipient.address, 301))
      .to.be.revertedWithCustomError(qs, "FeeTooHigh");
  });

  it("lets the owner set a fee within the band but never above it", async function () {
    await qs.setFeeBps(300);
    expect(await qs.feeBps()).to.equal(300n);

    await expect(qs.setFeeBps(301))
      .to.be.revertedWithCustomError(qs, "FeeTooHigh");
  });

  it("gates owner-only setters", async function () {
    await expect(qs.connect(other).setFeeRecipient(other.address))
      .to.be.revertedWithCustomError(qs, "NotOwner");
    await expect(qs.connect(other).setFeeBps(10))
      .to.be.revertedWithCustomError(qs, "NotOwner");
  });

  it("transfers ownership", async function () {
    await qs.transferOwnership(other.address);
    expect(await qs.owner()).to.equal(other.address);
    // Old owner can no longer administer.
    await expect(qs.setFeeBps(10))
      .to.be.revertedWithCustomError(qs, "NotOwner");
  });
});
