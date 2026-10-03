const { expect } = require("chai");
const { ethers } = require("hardhat");

// ─────────────────────────────────────────────────────────────────────────────
// StepDex bonding-curve math + StepCoin 2% levy.
//
// These are the "precise math" paths the protocol's value rests on. The suite
// asserts the EXACT on-chain behaviour (not the rounded whitepaper examples),
// including the subtlety that — with the levy whitelist empty (as on mainnet) —
// the DEX→club hop on a buy is itself taxed 2%.
// ─────────────────────────────────────────────────────────────────────────────

const PRECISION = 10n ** 18n;
const INITIAL_SUPPLY = 1_000_000n * PRECISION; // StepCoin.INITIAL_SUPPLY

async function deploy() {
  const [deployer, alice, bob] = await ethers.getSigners();

  const DAI = await (await ethers.getContractFactory("MockERC20")).deploy("Mock DAI", "DAI", 18);
  const Registry = await (await ethers.getContractFactory("StepRegistry")).deploy(deployer.address);
  const Coin = await (await ethers.getContractFactory("StepCoin")).deploy(await Registry.getAddress());
  const Dex = await (await ethers.getContractFactory("StepDex")).deploy(
    await Registry.getAddress(),
    await DAI.getAddress()
  );
  const Club = await (await ethers.getContractFactory("MockClub")).deploy();

  // Bootstrap registry wiring (controller = deployer).
  await Registry.setInitial(await Registry.KEY_STEP_COIN(), await Coin.getAddress());
  await Registry.setInitial(await Registry.KEY_STEP_DEX(), await Dex.getAddress());
  await Registry.setInitial(await Registry.KEY_CLUB_TREASURY(), await Club.getAddress());

  // Mint the one-shot genesis supply into the DEX.
  await Coin.mintInitialSupply();

  return { deployer, alice, bob, DAI, Registry, Coin, Dex, Club };
}

// Mirror StepCoin._update: 2% levy (min 1 wei) on non-mint/burn,
// non-whitelisted transfers.
function applyLevy(amount) {
  let fee = (amount * 2n) / 100n;
  if (fee === 0n) fee = 1n;
  return { fee, net: amount - fee };
}

describe("StepCoin — 2% transfer levy", () => {
  it("burns 2% on a plain EOA→EOA transfer (whitelist empty, as on mainnet)", async () => {
    const { deployer, alice, bob, Registry, Coin, Dex, DAI } = await deploy();

    // Whitelist must be empty by default (matches live mainnet state).
    expect(await Coin.whitelistCount()).to.equal(0n);

    // Move some STEP out of the DEX to alice so she has a balance to send.
    // (DEX holds the genesis supply; impersonate not needed — use a buy instead.)
    await fundViaBuy({ Registry, Coin, Dex, DAI, buyer: alice, dai: ethers.parseEther("1") });

    const aliceBal = await Coin.balanceOf(alice.address);
    const amount = aliceBal / 2n;
    const { fee, net } = applyLevy(amount);

    const supplyBefore = await Coin.totalSupply();
    await expect(Coin.connect(alice).transfer(bob.address, amount))
      .to.emit(Coin, "TokensBurned")
      .withArgs(alice.address, fee);

    expect(await Coin.balanceOf(bob.address)).to.equal(net);
    expect(await Coin.totalSupply()).to.equal(supplyBefore - fee); // levy is burned
  });

  it("does NOT levy mints (DEX buy mints full 96% to the buyer)", async () => {
    const { deployer, alice, Registry, Coin, Dex, DAI } = await deploy();

    // Seed the reserve first so price is off the floor, THEN read price.
    const seed = ethers.parseEther("10");
    await DAI.mint(deployer.address, seed);
    await DAI.approve(await Dex.getAddress(), seed);
    await Dex.donateLiquidity(seed);

    const dai = ethers.parseEther("1");
    const price = await Dex.getPrice();
    const stepRaw = (dai * PRECISION) / price;
    const expectedUser = (stepRaw * 96n) / 100n; // BUY_USER_PERCENT, minted (no levy)

    await fundViaBuy({ Registry, Coin, Dex, DAI, buyer: alice, dai });

    expect(await Coin.balanceOf(alice.address)).to.equal(expectedUser);
  });
});

