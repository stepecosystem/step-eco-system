require("@nomicfoundation/hardhat-toolbox");

// Compiles the REAL production contracts from ../contracts together with the
// test-only mocks in ../contracts-src/mocks. `npm test` (and CI) assemble both
// into ./contracts first — see the "assemble" script in package.json. Compiler
// settings mirror the mainnet build (../hardhat.config.js): 0.8.35 + viaIR +
// runs:1, except for the EVM target below.
module.exports = {
  solidity: {
    version: "0.8.35",
    settings: {
      optimizer: { enabled: true, runs: 1 },
      viaIR: true,
      // Tests target cancun (OZ 5.6's Bytes.sol uses the `mcopy` opcode).
      // This is logic-equivalent for these contracts; the mainnet bytecode was
      // built for "paris" (see ../hardhat.config.js).
      evmVersion: "cancun",
      metadata: { bytecodeHash: "none" },
    },
  },
  // `contracts/` is generated (gitignored): Hardhat requires sources inside the
  // project, so the production sources are copied in rather than referenced
  // out-of-tree, which would not resolve this folder's node_modules.
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};
