const { expect } = require("chai");
const { ethers } = require("hardhat");
const { E } = require("./_helpers");

// StepNFTTreasury — public NFT sale on a fixed tiered price curve. Each buy
// pulls DAI, swaps it for STEP on the live StepDex, and splits the STEP 90/10
// between two treasury wallets. Wired here as a real system contract so the
// DEX accepts its `buyStep` calls.
describe("StepNFTTreasury", function () {
  let deployer, alice, bob, w90, w10, dev;
  let DAI, Registry, Coin, Dex, NFT, Club;
  const FIRST_BUY_ID = 301n; // SWAP_END_ID (300) + 1

  beforeEach(async function () {
    [deployer, alice, bob, w90, w10, dev] = await ethers.getSigners();

    DAI      = await (await ethers.getContractFactory("MockERC20")).deploy("Mock DAI", "DAI", 18);
    Registry = await (await ethers.getContractFactory("StepRegistry")).deploy(deployer.address);
    Coin     = await (await ethers.getContractFactory("StepCoin")).deploy(await Registry.getAddress());
    Dex      = await (await ethers.getContractFactory("StepDex")).deploy(
      await Registry.getAddress(), await DAI.getAddress());
    NFT      = await (await ethers.getContractFactory("StepNFTTreasury")).deploy(
      await Registry.getAddress(), await DAI.getAddress(), w90.address, w10.address);
    Club     = await (await ethers.getContractFactory("MockClub")).deploy();

    await Registry.setInitial(await Registry.KEY_STEP_COIN(),     await Coin.getAddress());
    await Registry.setInitial(await Registry.KEY_STEP_DEX(),      await Dex.getAddress());
    await Registry.setInitial(await Registry.KEY_NFT_TREASURY(),  await NFT.getAddress());
    await Registry.setInitial(await Registry.KEY_CLUB_TREASURY(), await Club.getAddress());
    await Registry.setInitial(await Registry.KEY_DEV_TREASURY(),  dev.address);

    await Coin.mintInitialSupply();            // mints the fixed supply to the DEX
    const seed = E(10000);
    await DAI.mint(deployer.address, seed);
    await DAI.approve(await Dex.getAddress(), seed);
    await Dex.donateLiquidity(seed);
  });

  describe("price curve (pure)", function () {
    it("matches the documented tier ladder", async function () {
      expect(await NFT.getPrice(1)).to.equal(E(100));
      expect(await NFT.getPrice(200)).to.equal(E(100));
      expect(await NFT.getPrice(201)).to.equal(E(200));
      expect(await NFT.getPrice(301)).to.equal(E(400));
      expect(await NFT.getPrice(1000)).to.equal(E(25600));
    });

    it("the public-buy pool opens at id 301 (= 400 DAI)", async function () {
      expect(await NFT.getCurrentPrice()).to.equal(E(400));
    });
  });

  describe("buy", function () {
    it("mints the next NFT to the buyer and splits STEP 90/10 to the wallets", async function () {
      await Registry.connect(alice).acceptTerms();
      await DAI.mint(alice.address, E(400));
      await DAI.connect(alice).approve(await NFT.getAddress(), E(400));

      await NFT.connect(alice).buy(0); // 0 = no max-price cap

      expect(await NFT.ownerOf(FIRST_BUY_ID)).to.equal(alice.address);
      expect(await NFT.balanceOf(alice.address)).to.equal(1n);

      const got90 = await Coin.balanceOf(w90.address);
      const got10 = await Coin.balanceOf(w10.address);
      expect(got90).to.be.gt(0n);
      expect(got10).to.be.gt(0n);
      expect(got90).to.be.gt(got10); // 90% strictly larger than 10%
    });

    it("reverts when the buyer has not accepted the Terms", async function () {
      await DAI.mint(bob.address, E(400));
      await DAI.connect(bob).approve(await NFT.getAddress(), E(400));
      await expect(NFT.connect(bob).buy(0))
        .to.be.revertedWithCustomError(NFT, "TermsNotAccepted");
    });

    it("reverts when the curve price exceeds the caller's maxPrice", async function () {
      await Registry.connect(alice).acceptTerms();
      await DAI.mint(alice.address, E(400));
      await DAI.connect(alice).approve(await NFT.getAddress(), E(400));
      await expect(NFT.connect(alice).buy(E(399)))
        .to.be.revertedWithCustomError(NFT, "PriceExceedsMax");
    });
  });

  describe("admin", function () {
    it("setBaseURI is owner-gated", async function () {
      await expect(NFT.connect(bob).setBaseURI("ipfs://x/"))
        .to.be.revertedWithCustomError(NFT, "OwnableUnauthorizedAccount");
      await NFT.setBaseURI("ipfs://x/"); // owner succeeds
    });
  });
});
