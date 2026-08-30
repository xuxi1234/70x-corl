export type EvidenceTransaction = { stage: string; hash: string; receipt: { status: 0 | 1; blockNumber: bigint; blockHash: string }; requiredEvents: string[]; decodedEvents: Array<{ name: string; args: Record<string, unknown> }> };
export type EvidenceBundle = {
  schemaVersion: 1;
  releaseCommit: string;
  scenario: string;
  chainId: 97;
  addresses: Record<string, string>;
  transactions: EvidenceTransaction[];
  rpcSnapshots: Array<{ stage: string; primary: Record<string, unknown>; secondary: Record<string, unknown> }>;
  verification: Array<{ provider: string; status: "Pending" | "Verified" | "Failed"; url?: string }>;
  config: { form: Record<string, unknown>; chain: Record<string, unknown>; index: Record<string, unknown> };
};

const txHash = /^0x[0-9a-fA-F]{64}$/;
const commitHash = /^[0-9a-f]{40}$/i;
const canonical = (value: unknown): string => {
  if (typeof value === "bigint") return JSON.stringify(value.toString());
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
  return JSON.stringify(value);
};

export function validateEvidence(input: unknown): asserts input is EvidenceBundle {
  if (!input || typeof input !== "object") throw new Error("EVIDENCE_REQUIRED");
  const evidence = input as EvidenceBundle;
  if (evidence.schemaVersion !== 1 || evidence.chainId !== 97 || !commitHash.test(evidence.releaseCommit)) throw new Error("INVALID_RELEASE_IDENTITY");
  if (!evidence.scenario || !evidence.transactions?.length) throw new Error("EMPTY_SCENARIO");
  for (const transaction of evidence.transactions) {
    if (!txHash.test(transaction.hash)) throw new Error(`MISSING_TRANSACTION_HASH:${transaction.stage}`);
    if (transaction.receipt.status !== 1 || !txHash.test(transaction.receipt.blockHash)) throw new Error(`FAILED_RECEIPT:${transaction.stage}`);
    const names = new Set(transaction.decodedEvents.map((event) => event.name));
    for (const required of transaction.requiredEvents) if (!names.has(required)) throw new Error(`MISSING_EVENT:${transaction.stage}:${required}`);
  }
  for (const snapshot of evidence.rpcSnapshots ?? []) if (canonical(snapshot.primary) !== canonical(snapshot.secondary)) throw new Error(`RPC_DIVERGENCE:${snapshot.stage}`);
  if (!evidence.verification?.length || evidence.verification.some((attempt) => attempt.status !== "Verified")) throw new Error("SOURCE_UNVERIFIED");
  if (canonical(evidence.config.form) !== canonical(evidence.config.chain) || canonical(evidence.config.form) !== canonical(evidence.config.index)) throw new Error("CONFIG_MISMATCH");
}

const secretKey = /private.?key|mnemonic|api[_-]?key|rpc[_-]?(url|credential)/i;
const redact = (value: unknown, key = ""): unknown => {
  if (secretKey.test(key)) return "[REDACTED]";
  if (typeof value === "string") return value.replace(/https:\/\/[^/@\s]+@/g, "https://[REDACTED]@");
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([childKey, item]) => [childKey, redact(item, childKey)]));
  return value;
};

export function writeEvidence(input: EvidenceBundle): string {
  validateEvidence(input);
  return `${JSON.stringify(redact(input), null, 2)}\n`;
}
