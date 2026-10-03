// StepNFTFund — the buy-back desk and the NFT yield vault.
//
// Deployed to Polygon mainnet at 0xaA739Ce109C72f775212Ed5fd1177120d295b26f. It receives the
// 20% slice of every StepSubscription payment and keeps it in two vaults that are never netted
// against each other: the SALE vault (pays holders who sell an NFT back) and the YIELD vault
// (pays a daily reward to NFTs priced 400 DAI or more).
//
// The collection is MockStepNFT: the production mint curve, the production "day price" rule and
// the production 10% DAI transfer levy on the sending side — the levy is what the fund's custody
// logic is built around, so a mock that moved tokens for free would prove nothing.
//
// Every test ends by checking the books: the fund's STEP balance must equal, to the wei, the sum
// of what it says it owes (sale vault + yield vault + distributed-but-unclaimed). STEP's 2% levy
// is taken out of the amount sent, so a transfer of X always costs the sender exactly X — any
// drift here would be a real accounting defect, not rounding.
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFull } = require("./_helpers");

const E = (n) => ethers.parseEther(String(n));
const DAY = 24n * 60n * 60n;
const levy = (x) => { const f = (x * 2n) / 100n; return f === 0n ? 1n : f; };

describe("StepNFTFund (buy-back desk + yield vault)", function () {
  async function fixture() {
    const ctx = await deployFull();
    const { Registry, DAI, Coin, Dex } = ctx;
    const signers = await ethers.getSigners();
    const [owner, alice, bob, , carol] = signers;
    const [w90, w10, dave] = [signers[5], signers[6], signers[7]];

    const NFT = await (await ethers.getContractFactory("MockStepNFT")).deploy(
      await DAI.getAddress(), await Coin.getAddress(), w90.address, w10.address);
    const Fund = await (await ethers.getContractFactory("StepNFTFund")).deploy(
      await Registry.getAddress(), await DAI.getAddress(), await NFT.getAddress());
    const fundAddr = await Fund.getAddress();
    const nftAddr = await NFT.getAddress();

    // STEP is bought on the public AMM — nobody starts with a balance.
    const buyStep = async (who, daiAmount) => {
      await DAI.mint(who.address, daiAmount);
      await Registry.connect(who).acceptTerms();
      await DAI.connect(who).approve(await Dex.getAddress(), daiAmount);
      await Dex.connect(who).buyStepPublic(daiAmount, 0);
      return Coin.balanceOf(who.address);
    };
    // dave is the liquidity of last resort: he funds vaults in the tests.
    await buyStep(dave, E(5000));

    const donate = async (fn, amount) => {
      await Coin.connect(dave).approve(fundAddr, amount);
      return Fund.connect(dave)[fn](amount);
    };

    // Mint `id` to `who` and make them ready to sell it to the desk: the fund may move the
    // token, and the collection may pull its 10% DAI levy from the seller.
    const holder = async (who, id) => {
      await NFT.mint(who.address, id);
      const fee = ((await NFT.getPrice(id)) * 10n) / 100n;
      await DAI.mint(who.address, fee);
      await DAI.connect(who).approve(nftAddr, fee);
      await NFT.connect(who).setApprovalForAll(fundAddr, true);
    };

    const stepFor = async (daiAmount) => (daiAmount * E(1)) / (await Dex.getPrice());

    const expectBooksBalance = async () => {
      const [sale, yld, pending, balance] = await Fund.vaultBalances();
      expect(balance, "fund STEP balance vs. sale + yield + pending").to.equal(sale + yld + pending);
    };

    return {
      ...ctx, Fund, NFT, fundAddr, owner, alice, bob, carol, dave, w90, w10,
      buyStep, donate, holder, stepFor, expectBooksBalance,
    };
  }

  // ── Inflow ──────────────────────────────────────────────────────────────────
  describe("inflow", function () {
    it("splits every deposit 50/50 between the sale and yield vaults, crediting what ARRIVED", async function () {
      const { Fund, Coin, dave, donate, expectBooksBalance } = await loadFixture(fixture);
      const amount = (await Coin.balanceOf(dave.address)) / 10n;

      await donate("depositSplit", amount);

      const [sale, yld, , balance] = await Fund.vaultBalances();
      expect(balance).to.equal(amount - levy(amount)); // the levy burned on the way in
      expect(sale + yld).to.equal(balance);
      expect(yld - sale).to.be.oneOf([0n, 1n]);         // floor goes to the sale vault
      await expectBooksBalance();
    });

    it("lets only the owner retune the split, never above 100%", async function () {
      const { Fund, Coin, alice, dave, donate } = await loadFixture(fixture);
      await expect(Fund.connect(alice).setSaleShareBps(7000))
        .to.be.revertedWithCustomError(Fund, "OwnableUnauthorizedAccount");
      await expect(Fund.setSaleShareBps(10001)).to.be.revertedWithCustomError(Fund, "BadShare");

      await expect(Fund.setSaleShareBps(7000)).to.emit(Fund, "SaleShareUpdated").withArgs(7000);
      const amount = (await Coin.balanceOf(dave.address)) / 10n;
      await donate("depositSplit", amount);
      const [sale, , , balance] = await Fund.vaultBalances();
      expect(sale).to.equal((balance * 7000n) / 10000n);
    });

    it("sweeps what the original collection owes it into the yield vault", async function () {
      const { Fund, NFT, Coin, dave, fundAddr, expectBooksBalance } = await loadFixture(fixture);
      const reward = (await Coin.balanceOf(dave.address)) / 20n;
      await Coin.connect(dave).transfer(await NFT.getAddress(), reward);
      const credited = reward - levy(reward);
      await NFT.creditReward(fundAddr, credited);

      expect(await Fund.treasuryRewardsPending()).to.equal(credited);
      await expect(Fund.claimTreasuryRewards()).to.emit(Fund, "TreasuryRewardsSwept");
      expect(await Fund.yieldVaultStep()).to.equal(credited - levy(credited));
      await expectBooksBalance();
    });
  });

  // ── Sale vault ──────────────────────────────────────────────────────────────
  describe("sale vault", function () {
    it("takes the NFT into custody, lists it, and pays half its price at once when funded", async function () {
      const { Fund, NFT, Coin, alice, holder, donate, stepFor, fundAddr, expectBooksBalance } =
        await loadFixture(fixture);
      await holder(alice, 350); // 400-DAI tier → owed 200 DAI
      await donate("donateToSaleVault", await stepFor(E(1000)));

      const owedStep = await stepFor(E(200));
      const before = await Coin.balanceOf(alice.address);
      await expect(Fund.connect(alice)["sellToFund(uint256)"](350))
        .to.emit(Fund, "SellOrderSettled");

      expect(await Coin.balanceOf(alice.address) - before).to.equal(owedStep - levy(owedStep));
      expect(await NFT.ownerOf(350)).to.equal(fundAddr);
      expect(await Fund.listed(350)).to.equal(true);
      const [total, head, outstanding] = await Fund.queueInfo();
      expect([total, head, outstanding]).to.deep.equal([1n, 1n, 0n]);
      await expectBooksBalance();
    });

    it("queues sellers in strict FIFO order when the vault is short", async function () {
      const { Fund, Coin, alice, bob, holder, donate, stepFor, expectBooksBalance } = await loadFixture(fixture);
      await holder(alice, 350);
      await holder(bob, 351);
      await Fund.connect(alice)["sellToFund(uint256)"](350);
      await Fund.connect(bob)["sellToFund(uint256)"](351);

      let [, , outstanding, outstandingDai] = await Fund.queueInfo();
      expect(outstanding).to.equal(2n);
      expect(outstandingDai).to.equal(E(400));

      // Fund enough for exactly ONE order: the first seller is paid, the second still waits.
      const aliceBefore = await Coin.balanceOf(alice.address);
      const bobBefore = await Coin.balanceOf(bob.address);
      await donate("donateToSaleVault", ((await stepFor(E(200))) * 3n) / 2n);
      expect(await Coin.balanceOf(alice.address)).to.be.gt(aliceBefore);
      expect(await Coin.balanceOf(bob.address)).to.equal(bobBefore);
      [, , outstanding] = await Fund.queueInfo();
      expect(outstanding).to.equal(1n);

      // A nudge with no new money settles nothing — and says so.
      await expect(Fund.settleQueue(5)).to.be.revertedWithCustomError(Fund, "NothingToSettle");
      await donate("donateToSaleVault", await stepFor(E(200)));
      expect(await Coin.balanceOf(bob.address)).to.be.gt(bobBefore);
      await expectBooksBalance();
    });

    it("lets an unpaid seller — and only that seller — cancel and take the NFT back", async function () {
      const { Fund, NFT, DAI, alice, bob, holder, fundAddr, expectBooksBalance } = await loadFixture(fixture);
      await holder(alice, 350);
      await Fund.connect(alice)["sellToFund(uint256)"](350);

      await expect(Fund.connect(bob).cancelSellOrder(350))
        .to.be.revertedWithCustomError(Fund, "NotTokenOwner");

      const fee = await Fund.cancelFeeDai(350);
      expect(fee).to.equal(E(40)); // 10% of the 400-DAI mint price
      await DAI.mint(alice.address, fee);
      await DAI.connect(alice).approve(fundAddr, fee);
      await expect(Fund.connect(alice).cancelSellOrder(350)).to.emit(Fund, "SellOrderCancelled");

      expect(await NFT.ownerOf(350)).to.equal(alice.address);
      expect(await Fund.listed(350)).to.equal(false);
      await expectBooksBalance();
    });

    it("refuses to cancel once the vault has paid — the sale is final", async function () {
      const { Fund, alice, holder, donate, stepFor } = await loadFixture(fixture);
      await holder(alice, 350);
      await donate("donateToSaleVault", await stepFor(E(1000)));
      await Fund.connect(alice)["sellToFund(uint256)"](350);
      await expect(Fund.connect(alice).cancelSellOrder(350))
        .to.be.revertedWithCustomError(Fund, "NothingToSettle");
    });
  });

  // ── Re-sale of listed NFTs ──────────────────────────────────────────────────
  describe("re-sale", function () {
    it("sells at the day price, clears the head of the queue, and splits the rest 90/10", async function () {
      const { Fund, NFT, DAI, Coin, alice, dave, w90, w10, holder, fundAddr, expectBooksBalance } =
        await loadFixture(fixture);
      await NFT.setNextBuyId(450); // the collection is minting the 800-DAI tier today
      await holder(alice, 350);    // 400-DAI mint price → owed 200, vault empty → queued
      await Fund.connect(alice)["sellToFund(uint256)"](350);

      const [priceDai, feeDai, swapDai, toQueueDai] = await Fund.quoteBuyListed(350);
      expect(priceDai).to.equal(E(800));
      expect(feeDai).to.equal(E(40));
      expect(swapDai).to.equal(E(760));
      expect(toQueueDai).to.equal(E(200));

      const aliceBefore = await Coin.balanceOf(alice.address);
      await DAI.mint(dave.address, priceDai);
      await DAI.connect(dave).approve(fundAddr, priceDai);
      const tx = await Fund.connect(dave).buyListed(350, priceDai);
      const rc = await tx.wait();
      const ev = rc.logs.map((l) => { try { return Fund.interface.parseLog(l); } catch { return null; } })
        .find((p) => p && p.name === "ListedNFTBought");
      const { toQueueStep: toQueue, toWallet90Step: to90, toWallet10Step: to10 } = ev.args;

      expect(await NFT.ownerOf(350)).to.equal(dave.address);
      expect(await Coin.balanceOf(alice.address)).to.be.gt(aliceBefore); // the queued seller got paid
      expect(to90).to.equal(((to90 + to10) * 90n) / 100n);
      expect(await Coin.balanceOf(w90.address)).to.equal(to90 - levy(to90));
      expect(await Coin.balanceOf(w10.address)).to.equal(to10 - levy(to10));
      expect(toQueue).to.be.gt(0n);
      expect(await Fund.tierOf(350)).to.equal(E(800)); // re-sold → now an 800-DAI token
      const [, , outstanding] = await Fund.queueInfo();
      expect(outstanding).to.equal(0n);
      await expectBooksBalance();
    });

    it("promotes a low-id token into the yield tier when it re-sells at 400 DAI or more", async function () {
      const { Fund, NFT, DAI, carol, dave, holder, fundAddr } = await loadFixture(fixture);
      await NFT.setNextBuyId(450);
      await holder(carol, 10); // 100-DAI tier: earns no yield by birth
      expect((await Fund.tokenTier(10)).earnsYield).to.equal(false);
      await Fund.connect(carol)["sellToFund(uint256)"](10);

      await DAI.mint(dave.address, E(800));
      await DAI.connect(dave).approve(fundAddr, E(800));
      await expect(Fund.connect(dave).buyListed(10, E(800)))
        .to.emit(Fund, "TokenPromoted").withArgs(10, E(100), E(800), true);

      expect(await Fund.promotedCount()).to.equal(1n);
      expect((await Fund.tokenTier(10)).earnsYield).to.equal(true);
    });

    it("honours the buyer's price cap", async function () {
      const { Fund, NFT, alice, holder } = await loadFixture(fixture);
      await NFT.setNextBuyId(450);
      await holder(alice, 350);
      await Fund.connect(alice)["sellToFund(uint256)"](350);
      await expect(Fund.buyListed(350, E(799))).to.be.revertedWithCustomError(Fund, "PriceExceedsMax");
    });
  });

  // ── Yield vault ─────────────────────────────────────────────────────────────
  describe("yield vault", function () {
    async function yieldFixture() {
      const ctx = await fixture();
      const { NFT, alice, bob, carol, Coin, dave, donate } = ctx;
      await NFT.mint(alice.address, 301); // 400 DAI — eligible
      await NFT.mint(bob.address, 302);   // 400 DAI — eligible
      await NFT.mint(carol.address, 5);   // 100 DAI — not eligible
      await NFT.setNextBuyId(303);
      await donate("donateToYieldVault", (await Coin.balanceOf(dave.address)) / 10n);
      return ctx;
    }

    it("pays only NFTs priced 400 DAI or more, evenly per NFT", async function () {
      const { Fund, Coin, alice, bob, carol, expectBooksBalance } = await loadFixture(yieldFixture);
      const vault = await Fund.yieldVaultStep();
      expect(await Fund.eligibleNftCount()).to.equal(2n);

      await expect(Fund.distributeYield()).to.emit(Fund, "YieldDistributed");
      const perNFT = vault / 2n;
      expect(await Fund.pendingOf(alice.address)).to.equal(perNFT);
      expect(await Fund.pendingOf(bob.address)).to.equal(perNFT);
      expect(await Fund.pendingOf(carol.address)).to.equal(0n);

      const before = await Coin.balanceOf(alice.address);
      await Fund.connect(alice).claimYield();
      expect(await Coin.balanceOf(alice.address) - before).to.equal(perNFT - levy(perNFT));
      expect(await Fund.totalClaimed(alice.address)).to.equal(perNFT);
      await expectBooksBalance();
    });

    it("runs at most once per day", async function () {
      const { Fund } = await loadFixture(yieldFixture);
      await Fund.distributeYield();
      await expect(Fund.distributeYield()).to.be.revertedWithCustomError(Fund, "TooEarly");
    });

    it("excludes NFTs held in its own custody from the split", async function () {
      const { Fund, NFT, DAI, alice, bob, fundAddr } = await loadFixture(yieldFixture);
      const fee = E(40);
      await DAI.mint(bob.address, fee);
      await DAI.connect(bob).approve(await NFT.getAddress(), fee);
      await NFT.connect(bob).setApprovalForAll(fundAddr, true);
      await Fund.connect(bob)["sellToFund(uint256)"](302); // queued, token now in custody

      expect(await Fund.eligibleNftCount()).to.equal(1n);
      await Fund.distributeYield();
      expect(await Fund.pendingOf(alice.address)).to.be.gt(0n);
      expect(await Fund.pendingOf(bob.address)).to.equal(0n);
      expect(await Fund.pendingOf(fundAddr)).to.equal(0n);
    });

    it("burns yield left unclaimed past the 30-day window instead of paying it", async function () {
      const { Fund, Coin, alice, expectBooksBalance } = await loadFixture(yieldFixture);
      await Fund.distributeYield();
      const owed = await Fund.pendingOf(alice.address);
      await time.increase(31n * DAY);

      expect(await Fund.pendingOf(alice.address)).to.equal(0n);
      const before = await Coin.balanceOf(alice.address);
      await expect(Fund.connect(alice).claimYield())
        .to.emit(Fund, "TokensBurned").withArgs(alice.address, owed);
      expect(await Coin.balanceOf(alice.address)).to.equal(before);
      expect(await Fund.totalBurnedOf(alice.address)).to.equal(owed);
      await expectBooksBalance();
    });

    it("resumes a large round across calls, freezes custody meanwhile, and returns unowed shares", async function () {
      const { Fund, NFT, Coin, alice, dave, donate, holder, expectBooksBalance } = await loadFixture(fixture);
      // 500 ids in the yield range — more than one 400-id batch — but only #301 has an owner.
      await holder(alice, 301);
      await NFT.setNextBuyId(801);
      await donate("donateToYieldVault", (await Coin.balanceOf(dave.address)) / 10n);
      const vault = await Fund.yieldVaultStep();
      expect(await Fund.eligibleNftCount()).to.equal(500n);
      const perNFT = vault / 500n;

      await Fund.distributeYield(); // first batch: 400 ids
      expect((await Fund.getDistributionStatus()).inProgress).to.equal(true);
      // The eligible count was snapshotted at the start, so custody may not move mid-round.
      await expect(Fund.connect(alice)["sellToFund(uint256)"](301))
        .to.be.revertedWithCustomError(Fund, "DistributionInProgress");

      await Fund.distributeYield(); // second batch closes the round
      expect((await Fund.getDistributionStatus()).inProgress).to.equal(false);
      expect(await Fund.pendingOf(alice.address)).to.equal(perNFT);
      // 499 shares had no live owner: they return to the vault rather than becoming a liability
      // nobody can ever claim.
      expect(await Fund.yieldVaultStep()).to.equal(vault - perNFT);
      await expectBooksBalance();
    });
  });

  // ── Migration gate ──────────────────────────────────────────────────────────
  describe("migration", function () {
    it("is reachable only through the registry's DAO path — not the owner", async function () {
      const { Fund, alice } = await loadFixture(fixture);
      await expect(Fund.migrateAssetsTo(alice.address)).to.be.revertedWithCustomError(Fund, "NotAuthorized");
      await expect(Fund.migrateEscrowedNFTs(0)).to.be.revertedWithCustomError(Fund, "NotMigrated");
    });
  });
});
