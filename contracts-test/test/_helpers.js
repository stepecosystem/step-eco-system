const { ethers } = require("hardhat");

// Shared StepNet deploy/wiring helpers (no `describe` block → no tests here).
const E = (n) => ethers.parseEther(String(n));
const PRECISION = 10n ** 18n;

async function deployLibs() {
  const Reserve = await (await ethers.getContractFactory("ReserveLib")).deploy();
  const reserveAddr = await Reserve.getAddress();
  const Wallet = await (
    await ethers.getContractFactory("WalletLib", {
      libraries: { "contracts/StepNetLib.sol:ReserveLib": reserveAddr },
    })
  ).deploy();
  const Pending = await (await ethers.getContractFactory("PendingLib")).deploy();
  const Import = await (await ethers.getContractFactory("ImportLib")).deploy();
  const ClubSync = await (await ethers.getContractFactory("ClubSyncLib")).deploy();
  return {
    "contracts/StepNetLib.sol:ReserveLib": reserveAddr,
    "contracts/StepNetLib.sol:WalletLib": await Wallet.getAddress(),
    "contracts/StepNetLib.sol:PendingLib": await Pending.getAddress(),
    "contracts/StepNetLib.sol:ImportLib": await Import.getAddress(),
    "contracts/StepNetLib.sol:ClubSyncLib": await ClubSync.getAddress(),
  };
}

async function deployFull() {
  const [deployer, alice, bob, dev, carol] = await ethers.getSigners();

  const DAI = await (await ethers.getContractFactory("MockERC20")).deploy("Mock DAI", "DAI", 18);
  const Registry = await (await ethers.getContractFactory("StepRegistry")).deploy(deployer.address);
  const Coin = await (await ethers.getContractFactory("StepCoin")).deploy(await Registry.getAddress());
  const Dex = await (await ethers.getContractFactory("StepDex")).deploy(
    await Registry.getAddress(),
    await DAI.getAddress()
  );
  const libs = await deployLibs();
  const Net = await (
    await ethers.getContractFactory("StepNet", { libraries: libs })
  ).deploy(await Registry.getAddress(), await DAI.getAddress());
  const Club = await (await ethers.getContractFactory("MockClub")).deploy();
  const NFT = await (await ethers.getContractFactory("MockNFT")).deploy();

  const R = Registry;
  await R.setInitial(await R.KEY_STEP_COIN(), await Coin.getAddress());
  await R.setInitial(await R.KEY_STEP_DEX(), await Dex.getAddress());
  await R.setInitial(await R.KEY_STEP_NET(), await Net.getAddress());
  await R.setInitial(await R.KEY_NFT_TREASURY(), await NFT.getAddress());
  await R.setInitial(await R.KEY_CLUB_TREASURY(), await Club.getAddress());
  await R.setInitial(await R.KEY_DEV_TREASURY(), dev.address);

  await Coin.mintInitialSupply();
  const seed = E(1000);
  await DAI.mint(deployer.address, seed);
  await DAI.approve(await Dex.getAddress(), seed);
  await Dex.donateLiquidity(seed);

  await Net.finalizeSetup();

  return { deployer, alice, bob, dev, carol, DAI, Registry, Coin, Dex, Net, Club, NFT };
}

// Give `user` terms + 25 DAI and activate Box-0 under `referrer`.
async function activate(ctx, user, referrer) {
  const { Registry, DAI, Net } = ctx;
  await Registry.connect(user).acceptTerms();
  await DAI.mint(user.address, E(25));
  await DAI.connect(user).approve(await Net.getAddress(), E(25));
  await Net.connect(user).activateBox(referrer.address);
}

module.exports = { E, PRECISION, deployLibs, deployFull, activate };
