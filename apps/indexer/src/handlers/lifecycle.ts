import type { ProjectRow, ProtocolLog, ReadModelRows, VaultStateRow } from "../index";

const text = (value: unknown) => typeof value === "string" ? value : undefined;
const amount = (value: unknown) => typeof value === "bigint" ? value : undefined;
const numeric = (value: unknown) => typeof value === "number" ? value : typeof value === "bigint" ? Number(value) : undefined;
const nonzeroAddress = (value: unknown) => {
  const address = text(value);
  return address && !/^0x0{40}$/i.test(address) ? address : undefined;
};

function emptyVault(chainId: number, vault: string): VaultStateRow {
  return {
    chainId, vault, sharesSold: 0n, totalPaid: 0n, state: "minting", executionAttempts: 0,
    claimedTokens: 0n, refundedNative: 0n, rewardFunded: 0n, rewardClaimed: 0n,
    buybackFunded: 0n, buybackSpent: 0n, tokensBurned: 0n,
  };
}

function projectFor(rows: ReadModelRows, address: string): ProjectRow | undefined {
  const normalized = address.toLowerCase();
  const projectKey = rows.componentProjects.get(normalized) ?? rows.vaultProjects.get(normalized) ?? normalized;
  return rows.projects.get(projectKey);
}

function vaultFor(rows: ReadModelRows, log: ProtocolLog): VaultStateRow | undefined {
  const direct = rows.vaultStates.get(log.address.toLowerCase());
  if (direct) return direct;
  const project = projectFor(rows, log.address);
  return project?.vault ? rows.vaultStates.get(project.vault.toLowerCase()) : undefined;
}

function updateProtocolConfig(rows: ReadModelRows, log: ProtocolLog): void {
  const key = log.address.toLowerCase();
  const config = rows.protocolConfigs.get(key) ?? { chainId: log.chainId, address: log.address };
  const owner = text(log.args.newOwner);
  const fee = amount(log.args.newFee);
  const revenueRecipient = text(log.args.newRecipient);
  if (log.eventName === "OwnershipTransferred" && owner) config.owner = owner;
  if (log.eventName === "FeeChanged" && fee !== undefined) config.fee = fee;
  if (log.eventName === "RevenueRecipientChanged" && revenueRecipient) config.revenueRecipient = revenueRecipient;
  if (log.eventName === "DeploymentsPauseChanged" && typeof log.args.paused === "boolean") config.paused = log.args.paused;
  rows.protocolConfigs.set(key, config);
}

