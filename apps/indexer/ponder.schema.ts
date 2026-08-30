export const ponderSchema = Object.freeze({
  project: ["chainId", "address", "vault", "templateId", "configHash", "status"],
  projectConfig: ["chainId", "project", "configHash", "source"],
  vaultState: ["chainId", "vault", "sharesSold", "totalPaid", "state", "executionAttempts", "claimedTokens", "refundedNative", "rewardFunded", "rewardClaimed", "buybackFunded", "buybackSpent", "tokensBurned", "lpDisposition", "liquidityToken", "lastFailureHash"],
  transaction: ["id", "chainId", "txHash", "logIndex", "blockNumber", "blockHash", "confirmations", "finalized", "eventName", "entityId"],
  verificationAttempt: ["chainId", "project", "provider", "status", "attempt"],
  protocolConfig: ["chainId", "address", "owner", "fee", "revenueRecipient", "paused"],
});
