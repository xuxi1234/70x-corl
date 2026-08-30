export const ponderConfig = Object.freeze({
  networks: { bscTestnet: { chainId: 97, confirmations: 12 } },
  contracts: ["LaunchFactory", "MintVault", "RewardVault", "BuybackVault", "LpLockerAdapter", "PlatformConfig", "Ownable2Step"],
});

export default ponderConfig;
