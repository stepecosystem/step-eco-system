require("@nomicfoundation/hardhat-toolbox");

// Compile the REAL production contracts from ../contracts-src (single source of
// truth — no copies, no drift). Test-only mocks live in ../contracts-src/mocks.
// Compiler settings mirror the mainnet deploy exactly (see
// step-ecosystem/hardhat.config.recommended.js): 0.8.35 + viaIR + runs:1 + paris.
module.exports = {
  solidity: {
    version: "0.8.35",
    settings: {
      optimizer: { enabled: true, runs: 1 },
      viaIR: true,
      // Tests target cancun (OZ 5.6's Bytes.sol uses the `mcopy` opcode).
      // This is logic-equivalent for these contracts; the mainnet bytecode was
      // built for "paris" (see step-ecosystem/hardhat.config.recommended.js).
      evmVersion: "cancun",
      metadata: { bytecodeHash: "none" },
    },
  },
  // `contracts/` is a symlink to ../contracts-src so Hardhat compiles the real
  // production sources directly (no copies, no drift). Git preserves the
  // symlink; on a Linux CI checkout it resolves to contracts-src at the repo
  // root. (Hardhat requires sources inside the project, hence the symlink
  // rather than an out-of-tree path or a rooted-up project that can't resolve
  // this folder's node_modules.)
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};
