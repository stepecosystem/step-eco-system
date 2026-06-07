// scripts/deploy-quickswap.js
// ═══════════════════════════════════════════════════════════════════════════════
// 🚀 Deploy QuickSwap — single-tx DAI↔POL swap proxy with a platform fee
//
//   اجرا:
//     FEE_RECIPIENT=0xYourWallet FEE_BPS=50 npx hardhat run scripts/deploy-quickswap.js --network polygon
//
//   • FEE_RECIPIENT : کیف‌پولی که کارمزد به آن می‌رود (پیش‌فرض = خود deployer)
//   • FEE_BPS       : کارمزد به bps (50 = 0.5%). سقف سخت قرارداد = 300 (3%).
//
//   بعد از deploy، آدرس چاپ‌شده را در فرانت‌اند جایگزین router کن:
//     VITE_SWAP_ROUTER=0x...        ← آدرس همین قرارداد QuickSwap
//   سپس rebuild + redeploy فرانت‌اند. (هیچ تغییر کد دیگری لازم نیست — drop-in.)
// ═══════════════════════════════════════════════════════════════════════════════

const hre = require("hardhat");

// Real QuickSwap V2 router on Polygon PoS — the swap is forwarded here after the fee.
const REAL_ROUTER = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const feeRecipient = process.env.FEE_RECIPIENT || deployer.address;
  const feeBps       = Number(process.env.FEE_BPS || 50);

  if (feeBps > 300) throw new Error("FEE_BPS exceeds the contract hard cap (300 = 3%)");

  console.log("Deployer       :", deployer.address);
  console.log("Real V2 router  :", REAL_ROUTER);
  console.log("Fee recipient   :", feeRecipient);
  console.log("Fee bps         :", feeBps, `(${feeBps / 100}%)`);

  const Factory = await hre.ethers.getContractFactory("QuickSwap");
  const c = await Factory.deploy(REAL_ROUTER, feeRecipient, feeBps);
  await c.waitForDeployment();
  const addr = await c.getAddress();

  console.log("\n✅ QuickSwap deployed:", addr);
  console.log("\n── Point the frontend swap at it (replaces the router), then rebuild ──");
  console.log(`VITE_SWAP_ROUTER=${addr}`);

  // Optional Polygonscan verify (needs POLYGONSCAN_API_KEY in hardhat config).
  if (process.env.VERIFY === "1") {
    console.log("\nWaiting 30s before verify…");
    await new Promise(r => setTimeout(r, 30000));
    try {
      await hre.run("verify:verify", { address: addr, constructorArguments: [REAL_ROUTER, feeRecipient, feeBps] });
      console.log("✅ Verified on Polygonscan");
    } catch (e) { console.log("verify skipped/failed:", e.message); }
  }
}

main().catch(e => { console.error(e); process.exit(1); });
