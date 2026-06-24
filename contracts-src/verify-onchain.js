#!/usr/bin/env node
/* eslint-disable no-console */
// ─────────────────────────────────────────────────────────────────────────────
// verify-onchain.js — Reads the LIVE governance/admin state of the StepNet
// contracts on Polygon mainnet and prints a plain pass/fail report.
//
// Answers the "تأیید کن" items from the technical review:
//   • StepRegistry.daoActive / controlRenounced / controller
//   • Owners of StepSubscription / StepNFTTreasury
//   • StepSubscription.treasury / granter
//   • Which addresses sit in StepCoin's 2-slot levy whitelist
//
// Run:  node contracts-src/verify-onchain.js
//   (optional)  RPC_URL=https://your-node  node contracts-src/verify-onchain.js
// ─────────────────────────────────────────────────────────────────────────────
const { ethers } = require('ethers');

const RPCS = [
  process.env.RPC_URL,
  'https://polygon-bor-rpc.publicnode.com',
  'https://polygon-rpc.com',
  'https://polygon.drpc.org',
  'https://rpc.ankr.com/polygon',
].filter(Boolean);

const A = {
  REGISTRY:      '0x708fA8F368D15B8293cD6c0A29a790fC1c7F13Ce',
  STEP_COIN:     '0x259c17323F9a38118a10D979f21F9eBafAE9c0F6',
  STEP_DEX:      '0x512964f922Ec791a93b5E70ED3c9aC09ec4dCf10',
  STEP_NET:      '0xeD4a3704d23a134C2219534C601a44fd677A77ff',
  NFT_TREASURY:  '0x49de1a6516A1eEDb6269224953F03e55F72Dc68c',
  STEP_CLUB:     '0x00d76a71f9c89C79406ed170583BEDb45f3c7AE6',
  SUBSCRIPTION:  '0x40d14915073c76b7ba4601804413ac4646d123D6',
  DEPLOYER:      '0x902EFCE5A39F1e883Fc73473A481472fc5B0aE8c',
};

// Map known addresses → human labels so the report is readable.
const LABELS = Object.fromEntries(
  Object.entries(A).filter(([, v]) => v).map(([k, v]) => [v.toLowerCase(), k])
);
const label = (addr) => {
  if (!addr || addr === ethers.ZeroAddress) return '∅ (zero)';
  const l = LABELS[addr.toLowerCase()];
  return l ? `${addr} (${l})` : addr;
};

const ABI = {
  registry: [
    'function controller() view returns (address)',
    'function controlRenounced() view returns (bool)',
    'function daoActive() view returns (bool)',
    'function migrationTimelock() view returns (uint256)',
  ],
  coin: [
    'function whitelistCount() view returns (uint256)',
    'function whitelistedAddresses(uint256) view returns (address)',
    'function isWhitelisted(address) view returns (bool)',
  ],
  ownable: ['function owner() view returns (address)'],
  sub: [
    'function owner() view returns (address)',
    'function treasury() view returns (address)',
    'function granter() view returns (address)',
  ],
};

async function getProvider() {
  for (const url of RPCS) {
    try {
      const p = new ethers.JsonRpcProvider(url, 137, { staticNetwork: true });
      await p.getBlockNumber();
      console.log(`RPC: ${url}\n`);
      return p;
    } catch { /* try next */ }
  }
  throw new Error('No working RPC endpoint');
}

const safe = async (fn, fallback = '⚠️ call failed') => {
  try { return await fn(); } catch (e) { return `${fallback} (${e.shortMessage || e.code || e.message})`; }
};

(async () => {
  const p = await getProvider();
  const c = (addr, abi) => new ethers.Contract(addr, abi, p);

  console.log('══════════════════════════════════════════════════════════════');
  console.log(' StepNet — LIVE on-chain governance / admin state (Polygon 137)');
  console.log('══════════════════════════════════════════════════════════════\n');

  // 1) Registry — the heart of the "no backdoor" claim
  const reg = c(A.REGISTRY, ABI.registry);
  const daoActive        = await safe(() => reg.daoActive());
  const controlRenounced = await safe(() => reg.controlRenounced());
  const controller       = await safe(() => reg.controller());
  const timelock         = await safe(() => reg.migrationTimelock());

  console.log('[1] StepRegistry');
  console.log(`    daoActive        : ${daoActive}`);
  console.log(`    controlRenounced : ${controlRenounced}`);
  console.log(`    controller       : ${label(controller)}`);
  console.log(`    migrationTimelock: ${timelock} s`);
  const liveController = controlRenounced === false;
  console.log(`    → VERDICT: ${liveController
    ? '🔴 controller is STILL ACTIVE — it can veto every proposal (live admin power)'
    : '🟢 control renounced — registry changes go through DAO only'}`);
  if (daoActive === false) console.log('    → ⚠️ daoActive=false — DAO not yet turned on; bootstrap powers still apply.');
  console.log();

  // 2) Ownable modules outside the DAO
  console.log('[2] Owner-gated modules (outside DAO governance)');
  const subOwner = await safe(() => c(A.SUBSCRIPTION, ABI.sub).owner());
  const subTreas = await safe(() => c(A.SUBSCRIPTION, ABI.sub).treasury());
  const subGrant = await safe(() => c(A.SUBSCRIPTION, ABI.sub).granter());
  console.log(`    StepSubscription.owner    : ${label(subOwner)}`);
  console.log(`    StepSubscription.treasury : ${label(subTreas)}  ← subscription revenue lands here`);
  console.log(`    StepSubscription.granter  : ${label(subGrant)}`);

  const nftOwner = await safe(() => c(A.NFT_TREASURY, ABI.ownable).owner());
  console.log(`    StepNFTTreasury.owner     : ${label(nftOwner)}`);

  const flagDeployer = [subOwner, nftOwner].some(
    (o) => typeof o === 'string' && o.toLowerCase() === A.DEPLOYER.toLowerCase()
  );
  console.log(`    → VERDICT: ${flagDeployer
    ? '🔴 a module owner is still the DEPLOYER EOA — move to multisig / renounce'
    : '🟡 verify each owner above is a multisig (or zero if renounced)'}`);
  console.log();

  // 3) StepCoin levy whitelist (capacity 2)
  console.log('[3] StepCoin levy whitelist (capacity 2)');
  const coin = c(A.STEP_COIN, ABI.coin);
  const count = await safe(() => coin.whitelistCount());
  console.log(`    whitelistCount: ${count}`);
  for (let i = 0; i < 2; i++) {
    const addr = await safe(() => coin.whitelistedAddresses(i));
    console.log(`    slot[${i}]       : ${label(addr)}`);
  }
  // Are the core value-moving contracts exempt?
  for (const name of ['STEP_DEX', 'STEP_NET', 'STEP_CLUB', 'NFT_TREASURY', 'SUBSCRIPTION']) {
    const ex = await safe(() => coin.isWhitelisted(A[name]));
    console.log(`    isWhitelisted(${name.padEnd(12)}): ${ex}`);
  }
  console.log();

  console.log('══════════════════════════════════════════════════════════════');
  console.log(' Done. Items marked 🔴 are the live admin facts to disclose/fix.');
  console.log('══════════════════════════════════════════════════════════════');
})().catch((e) => { console.error('FATAL:', e); process.exit(1); });
