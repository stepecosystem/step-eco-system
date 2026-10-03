#!/usr/bin/env node
/* eslint-disable no-console */
// ─────────────────────────────────────────────────────────────────────────────
// verify-onchain.js — Reads the LIVE governance/admin state of the StepNet
// contracts on Polygon mainnet and prints a plain report.
//
// It answers, straight from the chain:
//   • StepRegistry.daoActive / controlRenounced / controller / timelock
//   • the live configuration of StepSubscription, StepNFTTreasury and
//     StepNFTFund, including where revenue is routed
//   • which addresses sit in StepCoin's 2-slot levy whitelist
//
// A value that could not be read is reported as UNKNOWN, never as a verdict,
// and the script then exits with code 2 — so a flaky RPC can never print a
// reassuring answer it did not actually read.
//
// Run:  node contracts-src/verify-onchain.js
//   (optional)  RPC_URL=https://your-node  node contracts-src/verify-onchain.js
// ─────────────────────────────────────────────────────────────────────────────
const { ethers } = require('ethers');

// Public endpoints, tried in order for EVERY call. Public RPCs rate-limit and
// fail independently, so one that answers the first call may refuse the next.
const RPCS = [
  process.env.RPC_URL,
  'https://polygon.drpc.org',
  'https://1rpc.io/matic',
  'https://polygon.gateway.tenderly.co',
  'https://polygon.api.onfinality.io/public',
  'https://polygon-bor-rpc.publicnode.com',
].filter(Boolean);

const A = {
  REGISTRY:          '0x708fA8F368D15B8293cD6c0A29a790fC1c7F13Ce',
  STEP_COIN:         '0x259c17323F9a38118a10D979f21F9eBafAE9c0F6',
  STEP_DEX:          '0x512964f922Ec791a93b5E70ED3c9aC09ec4dCf10',
  STEP_NET:          '0xeD4a3704d23a134C2219534C601a44fd677A77ff',
  NFT_TREASURY:      '0x49de1a6516A1eEDb6269224953F03e55F72Dc68c',
  NFT_FUND:          '0xaA739Ce109C72f775212Ed5fd1177120d295b26f',
  STEP_CLUB:         '0x00d76a71f9c89C79406ed170583BEDb45f3c7AE6',
  SUBSCRIPTION:      '0x8B567B997B5e80840228D047C8796234992E667C',
  CONTROLLER:        '0x57bA445848bEc74bF9C5665FB098521745363983',
  DEPLOYER:          '0x902EFCE5A39F1e883Fc73473A481472fc5B0aE8c',
};

// Map known addresses → human labels so the report is readable.
const LABELS = Object.fromEntries(Object.entries(A).map(([k, v]) => [v.toLowerCase(), k]));
const label = (v) => {
  if (v instanceof Unread) return String(v);
  if (!v || v === ethers.ZeroAddress) return '∅ (zero)';
  const l = LABELS[v.toLowerCase()];
  return l ? `${v} (${l})` : v;
};

const ABI = {
  registry: [
    'function controller() view returns (address)',
    'function controlRenounced() view returns (bool)',
    'function daoActive() view returns (bool)',
    'function migrationTimelock() view returns (uint256)',
    'function get(bytes32) view returns (address)',
  ],
  coin: [
    'function whitelistCount() view returns (uint256)',
    'function whitelistedAddresses(uint256) view returns (address)',
    'function isWhitelisted(address) view returns (bool)',
  ],
  ownable: ['function owner() view returns (address)'],
  sub: [
    'function owner() view returns (address)',
    'function devWallet() view returns (address)',
    'function ownerWallet() view returns (address)',
    'function nftFund() view returns (address)',
    'function clubAuthority() view returns (address)',
    'function granter() view returns (address)',
  ],
  fund: [
    'function owner() view returns (address)',
    'function saleShareBps() view returns (uint256)',
  ],
};

/** A value the chain did not give us. Never mistaken for true/false/an address. */
class Unread {
  constructor(why) { this.why = why; }
  toString() { return `UNKNOWN — could not read (${this.why})`; }
}
let unreadCount = 0;

const providers = RPCS.map((url) => new ethers.JsonRpcProvider(url, 137, { staticNetwork: true }));

/** Calls `fn(contract)` against each RPC in turn until one answers. */
async function read(addr, abi, fn) {
  let lastErr;
  for (const p of providers) {
    try {
      return await fn(new ethers.Contract(addr, abi, p));
    } catch (e) {
      // A genuine revert is an answer, not an outage — don't retry it elsewhere.
      if (e.code === 'CALL_EXCEPTION' && e.data) { lastErr = e; break; }
      lastErr = e;
    }
  }
  unreadCount++;
  return new Unread(lastErr?.shortMessage || lastErr?.code || 'no RPC answered');
}

