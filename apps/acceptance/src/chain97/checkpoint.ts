import { createHash } from "node:crypto";
import { readFile, rename, writeFile } from "node:fs/promises";

export type Chain97CheckpointEntry = {
  executionKey: string;
  transactionHash: string;
  blockNumber: string;
  blockHash: string;
};

export type Chain97Checkpoint = {
  schemaVersion: 1;
  releaseCommit: string;
  planHash: string;
  completed: Chain97CheckpointEntry[];
  integrityHash: string;
};

const hashPattern = /^0x[0-9a-fA-F]{64}$/;
const commitPattern = /^[0-9a-f]{40}$/i;
const canonical = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
  return JSON.stringify(value);
};

const integrity = (checkpoint: Omit<Chain97Checkpoint, "integrityHash">) => `0x${createHash("sha256").update(canonical(checkpoint)).digest("hex")}`;

export function createCheckpoint(input: Omit<Chain97Checkpoint, "schemaVersion" | "integrityHash">): Chain97Checkpoint {
  const transactionHashes = new Set<string>();
  for (const entry of input.completed) {
    const normalized = entry.transactionHash.toLowerCase();
    if (transactionHashes.has(normalized)) throw new Error("CHAIN97_CHECKPOINT_TRANSACTION_DUPLICATE");
    transactionHashes.add(normalized);
  }
  const unsigned = { schemaVersion: 1 as const, ...input };
  return { ...unsigned, integrityHash: integrity(unsigned) };
}

export type CheckpointBinding = { releaseCommit: string; planHash: string };

export function parseCheckpoint(raw: string, releaseCommit: string, planHash: string, compatible: readonly CheckpointBinding[] = []): Chain97Checkpoint {
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { throw new Error("CHAIN97_CHECKPOINT_INVALID"); }
  if (!parsed || typeof parsed !== "object") throw new Error("CHAIN97_CHECKPOINT_INVALID");
  const checkpoint = parsed as Chain97Checkpoint;
  if (checkpoint.schemaVersion !== 1 || !commitPattern.test(checkpoint.releaseCommit) || !hashPattern.test(checkpoint.planHash) || !hashPattern.test(checkpoint.integrityHash) || !Array.isArray(checkpoint.completed)) {
    throw new Error("CHAIN97_CHECKPOINT_INVALID");
  }
  const executionKeys = new Set<string>();
  const transactionHashes = new Set<string>();
  for (const item of checkpoint.completed) {
    if (!item || typeof item.executionKey !== "string" || executionKeys.has(item.executionKey) || !hashPattern.test(item.transactionHash) || !/^[1-9][0-9]*$/.test(item.blockNumber) || !hashPattern.test(item.blockHash)) {
      throw new Error("CHAIN97_CHECKPOINT_INVALID");
    }
    const normalizedTransactionHash = item.transactionHash.toLowerCase();
    if (transactionHashes.has(normalizedTransactionHash)) throw new Error("CHAIN97_CHECKPOINT_TRANSACTION_DUPLICATE");
    executionKeys.add(item.executionKey);
    transactionHashes.add(normalizedTransactionHash);
  }
  const { integrityHash: provided, ...unsigned } = checkpoint;
  if (integrity(unsigned).toLowerCase() !== provided.toLowerCase()) throw new Error("CHAIN97_CHECKPOINT_INTEGRITY_MISMATCH");
  const current = checkpoint.releaseCommit.toLowerCase() === releaseCommit.toLowerCase() && checkpoint.planHash.toLowerCase() === planHash.toLowerCase();
  const migrated = compatible.some((binding) => binding.releaseCommit.toLowerCase() === checkpoint.releaseCommit.toLowerCase() && binding.planHash.toLowerCase() === checkpoint.planHash.toLowerCase());
  if (!current && !migrated) {
    if (checkpoint.releaseCommit.toLowerCase() !== releaseCommit.toLowerCase()) throw new Error("CHAIN97_CHECKPOINT_RELEASE_MISMATCH");
    throw new Error("CHAIN97_CHECKPOINT_PLAN_MISMATCH");
  }
  return checkpoint;
}

export async function loadCheckpoint(path: string | undefined, releaseCommit: string, planHash: string, compatible: readonly CheckpointBinding[] = []): Promise<Chain97Checkpoint> {
  if (!path) return createCheckpoint({ releaseCommit, planHash, completed: [] });
  try { return parseCheckpoint(await readFile(path, "utf8"), releaseCommit, planHash, compatible); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return createCheckpoint({ releaseCommit, planHash, completed: [] });
    throw error;
  }
}

export async function saveCheckpoint(path: string | undefined, checkpoint: Chain97Checkpoint): Promise<void> {
  if (!path) return;
  const temporary = `${path}.tmp`;
  await writeFile(temporary, `${JSON.stringify(checkpoint, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}
