#!/usr/bin/env node
/* eslint-disable no-console */
// ─────────────────────────────────────────────────────────────────────────────
// verify-sources.js — Proves that every file in ./contracts is the source of a
// contract deployed on Polygon mainnet.
//
// For each deployed address it fetches the source that Sourcify verified
// against the on-chain bytecode, and compares it with the file in this
// repository. The only differences tolerated are the SPDX license line (this
// repository is proprietary; the deployed sources say MIT) and line endings.
//
// Exit codes: 0 = every file matches · 1 = a file differs · 2 = could not check.
//
// Run:  node contracts-src/verify-sources.js        (Node 18+, no dependencies)
// ─────────────────────────────────────────────────────────────────────────────
const fs = require('fs');
const path = require('path');

const CHAIN_ID = 137;
const DEPLOYED = {
  StepRegistry:       '0x708fA8F368D15B8293cD6c0A29a790fC1c7F13Ce',
  StepNet:            '0xeD4a3704d23a134C2219534C601a44fd677A77ff',
  StepNetView:        '0x944ffb44c6C1777aB599325514c7d14bD4f8c61D',
  StepCoin:           '0x259c17323F9a38118a10D979f21F9eBafAE9c0F6',
  StepDex:            '0x512964f922Ec791a93b5E70ED3c9aC09ec4dCf10',
  StepNFTTreasury:    '0x49de1a6516A1eEDb6269224953F03e55F72Dc68c',
  StepClub:           '0x00d76a71f9c89C79406ed170583BEDb45f3c7AE6',
  StepSubscription:   '0x8B567B997B5e80840228D047C8796234992E667C',
  StepNFTFund:        '0xaA739Ce109C72f775212Ed5fd1177120d295b26f',
};

const CONTRACTS_DIR = path.join(__dirname, '..', 'contracts');
const normalise = (s) =>
  s.replace(/\r\n/g, '\n').replace(/SPDX-License-Identifier: \S+/, 'SPDX-License-Identifier: <license>').trim();

(async () => {
  let differs = 0;
  let unknown = 0;
  const covered = new Set();

  for (const [name, address] of Object.entries(DEPLOYED)) {
    let data;
    try {
      const res = await fetch(`https://sourcify.dev/server/v2/contract/${CHAIN_ID}/${address}?fields=sources`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      data = await res.json();
    } catch (e) {
      console.log(`⚠️  ${name.padEnd(19)} ${address}  UNKNOWN — Sourcify unreachable (${e.message})`);
      unknown++;
      continue;
    }
    if (data.match !== 'match' && data.match !== 'exact_match') {
      console.log(`❌ ${name.padEnd(19)} ${address}  not fully verified on Sourcify (${data.match})`);
      differs++;
      continue;
    }
    for (const [srcPath, { content }] of Object.entries(data.sources || {})) {
      if (srcPath.startsWith('@')) continue; // OpenZeppelin, pinned by package-lock
      const base = path.basename(srcPath);
      const local = base;
      const file = path.join(CONTRACTS_DIR, local);
      covered.add(local);
      if (!fs.existsSync(file)) {
        console.log(`❌ ${name.padEnd(19)} ${address}  ${local} is missing from ./contracts`);
        differs++;
      } else if (normalise(fs.readFileSync(file, 'utf8')) !== normalise(content)) {
        console.log(`❌ ${name.padEnd(19)} ${address}  ${local} DIFFERS from the verified source`);
        differs++;
      } else {
        console.log(`✅ ${name.padEnd(19)} ${address}  ${local} matches the verified source`);
      }
    }
  }

  const extra = fs.readdirSync(CONTRACTS_DIR).filter((f) => f.endsWith('.sol') && !covered.has(f));
  if (!unknown) {
    for (const f of extra) {
      console.log(`❌ ${f} is not the source of any deployed contract listed here`);
      differs++;
    }
  }

  console.log();
  if (differs) { console.log(`${differs} problem(s) found.`); process.exit(1); }
  if (unknown) { console.log(`${unknown} contract(s) could not be checked — result INCOMPLETE.`); process.exit(2); }
  console.log('Every file in ./contracts is the verified source of a deployed contract.');
})().catch((e) => { console.error('FATAL:', e); process.exit(2); });
