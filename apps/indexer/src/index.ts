import { applyLifecycleEvent } from "./handlers/lifecycle";

export type ProtocolLog = {
  chainId: number;
  blockNumber: bigint;
  blockHash: string;
  txHash: string;
  logIndex: number;
  eventName: string;
  address: string;
  args: Record<string, unknown>;
};

export type ProjectRow = {
  chainId: number; address: string; token?: string; vault?: string; templateId?: string; version?: number;
  creator?: string; fee?: bigint; revenueRecipient?: string; configHash?: string; status: string;
};
export type VaultStateRow = {
  chainId: number; vault: string; sharesSold: bigint; totalPaid: bigint; state: string; executionAttempts: number;
  claimedTokens: bigint; refundedNative: bigint; rewardFunded: bigint; rewardClaimed: bigint;
  buybackFunded: bigint; buybackSpent: bigint; tokensBurned: bigint; lpDisposition?: "burned" | "locked";
  liquidityToken?: string; lastFailureHash?: string;
};
export type TransactionRow = {
  id: string; chainId: number; txHash: string; logIndex: number; blockNumber: bigint; blockHash: string;
  confirmations: number; finalized: boolean; eventName: string; entityId: string;
};
export type VerificationAttemptRow = { chainId: number; project: string; provider: string; status: string; attempt: number };
export type Cursor = { chainId: number; blockNumber: bigint; blockHash: string; confirmations: number };

export type ReadModelRows = {
  projects: Map<string, ProjectRow>;
  projectConfigs: Map<string, { chainId: number; project: string; configHash: string; source: "event" | "direct-read" }>;
  vaultStates: Map<string, VaultStateRow>;
  transactions: Map<string, TransactionRow>;
  verificationAttempts: Map<string, VerificationAttemptRow>;
  vaultProjects: Map<string, string>;
  componentProjects: Map<string, string>;
  protocolConfigs: Map<string, { chainId: number; address: string; owner?: string; fee?: bigint; revenueRecipient?: string; paused?: boolean }>;
};

const emptyRows = (): ReadModelRows => ({
  projects: new Map(), projectConfigs: new Map(), vaultStates: new Map(), transactions: new Map(), verificationAttempts: new Map(), vaultProjects: new Map(), componentProjects: new Map(), protocolConfigs: new Map(),
});
const sortAddress = <T extends { address?: string; vault?: string; project?: string }>(values: T[]) => values.sort((a, b) => (a.address ?? a.vault ?? a.project ?? "").localeCompare(b.address ?? b.vault ?? b.project ?? ""));

export class InMemoryReadModel {
  private readonly canonicalLogs = new Map<string, ProtocolLog>();
  private rows = emptyRows();
  private cursorValue: Cursor | null = null;

  apply(logs: readonly ProtocolLog[], cursor: Cursor): void {
    for (const log of logs) {
      if (log.chainId !== cursor.chainId) throw new Error("CHAIN_MISMATCH");
      if (log.blockNumber > cursor.blockNumber) throw new Error("UNFINALIZED_LOG");
      const conflicting = [...this.canonicalLogs.values()].find((item) => item.blockNumber === log.blockNumber && item.blockHash !== log.blockHash);
      if (conflicting) {
        for (const [id, item] of this.canonicalLogs) if (item.blockNumber >= log.blockNumber) this.canonicalLogs.delete(id);
      }
      this.canonicalLogs.set(`${log.chainId}/${log.txHash.toLowerCase()}/${log.logIndex}`, log);
    }
    this.cursorValue = cursor;
    this.rebuild();
  }

  private rebuild(): void {
    this.rows = emptyRows();
    const ordered = [...this.canonicalLogs.values()].sort((a, b) => a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1);
    for (const log of ordered) {
      const id = `${log.chainId}/${log.txHash.toLowerCase()}/${log.logIndex}`;
      this.rows.transactions.set(id, { id, chainId: log.chainId, txHash: log.txHash, logIndex: log.logIndex, blockNumber: log.blockNumber, blockHash: log.blockHash, confirmations: this.cursorValue?.confirmations ?? 0, finalized: log.blockNumber <= (this.cursorValue?.blockNumber ?? 0n), eventName: log.eventName, entityId: log.address });
      applyLifecycleEvent(this.rows, log);
    }
  }

  snapshot() {
    return {
      projects: sortAddress([...this.rows.projects.values()].map((item) => ({ ...item }))),
      projectConfigs: sortAddress([...this.rows.projectConfigs.values()].map((item) => ({ ...item }))),
      vaultStates: sortAddress([...this.rows.vaultStates.values()].map((item) => ({ ...item }))),
      transactions: [...this.rows.transactions.values()].map((item) => ({ ...item })),
      verificationAttempts: sortAddress([...this.rows.verificationAttempts.values()].map((item) => ({ ...item }))),
      protocolConfigs: sortAddress([...this.rows.protocolConfigs.values()].map((item) => ({ ...item }))),
      cursor: this.cursorValue ? { ...this.cursorValue } : null,
    };
  }
}

export function applyProtocolLogs(model: InMemoryReadModel, logs: readonly ProtocolLog[], options: { finalizedBlock: bigint; confirmations: number }): void {
  const chainId = logs[0]?.chainId ?? model.snapshot().cursor?.chainId;
  if (chainId === undefined) throw new Error("CHAIN_REQUIRED");
  const last = [...logs].sort((a, b) => a.blockNumber < b.blockNumber ? -1 : 1).at(-1);
  model.apply(logs, { chainId, blockNumber: options.finalizedBlock, blockHash: last?.blockHash ?? model.snapshot().cursor?.blockHash ?? "0x0", confirmations: options.confirmations });
}
