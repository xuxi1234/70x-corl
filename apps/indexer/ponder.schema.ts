export const ponderSchema = Object.freeze({
  project: ["chainId", "address", "vault", "templateId", "configHash", "status"],
  projectConfig: ["chainId", "project", "configHash", "source"],
  vaultState: ["chainId", "vault", "sharesSold", "totalPaid", "state"],
  transaction: ["id", "chainId", "txHash", "logIndex", "blockNumber", "eventName", "entityId"],
  verificationAttempt: ["chainId", "project", "provider", "status", "attempt"],
});