describe("StepDex — bonding-curve math", () => {
  it("price = daiReserve * 1e18 / totalSupply after seeding", async () => {
    const { deployer, DAI, Coin, Dex } = await deploy();
    const seed = ethers.parseEther("10");
    await DAI.mint(deployer.address, seed);
    await DAI.approve(await Dex.getAddress(), seed);
    await Dex.donateLiquidity(seed);

    const expected = (seed * PRECISION) / (await Coin.totalSupply());
    expect(await Dex.getPrice()).to.equal(expected);
    // 10 DAI / 1,000,000 STEP = 1e13 = 0.00001 DAI (whitepaper genesis example).
    expect(await Dex.getPrice()).to.equal(10n ** 13n);
  });

  it("buy mints 96% to user + 2% to club (club hop itself loses 2% levy)", async () => {
    const { deployer, alice, DAI, Coin, Dex, Club, Registry } = await deploy();
    const seed = ethers.parseEther("10");
    await DAI.mint(deployer.address, seed);
    await DAI.approve(await Dex.getAddress(), seed);
    await Dex.donateLiquidity(seed);

    const dai = ethers.parseEther("1");
    const price = await Dex.getPrice();
    const stepRaw = (dai * PRECISION) / price;
    const toUser = (stepRaw * 96n) / 100n;
    const toClub = (stepRaw * 2n) / 100n;
    // 2% un-minted buffer = stepRaw - toUser - toClub stays out of supply.
    const supplyBefore = await Coin.totalSupply();

    await fundViaBuy({ Registry, Coin, Dex, DAI, buyer: alice, dai });

    // User receives the full 96% (minted, no levy).
    expect(await Coin.balanceOf(alice.address)).to.equal(toUser);
    // Club's 2% is minted to the DEX then transferred to club → taxed 2% on the hop.
    const { net: clubNet, fee: clubFee } = applyLevy(toClub);
    expect(await Coin.balanceOf(await Club.getAddress())).to.equal(clubNet);
    // Net new supply = user(minted) + club(minted) - club-hop levy burn.
    expect(await Coin.totalSupply()).to.equal(supplyBefore + toUser + toClub - clubFee);
    // Reserve took 100% of the DAI.
    expect(await Dex.daiReserve()).to.equal(seed + dai);
  });

  it("price is monotonically non-decreasing across buy then sell", async () => {
    const { deployer, alice, DAI, Coin, Dex, Registry } = await deploy();
    const seed = ethers.parseEther("10");
    await DAI.mint(deployer.address, seed);
    await DAI.approve(await Dex.getAddress(), seed);
    await Dex.donateLiquidity(seed);

    const p0 = await Dex.getPrice();
    await fundViaBuy({ Registry, Coin, Dex, DAI, buyer: alice, dai: ethers.parseEther("5") });
    const p1 = await Dex.getPrice();
    expect(p1).to.be.gte(p0);

    // Alice sells half her STEP back.
    const sellAmt = (await Coin.balanceOf(alice.address)) / 2n;
    await Coin.connect(alice).approve(await Dex.getAddress(), sellAmt);
    await Dex.connect(alice).sellStep(sellAmt, 0);
    const p2 = await Dex.getPrice();
    expect(p2).to.be.gte(p1); // never drops, even on a sell
  });

  it("sell returns ~96% of DAI value (2% levy + 2% sell fee)", async () => {
    const { deployer, alice, DAI, Coin, Dex, Registry } = await deploy();
    const seed = ethers.parseEther("1000");
    await DAI.mint(deployer.address, seed);
    await DAI.approve(await Dex.getAddress(), seed);
    await Dex.donateLiquidity(seed);

    await fundViaBuy({ Registry, Coin, Dex, DAI, buyer: alice, dai: ethers.parseEther("100") });

    const price = await Dex.getPrice();
    const sellAmt = await Coin.balanceOf(alice.address);
    // Expected: levy leaves 98% reaching the DEX, then 98% of that value in DAI.
    const received = applyLevy(sellAmt).net;
    const fullValue = (received * price) / PRECISION;
    const expectedDai = (fullValue * 98n) / 100n;

    const daiBefore = await DAI.balanceOf(alice.address);
    await Coin.connect(alice).approve(await Dex.getAddress(), sellAmt);
    await Dex.connect(alice).sellStep(sellAmt, 0);
    const got = (await DAI.balanceOf(alice.address)) - daiBefore;

    expect(got).to.equal(expectedDai);
    // Sanity: net payout is ≈96% of notional (0.98 * 0.98 = 0.9604).
    const notional = (sellAmt * price) / PRECISION;
    expect(got).to.be.closeTo((notional * 9604n) / 10000n, notional / 1000n);
  });
});

// ── helpers ──────────────────────────────────────────────────────────────────
// A user buy needs: seeded reserve, accepted terms, DAI balance+approval.
async function fundViaBuy({ Registry, Coin, Dex, DAI, buyer, dai }) {
  // Ensure the reserve is seeded so price > floor and a sane amount mints.
  if ((await Dex.daiReserve()) === 0n) {
    const [deployer] = await ethers.getSigners();
    const seed = ethers.parseEther("10");
    await DAI.mint(deployer.address, seed);
    await DAI.approve(await Dex.getAddress(), seed);
    await Dex.donateLiquidity(seed);
  }
  await Registry.connect(buyer).acceptTerms();
  await DAI.mint(buyer.address, dai);
  await DAI.connect(buyer).approve(await Dex.getAddress(), dai);
  await Dex.connect(buyer).buyStepPublic(dai, 0);
}