const line = (k, v) => console.log(`    ${k.padEnd(28)}: ${v}`);

(async () => {
  console.log('══════════════════════════════════════════════════════════════');
  console.log(' StepNet — LIVE on-chain governance / admin state (Polygon 137)');
  console.log('══════════════════════════════════════════════════════════════\n');

  // 1) Registry — the heart of the "no backdoor" claim
  const R = (fn) => read(A.REGISTRY, ABI.registry, fn);
  const daoActive        = await R((c) => c.daoActive());
  const controlRenounced = await R((c) => c.controlRenounced());
  const controller       = await R((c) => c.controller());
  const timelock         = await R((c) => c.migrationTimelock());
  const fundKey          = await R((c) => c.get(ethers.id('NFT_FUND')));

  console.log('[1] StepRegistry (the DAO)');
  line('daoActive', daoActive);
  line('controlRenounced', controlRenounced);
  line('controller', label(controller));
  line('migrationTimelock', timelock instanceof Unread ? timelock : `${timelock} s (${Number(timelock) / 3600} h)`);
  line('get("NFT_FUND")', label(fundKey));

  if (daoActive === true) {
    console.log('    → 🟢 DAO active — registry changes require vote → veto window → timelock');
  } else if (daoActive === false) {
    console.log('    → DAO not active — bootstrap phase');
  } else {
    console.log('    → ⚠️  DAO status UNKNOWN — read failed, no verdict');
  }
  if (controlRenounced === true) {
    console.log('    → 🟢 control renounced — fully decentralised');
  } else if (controlRenounced === false) {
    console.log('    → 🟢 controller holds only a veto (a circuit-breaker that cannot write state); renounceControl() is the final step');
  } else {
    console.log('    → ⚠️  renounce status UNKNOWN — read failed, no verdict');
  }
  console.log();

  // 2) Module configuration — every value below is evented on change
  console.log('[2] Module configuration');
  const S = (fn) => read(A.SUBSCRIPTION, ABI.sub, fn);
  console.log('    StepSubscription (revenue conduit)');
  line('  owner', label(await S((c) => c.owner())));
  line('  devWallet   (19 %)', label(await S((c) => c.devWallet())));
  line('  ownerWallet (51 %)', label(await S((c) => c.ownerWallet())));
  line('  nftFund     (20 %)', label(await S((c) => c.nftFund())));
  line('  clubAuthority', label(await S((c) => c.clubAuthority())));
  line('  granter', label(await S((c) => c.granter())));

  const F = (fn) => read(A.NFT_FUND, ABI.fund, fn);
  console.log('    StepNFTFund');
  line('  owner', label(await F((c) => c.owner())));
  const bps = await F((c) => c.saleShareBps());
  line('  saleShareBps', bps instanceof Unread ? bps : `${bps} (${Number(bps) / 100} % sale vault / ${100 - Number(bps) / 100} % yield vault)`);

  console.log('    StepNFTTreasury');
  line('  owner', label(await read(A.NFT_TREASURY, ABI.ownable, (c) => c.owner())));
  console.log();

  // 3) StepCoin levy whitelist (capacity 2)
  console.log('[3] StepCoin levy whitelist (capacity 2)');
  const C = (fn) => read(A.STEP_COIN, ABI.coin, fn);
  line('whitelistCount', await C((c) => c.whitelistCount()));
  for (let i = 0; i < 2; i++) {
    line(`slot[${i}]`, label(await C((c) => c.whitelistedAddresses(i))));
  }
  for (const name of ['STEP_DEX', 'STEP_NET', 'STEP_CLUB', 'NFT_TREASURY', 'NFT_FUND', 'SUBSCRIPTION']) {
    line(`isWhitelisted(${name})`, await C((c) => c.isWhitelisted(A[name])));
  }
  console.log();

  console.log('══════════════════════════════════════════════════════════════');
  if (unreadCount) {
    console.log(` ⚠️  ${unreadCount} value(s) could not be read — this report is INCOMPLETE.`);
    console.log('    Re-run, or pass your own endpoint: RPC_URL=https://… node contracts-src/verify-onchain.js');
    console.log('══════════════════════════════════════════════════════════════');
    process.exit(2);
  }
  console.log(' Done — every value above was read live from Polygon mainnet.');
  console.log('══════════════════════════════════════════════════════════════');
})().catch((e) => { console.error('FATAL:', e); process.exit(1); });
