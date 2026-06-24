// scripts/deploy.js
// ═══════════════════════════════════════════════════════════════════════════════
// 🚀 Step Ecosystem — FULL UNIFIED DEPLOY  (v4 — LeaderboardLib لینک شد)
//
//    تغییرات نسبت به v3:
//      • LeaderboardLib (از StepNetView.sol) اضافه شد
//      • StepNetView با لینک به LeaderboardLib deploy می‌شود
//      • همه exportها (verify, .env, addresses.ts, deployed-addresses.json) آپدیت شدند
//
//    اجرا: npx hardhat run scripts/deploy.js --network polygon
// ═══════════════════════════════════════════════════════════════════════════════

const hre  = require("hardhat");
const fs   = require("fs");
const path = require("path");

// ─── تنظیمات ─────────────────────────────────────────────────────────────────
const CONFIG = {
  USE_DEPLOYER_AS_WALLETS : false,  // mainnet: use the explicit NFT split wallets in POLYGON below
  USE_DEPLOYER_AS_DEV     : false,  // mainnet: use the explicit DEV_TREASURY in POLYGON below
  DEPLOY_IMPORTER         : true,
  INITIAL_DAI_MAIN        : "10",
  DELAY_DEPLOY            : 3000,
  DELAY_CONFIG            : 2000,
  DELAY_VERIFY            : 30000,
};

// ─── Polygon PoS mainnet — fixed addresses (VERIFY each one before deploying) ──
// IMPORTANT: real DAI is an EXISTING on-chain token — it is referenced, never deployed.
const POLYGON = {
  DAI         : "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063", // (PoS) Dai Stablecoin — 18 decimals
  OWNER       : "0x57bA445848bEc74bF9C5665FB098521745363983", // StepRegistry controller (MUST == deployer)
  WALLET_90   : "0xe024e038eBE9473fa5E7ac43062FFbd2B2910706", // StepNFTTreasury wallet90 (90% split)
  WALLET_10   : "0xB633cE7B7950B522F029c0b6a2eEBc38d5DF4f6d", // StepNFTTreasury wallet10 (10% split)
  DEV_TREASURY: "0xD8D4D71993d831c147445271e407fAada2227895", // registry KEY_DEV_TREASURY
};

// Minimal ERC20 ABI for the real DAI token (only what PHASE 5 liquidity needs).
// `mint` is intentionally OMITTED — real DAI cannot be minted, so the PHASE 5 mint
// attempt cleanly no-ops (no on-chain tx, no wasted gas) and falls through to
// approve + donateLiquidity from the deployer's real DAI balance.
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

// ─── helpers ─────────────────────────────────────────────────────────────────
const delay = ms => new Promise(r => setTimeout(r, ms));
const log  = console.log;
const ok   = msg  => log(`   ✅ ${msg}`);
const warn = msg  => log(`   ⚠️  ${msg}`);
const info = msg  => log(`   ℹ️  ${msg}`);
const step = (n, title) => {
  log(`\n   ┌─────────────────────────────────────────────────────────┐`);
  log(`   │  ${`PHASE ${n}: ${title}`.padEnd(55)}│`);
  log(`   └─────────────────────────────────────────────────────────┘\n`);
};

// ─── deploy helper (بدون library link) ───────────────────────────────────────
async function deploy(name, constructorArgs = []) {
  log(`   🔨 Deploying ${name}...`);
  const Factory  = await hre.ethers.getContractFactory(name);
  const contract = await Factory.deploy(...constructorArgs);
  await contract.waitForDeployment();
  const address  = await contract.getAddress();
  ok(`${name}: ${address}`);
  await delay(CONFIG.DELAY_DEPLOY);
  return { contract, address };
}

// ─── deploy helper با library link ────────────────────────────────────────────
async function deployWithLibs(name, constructorArgs = [], libraries = {}) {
  log(`   🔨 Deploying ${name} (with library links)...`);
  const Factory  = await hre.ethers.getContractFactory(name, { libraries });
  const contract = await Factory.deploy(...constructorArgs);
  await contract.waitForDeployment();
  const address  = await contract.getAddress();
  ok(`${name}: ${address}`);
  for (const [libName, libAddr] of Object.entries(libraries)) {
    info(`     ↳ linked ${libName} @ ${libAddr}`);
  }
  await delay(CONFIG.DELAY_DEPLOY);
  return { contract, address };
}

