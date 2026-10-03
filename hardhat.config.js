require("@nomicfoundation/hardhat-toolbox");

/**
 * Step Eco System — Hardhat configuration.
 *
 * Compiler settings are tuned to bring the two largest contracts
 * (StepNet, StepNetView) under the 24,576-byte EIP-170 limit while keeping
 * behaviour byte-identical to what is deployed on Polygon mainnet:
 *
 *   • version 0.8.35  — first release with an empty known-bugs list.
 *   • optimizer runs 1 — optimizes for the smallest deploy bytecode.
 *   • viaIR true       — the IR pipeline emits ~5–15% smaller, equivalent code.
 *   • evmVersion paris — the exact EVM target the contracts were written for.
 *   • metadata none    — byte-reproducible verification builds.
 *
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    version: "0.8.35",
    settings: {
      optimizer: { enabled: true, runs: 1 },
      viaIR: true,
      evmVersion: "paris",
      metadata: { bytecodeHash: "none" },
    },
  },
  networks: {
    // RPC URLs and the deployer key are read from the environment and are
    // NEVER committed. Copy .env.example to .env and fill in your own values.
    polygon: {
      url: process.env.POLYGON_RPC_URL || "https://polygon-rpc.com",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 137,
    },
    amoy: {
      url: process.env.AMOY_RPC_URL || "https://rpc-amoy.polygon.technology",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 80002,
    },
  },
  etherscan: {
    // Polygonscan API key for `hardhat verify`, read from the environment.
    apiKey: { polygon: process.env.POLYGONSCAN_API_KEY || "" },
  },
};
