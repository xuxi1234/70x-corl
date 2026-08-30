import type { ProtocolLog, ReadModelRows } from "../index";

const text = (value: unknown) => typeof value === "string" ? value : undefined;
const amount = (value: unknown) => typeof value === "bigint" ? value : undefined;

export function applyLifecycleEvent(rows: ReadModelRows, log: ProtocolLog): void {
  const event = log.eventName;
  if (event === "ProjectDeployed") {
    const address = text(log.args.project) ?? log.address;
    const vault = text(log.args.vault);
    const configHash = text(log.args.configHash);
    rows.projects.set(address.toLowerCase(), {
      chainId: log.chainId,
      address,
      ...(vault ? { vault } : {}),
      ...(text(log.args.templateId) ? { templateId: text(log.args.templateId)! } : {}),
      ...(configHash ? { configHash } : {}),
      status: "deployed",
    });
    if (vault) {
      rows.vaultProjects.set(vault.toLowerCase(), address.toLowerCase());
      rows.vaultStates.set(vault.toLowerCase(), { chainId: log.chainId, vault, sharesSold: 0n, totalPaid: 0n, state: "minting" });
    }
    if (configHash) rows.projectConfigs.set(address.toLowerCase(), { chainId: log.chainId, project: address, configHash, source: "event" });
    return;
  }

  const projectKey = rows.vaultProjects.get(log.address.toLowerCase()) ?? log.address.toLowerCase();
  const project = rows.projects.get(projectKey);
  const vaultState = rows.vaultStates.get(log.address.toLowerCase());
  if (event === "MintPurchased" && vaultState) {
    vaultState.sharesSold = amount(log.args.totalSharesSold) ?? vaultState.sharesSold;
    vaultState.totalPaid += amount(log.args.paid) ?? 0n;
  } else if (event === "Filled" && vaultState) {
    vaultState.totalPaid = amount(log.args.totalPaid) ?? vaultState.totalPaid;
    vaultState.state = "filled";
    if (project) project.status = "filled";
  } else if (event === "ExecutionAttempt" && vaultState) {
    vaultState.state = log.args.success === true ? "launched" : "retryable";
  } else if (event === "Launched") {
    if (vaultState) vaultState.state = "launched";
    if (project) project.status = "launched";
  } else if (event === "RefundsEnabled") {
    if (vaultState) vaultState.state = "refunding";
    if (project) project.status = "refunding";
  } else if (event === "Refunded" && vaultState) {
    vaultState.totalPaid -= amount(log.args.nativeAmount) ?? 0n;
  } else if (event === "VerificationAttempt") {
    const provider = text(log.args.provider);
    if (provider) rows.verificationAttempts.set(`${projectKey}/${provider}`, {
      chainId: log.chainId,
      project: project?.address ?? log.address,
      provider,
      status: text(log.args.status) ?? "Pending",
      attempt: Number(log.args.attempt ?? 1),
    });
  }
}