// ─── main ─────────────────────────────────────────────────────────────────────
async function main() {
  const startTime = Date.now();
  const [deployer] = await hre.ethers.getSigners();
  const DEPLOYER   = deployer.address;

  // ── SAFETY GUARD ──────────────────────────────────────────────────────────
  // Every onlyController/onlyOwner config call below (setInitialBatch, setStepNet,
  // setStepNetView, mintInitialSupply, setImporter, setClubAuthority) is signed by
  // the deployer. If the loaded PRIVATE_KEY is not the intended OWNER, the contracts
  // would deploy but stay UNCONFIGURED on mainnet. Abort before spending any gas.
  if (DEPLOYER.toLowerCase() !== POLYGON.OWNER.toLowerCase()) {
    throw new Error(
      `Deployer ${DEPLOYER} != expected OWNER ${POLYGON.OWNER}. ` +
      `Load the OWNER's PRIVATE_KEY before deploying to Polygon mainnet.`
    );
  }

  const WALLET_90  = CONFIG.USE_DEPLOYER_AS_WALLETS ? DEPLOYER : POLYGON.WALLET_90;
  const WALLET_10  = CONFIG.USE_DEPLOYER_AS_WALLETS ? DEPLOYER : POLYGON.WALLET_10;
  const DEV_WALLET = CONFIG.USE_DEPLOYER_AS_DEV     ? DEPLOYER : POLYGON.DEV_TREASURY;
  const MSG_ADMIN  = DEPLOYER;

  const SUBSCRIPTION_TREASURY = process.env.SUBSCRIPTION_TREASURY || DEPLOYER;

  log("\n   ╔══════════════════════════════════════════════════════════╗");
  log("   ║   🚀 STEP ECOSYSTEM — FULL UNIFIED DEPLOY (v4)          ║");
  log("   ║   ✅ LeaderboardLib لینک شد                              ║");
  log("   ╚══════════════════════════════════════════════════════════╝\n");
  log(`   📅 ${new Date().toLocaleString()}`);
  log(`   🔗 Network  : ${hre.network.name}`);
  log(`   👤 Deployer : ${DEPLOYER}`);
  log(`   💰 Balance  : ${hre.ethers.formatEther(
    await hre.ethers.provider.getBalance(DEPLOYER)
  )} POL\n`);

  const addr  = {};
  const ctrs  = {};
  const cArgs = {};

  // ══════════════════════════════════════════════════════════════════════════
  // PHASE 1 — دپلوی قراردادهای اصلی
  // ══════════════════════════════════════════════════════════════════════════
  step(1, "DEPLOY MAIN CONTRACTS");

  // 1-1 DAI — REAL Polygon mainnet DAI (existing token; referenced, NOT deployed).
  //          The internal `addr.MockDAI` key is intentionally kept so every
  //          downstream constructor wiring stays byte-for-byte identical; it now
  //          holds the real DAI address. `ctrs.dai` is attached only for the
  //          PHASE 5 liquidity step (approve + donateLiquidity).
  addr.MockDAI = POLYGON.DAI;
  ctrs.dai     = await hre.ethers.getContractAt(ERC20_ABI, POLYGON.DAI);
  ok(`DAI (real, Polygon mainnet): ${addr.MockDAI}`);

  // 1-2 StepRegistry (controller = OWNER; the guard above guarantees OWNER == deployer)
  ({ contract: ctrs.registry, address: addr.StepRegistry } = await deploy("StepRegistry", [POLYGON.OWNER]));
  cArgs.StepRegistry = [POLYGON.OWNER];

  // 1-3 StepCoin
  ({ contract: ctrs.coin, address: addr.StepCoin } = await deploy("StepCoin", [addr.StepRegistry]));
  cArgs.StepCoin = [addr.StepRegistry];

  // 1-4 StepDex
  ({ contract: ctrs.dex, address: addr.StepDex } = await deploy("StepDex", [addr.StepRegistry, addr.MockDAI]));
  cArgs.StepDex = [addr.StepRegistry, addr.MockDAI];

  // 1-5 ReserveLib
  ({ contract: ctrs.reserveLib, address: addr.ReserveLib } = await deploy("ReserveLib", []));
  cArgs.ReserveLib = [];

  // 1-6 PendingLib
  ({ contract: ctrs.pendingLib, address: addr.PendingLib } = await deploy("PendingLib", []));
  cArgs.PendingLib = [];

  // 1-6b ImportLib
  ({ contract: ctrs.importLib, address: addr.ImportLib } = await deploy("ImportLib", []));
  cArgs.ImportLib = [];

  // 1-6c ClubSyncLib
  ({ contract: ctrs.clubSyncLib, address: addr.ClubSyncLib } = await deploy("ClubSyncLib", []));
  cArgs.ClubSyncLib = [];

  // 1-6d LeaderboardLib (جدید — برای StepNetView)
  ({ contract: ctrs.leaderboardLib, address: addr.LeaderboardLib } = await deploy("LeaderboardLib", []));
  cArgs.LeaderboardLib = [];

  // 1-7 WalletLib
  ({ contract: ctrs.walletLib, address: addr.WalletLib } = await deployWithLibs(
    "WalletLib",
    [],
    { ReserveLib: addr.ReserveLib }
  ));
  cArgs.WalletLib = [];

  // 1-8 StepNet
  ({ contract: ctrs.net, address: addr.StepNet } = await deployWithLibs(
    "StepNet",
    [addr.StepRegistry, addr.MockDAI],
    {
      ReserveLib  : addr.ReserveLib,
      WalletLib   : addr.WalletLib,
      PendingLib  : addr.PendingLib,
      ImportLib   : addr.ImportLib,
      ClubSyncLib : addr.ClubSyncLib,
    }
  ));
  cArgs.StepNet = [addr.StepRegistry, addr.MockDAI];

  // 1-9 StepNetView (لینک شده به LeaderboardLib)
  ({ contract: ctrs.netView, address: addr.StepNetView } = await deployWithLibs(
    "StepNetView",
    [addr.StepNet, addr.MockDAI, MSG_ADMIN],
    { LeaderboardLib: addr.LeaderboardLib }
  ));
  cArgs.StepNetView = [addr.StepNet, addr.MockDAI, MSG_ADMIN];

  // 1-10 StepNFTTreasury
  ({ contract: ctrs.nft, address: addr.StepNFTTreasury } = await deploy(
    "StepNFTTreasury",
    [addr.StepRegistry, addr.MockDAI, WALLET_90, WALLET_10]
  ));
  cArgs.StepNFTTreasury = [addr.StepRegistry, addr.MockDAI, WALLET_90, WALLET_10];

  // 1-11 StepSubscription (deployed BEFORE StepClub — the club is immutably
  //       wired to it in its constructor for the exitToSubscription() path)
  ({ contract: ctrs.subscription, address: addr.StepSubscription } = await deploy(
    "StepSubscription",
    [addr.StepCoin, addr.MockDAI, addr.StepDex, addr.StepNet, SUBSCRIPTION_TREASURY]
  ));
  cArgs.StepSubscription = [addr.StepCoin, addr.MockDAI, addr.StepDex, addr.StepNet, SUBSCRIPTION_TREASURY];
  log(`   💳 Subscription payout → ${SUBSCRIPTION_TREASURY}`);

  // 1-12 StepClub (immutable SUBSCRIPTION arg → trustless exitToSubscription)
  ({ contract: ctrs.club, address: addr.StepClub } = await deploy("StepClub", [addr.StepRegistry, addr.StepSubscription]));
  cArgs.StepClub = [addr.StepRegistry, addr.StepSubscription];

  // One-time wiring: authorise the club as the ONLY caller of grantFromClubExit.
  try {
    await (await ctrs.subscription.setClubAuthority(addr.StepClub)).wait();
    ok("StepSubscription.clubAuthority → StepClub");
  } catch (e) {
    warn(`setClubAuthority → ${e.reason || e.message?.slice(0, 80)}`);
  }

  // 1-13 StepNetImporter
  ({ contract: ctrs.importer, address: addr.StepNetImporter } = await deploy(
    "StepNetImporter",
    [addr.StepNet]
  ));
  cArgs.StepNetImporter = [addr.StepNet];

  // ══════════════════════════════════════════════════════════════════════════
  // PHASE 2 — ثبت در Registry
  // ══════════════════════════════════════════════════════════════════════════
  step(2, "REGISTER IN REGISTRY");

  try {
    const keys = [
      await ctrs.registry.KEY_STEP_COIN(),
      await ctrs.registry.KEY_STEP_DEX(),
      await ctrs.registry.KEY_STEP_NET(),
      await ctrs.registry.KEY_NFT_TREASURY(),
      await ctrs.registry.KEY_CLUB_TREASURY(),
      await ctrs.registry.KEY_DEV_TREASURY(),
    ];
    const values = [
      addr.StepCoin,
      addr.StepDex,
      addr.StepNet,
      addr.StepNFTTreasury,
      addr.StepClub,
      DEV_WALLET,
    ];
    await (await ctrs.registry.setInitialBatch(keys, values)).wait();
    ok("Registry batch registered");
  } catch (e) {
    warn(`setInitialBatch → ${e.reason || e.message?.slice(0, 80)}`);
  }
  await delay(CONFIG.DELAY_CONFIG);

  try {
    await (await ctrs.registry.setStepNet(addr.StepNet)).wait();
    ok("setStepNet done");
  } catch (e) {
    warn(`setStepNet → ${e.reason || e.message?.slice(0, 80)}`);
  }
  await delay(CONFIG.DELAY_CONFIG);

  try {
    await (await ctrs.registry.setStepNetView(addr.StepNetView)).wait();
    ok("setStepNetView done");
  } catch (e) {
    warn(`setStepNetView → ${e.reason || e.message?.slice(0, 80)}`);
  }
  await delay(CONFIG.DELAY_CONFIG);

  // ══════════════════════════════════════════════════════════════════════════
  // PHASE 3 — mintInitialSupply
  // ══════════════════════════════════════════════════════════════════════════
  step(3, "MINT INITIAL SUPPLY → STEPDEX");

  try {
    await (await ctrs.coin.mintInitialSupply()).wait();
    ok("1,000,000 STEP minted → StepDex");
  } catch (e) {
    warn(`mintInitialSupply → ${e.reason || e.message?.slice(0, 80)}`);
  }
  await delay(CONFIG.DELAY_CONFIG);

  // ══════════════════════════════════════════════════════════════════════════
  // PHASE 4 — setImporter
  // ══════════════════════════════════════════════════════════════════════════
  step(4, "SET IMPORTER ON STEPNET");

  try {
    await (await ctrs.net.setImporter(addr.StepNetImporter)).wait();
    ok(`setImporter done — StepNet.importer = ${addr.StepNetImporter}`);
  } catch (e) {
    warn(`setImporter → ${e.reason || e.message?.slice(0, 80)}`);
  }
  await delay(CONFIG.DELAY_CONFIG);

  // ══════════════════════════════════════════════════════════════════════════
  // PHASE 5 — لیکوییدیتی اولیه
  // ══════════════════════════════════════════════════════════════════════════
  step(5, "INITIAL LIQUIDITY → STEPDEX");

  try {
    const liqMain = hre.ethers.parseUnits(CONFIG.INITIAL_DAI_MAIN, 18);
    try {
      await (await ctrs.dai.mint(DEPLOYER, liqMain)).wait();
      info(`${CONFIG.INITIAL_DAI_MAIN} DAI minted for liquidity`);
    } catch (_) { info("MockDAI mint skipped"); }

    await (await ctrs.dai.approve(addr.StepDex, liqMain)).wait();
    ok(`Approved ${CONFIG.INITIAL_DAI_MAIN} DAI → StepDex`);

    await (await ctrs.dex.donateLiquidity(liqMain)).wait();
    const price = await ctrs.dex.getPrice();
    ok(`donateLiquidity done — price: ${hre.ethers.formatEther(price)} DAI/STEP`);
  } catch (e) {
    warn(`Liquidity → ${e.reason || e.message?.slice(0, 80)}`);
  }
  await delay(CONFIG.DELAY_CONFIG);

  // ══════════════════════════════════════════════════════════════════════════
  // PHASE 6 — Verify
  // ══════════════════════════════════════════════════════════════════════════
  if (!["hardhat", "localhost"].includes(hre.network.name)) {
    step(6, "VERIFY ON EXPLORER");

    info(`Waiting ${CONFIG.DELAY_VERIFY / 1000}s for block confirmations...`);
    await delay(CONFIG.DELAY_VERIFY);

    const verifyList = [
      // MockDAI removed — real DAI is an existing, already-verified token on Polygon.
      { n: "StepRegistry",    a: addr.StepRegistry,    args: cArgs.StepRegistry },
      { n: "StepCoin",        a: addr.StepCoin,        args: cArgs.StepCoin },
      { n: "StepDex",         a: addr.StepDex,         args: cArgs.StepDex },
      { n: "ReserveLib",      a: addr.ReserveLib,      args: cArgs.ReserveLib },
      { n: "PendingLib",      a: addr.PendingLib,      args: cArgs.PendingLib },
      { n: "ImportLib",       a: addr.ImportLib,       args: cArgs.ImportLib },
      { n: "ClubSyncLib",     a: addr.ClubSyncLib,     args: cArgs.ClubSyncLib },
      { n: "LeaderboardLib",  a: addr.LeaderboardLib,  args: cArgs.LeaderboardLib }, // ← جدید
      { n: "WalletLib",       a: addr.WalletLib,       args: cArgs.WalletLib,
        libs: { ReserveLib: addr.ReserveLib } },
      { n: "StepNet",         a: addr.StepNet,         args: cArgs.StepNet,
        libs: { ReserveLib: addr.ReserveLib, WalletLib: addr.WalletLib, PendingLib: addr.PendingLib, ImportLib: addr.ImportLib, ClubSyncLib: addr.ClubSyncLib } },
      { n: "StepNetView",     a: addr.StepNetView,     args: cArgs.StepNetView,
        libs: { LeaderboardLib: addr.LeaderboardLib } }, // ← لینک جدید
      { n: "StepNFTTreasury", a: addr.StepNFTTreasury, args: cArgs.StepNFTTreasury },
      { n: "StepClub",        a: addr.StepClub,        args: cArgs.StepClub },
      { n: "StepNetImporter", a: addr.StepNetImporter, args: cArgs.StepNetImporter },
      { n: "StepSubscription",a: addr.StepSubscription,args: cArgs.StepSubscription },
    ];

    for (const c of verifyList) {
      log(`   🔍 Verifying ${c.n}...`);

      // ① مطمئن شو بایت‌کد روی چین هست (جلوگیری از getCode=0x / هنوز mine یا index نشده)
      let hasCode = false;
      for (let i = 0; i < 10; i++) {
        try {
          const code = await hre.ethers.provider.getCode(c.a);
          if (code && code !== "0x") { hasCode = true; break; }
        } catch (_) {}
        await delay(3000);
      }
      if (!hasCode) { warn(`${c.n}: روی چین بایت‌کدی پیدا نشد (${c.a}) — verify رد شد`); continue; }

      const verifyArgs = { address: c.a, constructorArguments: c.args };
      if (c.libs) verifyArgs.libraries = c.libs;

      // ② تا ۵ بار تلاش؛ خطاهای موقتیِ index/صفِ explorer را retry کن
      let done = false;
      for (let attempt = 1; attempt <= 5 && !done; attempt++) {
        try {
          await hre.run("verify:verify", verifyArgs);
          ok(`${c.n} verified`);
          done = true;
        } catch (e) {
          const m = (e.message || "").toLowerCase();
          if (m.includes("already verified") || m.includes("already been verified")) {
            info(`${c.n} already verified`);
            done = true;
          } else if (
            m.includes("does not have bytecode") ||
            m.includes("unable to locate") ||
            m.includes("not been indexed") ||
            m.includes("pending in queue") ||
            m.includes("try again") ||
            m.includes("rate limit") ||
            m.includes("timeout")
          ) {
            warn(`${c.n}: تلاش ${attempt} (موقتی) → ${e.message?.slice(0, 60)} … retry`);
            await delay(10000);
          } else {
            warn(`${c.n}: ${e.message?.slice(0, 160)}`);
            done = true; // خطای غیرموقتی — ادامه نده
          }
        }
      }
      await delay(5000);
    }
  } else {
    info("Local/hardhat network — verify skipped.");
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PHASE 7 — Export
  // ══════════════════════════════════════════════════════════════════════════
  step(7, "EXPORT ABIs & ADDRESSES");

  const abiDir = "./abis";
  if (!fs.existsSync(abiDir)) fs.mkdirSync(abiDir, { recursive: true });

  const abiContracts = [
    { name: "StepRegistry",    file: "StepRegistry.sol/StepRegistry.json" },
    { name: "StepCoin",        file: "StepCoin.sol/StepCoin.json" },
    { name: "StepDex",         file: "StepDex.sol/StepDex.json" },
    { name: "ReserveLib",      file: "StepNetLib.sol/ReserveLib.json" },
    { name: "PendingLib",      file: "StepNetLib.sol/PendingLib.json" },
    { name: "WalletLib",       file: "StepNetLib.sol/WalletLib.json" },
    { name: "ImportLib",       file: "StepNetLib.sol/ImportLib.json" },
    { name: "ClubSyncLib",     file: "StepNetLib.sol/ClubSyncLib.json" },
    { name: "LeaderboardLib",  file: "StepNetView.sol/LeaderboardLib.json" }, // ← جدید
    { name: "StepNet",         file: "StepNet.sol/StepNet.json" },
    { name: "StepNetView",     file: "StepNetView.sol/StepNetView.json" },
    { name: "StepNFTTreasury", file: "StepNFTTreasury.sol/StepNFTTreasury.json" },
    { name: "StepClub",        file: "StepClub.sol/StepClub.json" },
    { name: "StepNetImporter", file: "StepNetLib.sol/StepNetImporter.json" },
    { name: "StepSubscription",file: "StepSubscription.sol/StepSubscription.json" },
  ];

  let indexJS = `// Auto-generated — ${new Date().toISOString()}\n\n`;

  for (const c of abiContracts) {
    const artPath = path.join("artifacts/contracts", c.file);
    if (fs.existsSync(artPath)) {
      const abi = JSON.parse(fs.readFileSync(artPath, "utf8")).abi;
      fs.writeFileSync(path.join(abiDir, `${c.name}.json`), JSON.stringify(abi, null, 2));
      indexJS += `export const ${c.name}ABI = ${JSON.stringify(abi, null, 2)};\n\n`;
      ok(`abis/${c.name}.json`);
    } else {
      warn(`Artifact not found: ${artPath}`);
    }
  }
  fs.writeFileSync(path.join(abiDir, "index.js"), indexJS);
  ok("abis/index.js");

  // deployed-addresses.json
  const deploymentInfo = {
    network      : hre.network.name,
    chainId      : hre.network.config.chainId,
    timestamp    : new Date().toISOString(),
    deployer     : DEPLOYER,
    status       : "PENDING_FINALIZE — import کاربران را انجام دهید، سپس finalizeSetup را اجرا کنید",
    wallets      : { wallet90: WALLET_90, wallet10: WALLET_10, dev: DEV_WALLET, msgAdmin: MSG_ADMIN },
    contracts    : addr,
    constructorArgs: cArgs,
    libraries    : {
      ReserveLib   : addr.ReserveLib,
      PendingLib   : addr.PendingLib,
      WalletLib    : addr.WalletLib,
      ImportLib    : addr.ImportLib,
      ClubSyncLib  : addr.ClubSyncLib,
      LeaderboardLib: addr.LeaderboardLib,   // ← جدید
    },
    registry     : {
      STEP_COIN    : addr.StepCoin,
      STEP_DEX     : addr.StepDex,
      STEP_NET     : addr.StepNet,
      STEP_NET_VIEW: addr.StepNetView,
      NFT_TREASURY : addr.StepNFTTreasury,
      CLUB_TREASURY: addr.StepClub,
      DEV_TREASURY : DEV_WALLET,
    },
    nextSteps: [
      "1) importer.batchImport([...users]) را برای هر batch اجرا کنید",
      "2) پس از اتمام همه batchها، finalizeSetup() را روی StepNet اجرا کنید",
      `3) net = await ethers.getContractAt("StepNet", "${addr.StepNet}")`,
      "4) await net.finalizeSetup()",
    ],
  };
  fs.writeFileSync("./deployed-addresses.json", JSON.stringify(deploymentInfo, null, 2));
  ok("deployed-addresses.json");

  // .env.contracts
  const envLines = [
    `# Step Ecosystem — ${hre.network.name} — ${new Date().toISOString()}`,
    `# STATUS: PENDING_FINALIZE`,
    `NEXT_PUBLIC_REGISTRY=${addr.StepRegistry}`,
    `NEXT_PUBLIC_MOCK_DAI=${addr.MockDAI}`,
    `NEXT_PUBLIC_STEP_COIN=${addr.StepCoin}`,
    `NEXT_PUBLIC_STEP_DEX=${addr.StepDex}`,
    `NEXT_PUBLIC_RESERVE_LIB=${addr.ReserveLib}`,
    `NEXT_PUBLIC_PENDING_LIB=${addr.PendingLib}`,
    `NEXT_PUBLIC_WALLET_LIB=${addr.WalletLib}`,
    `NEXT_PUBLIC_IMPORT_LIB=${addr.ImportLib}`,
    `NEXT_PUBLIC_CLUB_SYNC_LIB=${addr.ClubSyncLib}`,
    `NEXT_PUBLIC_LEADERBOARD_LIB=${addr.LeaderboardLib}`, // ← جدید
    `NEXT_PUBLIC_STEP_NET=${addr.StepNet}`,
    `NEXT_PUBLIC_STEP_NET_VIEW=${addr.StepNetView}`,
    `NEXT_PUBLIC_NFT_TREASURY=${addr.StepNFTTreasury}`,
    `NEXT_PUBLIC_STEP_CLUB=${addr.StepClub}`,
    `NEXT_PUBLIC_STEP_NET_IMPORTER=${addr.StepNetImporter}`,
    `NEXT_PUBLIC_STEP_SUBSCRIPTION=${addr.StepSubscription}`,
    `NEXT_PUBLIC_SUBSCRIPTION_TREASURY=${SUBSCRIPTION_TREASURY}`,
    `NEXT_PUBLIC_CHAIN_ID=${hre.network.config.chainId}`,
  ].join("\n");
  fs.writeFileSync("./.env.contracts", envLines);
  ok(".env.contracts");

  // abis/addresses.ts
  const tsContent =
`// Auto-generated — ${hre.network.name} — ${new Date().toISOString()}
// STATUS: PENDING_FINALIZE — بعد از import، finalizeSetup را اجرا کنید

export const CONTRACTS = {
  Registry        : "${addr.StepRegistry}",
  MockDAI         : "${addr.MockDAI}",
  StepCoin        : "${addr.StepCoin}",
  StepDex         : "${addr.StepDex}",
  StepNet         : "${addr.StepNet}",
  StepNetView     : "${addr.StepNetView}",
  StepClub        : "${addr.StepClub}",
  StepNFTTreasury : "${addr.StepNFTTreasury}",
  StepNetImporter : "${addr.StepNetImporter}",
  StepSubscription: "${addr.StepSubscription}",
} as const;

export const LIBRARIES = {
  ReserveLib    : "${addr.ReserveLib}",
  PendingLib    : "${addr.PendingLib}",
  WalletLib     : "${addr.WalletLib}",
  ImportLib     : "${addr.ImportLib}",
  ClubSyncLib   : "${addr.ClubSyncLib}",
  LeaderboardLib: "${addr.LeaderboardLib}",   // ← جدید
} as const;

export const CHAIN_ID = ${hre.network.config.chainId};
`;
  fs.writeFileSync("./abis/addresses.ts", tsContent);
  ok("abis/addresses.ts");

  // ══════════════════════════════════════════════════════════════════════════
  // خلاصه نهایی
  // ══════════════════════════════════════════════════════════════════════════
  const duration = ((Date.now() - startTime) / 1000).toFixed(1);

  log("\n   ╔══════════════════════════════════════════════════════════╗");
  log("   ║              🎉 DEPLOYMENT COMPLETE                     ║");
  log("   ╚══════════════════════════════════════════════════════════╝");
  log(`\n   ⏱  Duration: ${duration}s\n`);

  log("   ─── Contracts ────────────────────────────────────────────");
  log(`   MockDAI          : ${addr.MockDAI}`);
  log(`   StepRegistry     : ${addr.StepRegistry}`);
  log(`   StepCoin         : ${addr.StepCoin}`);
  log(`   StepDex          : ${addr.StepDex}`);
  log(`   ReserveLib       : ${addr.ReserveLib}    (library)`);
  log(`   PendingLib       : ${addr.PendingLib}    (library)`);
  log(`   WalletLib        : ${addr.WalletLib}    (library)`);
  log(`   ImportLib        : ${addr.ImportLib}    (library)`);
  log(`   ClubSyncLib      : ${addr.ClubSyncLib}    (library)`);
  log(`   LeaderboardLib   : ${addr.LeaderboardLib}    (library — linked to StepNetView)`); // ← جدید
  log(`   StepNet          : ${addr.StepNet}    (linked → 5 libraries)`);
  log(`   StepNetView      : ${addr.StepNetView}    (linked → LeaderboardLib)`);
  log(`   StepNFTTreasury  : ${addr.StepNFTTreasury}`);
  log(`   StepClub         : ${addr.StepClub}`);
  log(`   StepNetImporter  : ${addr.StepNetImporter}`);
  log(`   StepSubscription : ${addr.StepSubscription}    (subscription / license paywall)`);

  log("\n   ─── تنظیمات انجام‌شده ─────────────────────────────────────");
  log("   ✅  Registry: همه قراردادها ثبت شدند");
  log("   ✅  Registry: setStepNet + setStepNetView ست شدند");
  log("   ✅  StepDex: 1,000,000 STEP + لیکوییدیتی اولیه");
  log("   ✅  StepNet: setImporter اجرا شد");
  log("   ⛔  StepNet: finalizeSetup اجرا نشد — بعد از import اجرا کنید");

  log("\n   ─── مراحل بعدی (import + finalize) ───────────────────────");
  log(`   const importer = await ethers.getContractAt(`);
  log(`     "StepNetImporter", "${addr.StepNetImporter}"`);
  log(`   );`);
  log(`   await importer.batchImport([user1, user2, ...]);  // حداکثر 150 در هر batch`);
  log(`   `);
  log(`   // بعد از اتمام همه import‌ها:`);
  log(`   const net = await ethers.getContractAt(`);
  log(`     "StepNet", "${addr.StepNet}"`);
  log(`   );`);
  log(`   await net.finalizeSetup();`);

  log("\n   ─── فایل‌های تولید شده ────────────────────────────────────");
  log("   📄 deployed-addresses.json");
  log("   📄 .env.contracts (شامل NEXT_PUBLIC_LEADERBOARD_LIB)");
  log("   📄 abis/*.json  +  abis/index.js  +  abis/addresses.ts");
  log("\n   موفق باشید! 🚀\n");
}

main()
  .then(() => process.exit(0))
  .catch(e => {
    console.error("\n   ❌ FATAL ERROR:", e);
    process.exit(1);
  });