export function applyLifecycleEvent(rows: ReadModelRows, log: ProtocolLog): void {
  const event = log.eventName;
  if (event === "ProjectDeployed") {
    const token = nonzeroAddress(log.args.token);
    const vault = nonzeroAddress(log.args.vault);
    if (!vault) return;
    const address = token ?? vault;
    const configHash = text(log.args.commonConfigHash);
    const project: ProjectRow = {
      chainId: log.chainId,
      address,
      ...(token ? { token } : {}),
      vault,
      ...(text(log.args.id) ? { templateId: text(log.args.id)! } : {}),
      ...(numeric(log.args.version) !== undefined ? { version: numeric(log.args.version)! } : {}),
      ...(text(log.args.creator) ? { creator: text(log.args.creator)! } : {}),
      ...(amount(log.args.fee) !== undefined ? { fee: amount(log.args.fee)! } : {}),
      ...(text(log.args.recipient) ? { revenueRecipient: text(log.args.recipient)! } : {}),
      ...(configHash ? { configHash } : {}),
      status: "deployed",
    };
    const key = address.toLowerCase();
    rows.projects.set(key, project);
    rows.vaultProjects.set(vault.toLowerCase(), key);
    rows.componentProjects.set(address.toLowerCase(), key);
    rows.vaultStates.set(vault.toLowerCase(), emptyVault(log.chainId, vault));
    if (configHash) rows.projectConfigs.set(key, { chainId: log.chainId, project: address, configHash, source: "event" });
    return;
  }

  if (["RewardCompanionDeployed", "BuybackCompanionDeployed", "FinanceCompanionDeployed", "FlapVaultDeployed"].includes(event)) {
    const vault = text(log.args.vault) ?? text(log.args.mintVault);
    const projectKey = vault ? rows.vaultProjects.get(vault.toLowerCase()) : undefined;
    if (projectKey) {
      for (const field of ["companion", "rewardVault", "financeVault", "adapter"]) {
        const component = text(log.args[field]);
        if (component) rows.componentProjects.set(component.toLowerCase(), projectKey);
      }
      const configHash = text(log.args.configHash);
      const project = rows.projects.get(projectKey);
      if (configHash && project) rows.projectConfigs.set(projectKey, { chainId: log.chainId, project: project.address, configHash, source: "event" });
    }
    return;
  }

  const project = projectFor(rows, log.address);
  const vaultState = vaultFor(rows, log);
  if (event === "MintPurchased" && vaultState) {
    vaultState.sharesSold = amount(log.args.totalSharesSold) ?? BigInt(numeric(log.args.totalSharesSold) ?? Number(vaultState.sharesSold));
    vaultState.totalPaid += amount(log.args.paid) ?? 0n;
  } else if (event === "Filled" && vaultState) {
    vaultState.totalPaid = amount(log.args.totalPaid) ?? vaultState.totalPaid;
    vaultState.state = "filled";
    if (project) project.status = "filled";
  } else if (event === "ExecutionAttempt" && vaultState) {
    vaultState.executionAttempts += 1;
    vaultState.state = log.args.success === true ? "executed" : "retryable";
    const resultHash = text(log.args.resultHash);
    if (log.args.success !== true && resultHash) vaultState.lastFailureHash = resultHash;
  } else if (event === "Launched") {
    if (vaultState) {
      vaultState.state = "launched";
      const liquidityToken = text(log.args.liquidityToken) ?? text(log.args.pair);
      if (liquidityToken) vaultState.liquidityToken = liquidityToken;
    }
    if (project) project.status = "launched";
  } else if (event === "RefundsEnabled") {
    if (vaultState) vaultState.state = "refunding";
    if (project) project.status = "refunding";
  } else if (event === "Refunded" && vaultState) {
    const refunded = amount(log.args.nativeAmount) ?? 0n;
    vaultState.refundedNative += refunded;
    vaultState.totalPaid -= refunded;
  } else if (event === "Claimed" && vaultState) {
    vaultState.claimedTokens += amount(log.args.tokenAmount) ?? 0n;
  } else if (event === "RewardFunded" && vaultState) {
    vaultState.rewardFunded += amount(log.args.amount) ?? 0n;
  } else if (event === "RewardClaimed" && vaultState) {
    vaultState.rewardClaimed += amount(log.args.amount) ?? 0n;
  } else if (event === "BuybackFunded" && vaultState) {
    vaultState.buybackFunded += amount(log.args.amount) ?? 0n;
  } else if (event === "BuybackExecuted" && vaultState) {
    vaultState.buybackSpent += amount(log.args.nativeSpent) ?? 0n;
    vaultState.tokensBurned += amount(log.args.tokenBurned) ?? 0n;
  } else if (event === "Burned" && vaultState) {
    vaultState.tokensBurned += amount(log.args.amount) ?? 0n;
  } else if ((event === "LpLocked" || event === "LpBurned") && vaultState) {
    vaultState.lpDisposition = event === "LpLocked" ? "locked" : "burned";
    const liquidityToken = text(log.args.lpToken);
    if (liquidityToken) vaultState.liquidityToken = liquidityToken;
  } else if (["OwnershipTransferred", "FeeChanged", "RevenueRecipientChanged", "DeploymentsPauseChanged"].includes(event)) {
    updateProtocolConfig(rows, log);
  } else if (event === "VerificationAttempt") {
    const provider = text(log.args.provider);
    const projectKey = project?.address.toLowerCase() ?? log.address.toLowerCase();
    if (provider) rows.verificationAttempts.set(`${projectKey}/${provider}`, {
      chainId: log.chainId,
      project: project?.address ?? log.address,
      provider,
      status: text(log.args.status) ?? "Pending",
      attempt: numeric(log.args.attempt) ?? 1,
    });
  }
}
