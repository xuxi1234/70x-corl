import { prepareVerification, type VerificationAdapter, type VerificationProject } from "./verify";

export type ProviderAttempt = { provider: VerificationAdapter["name"]; status: "Pending" | "Verified" | "Failed"; url?: string; attempts: number; error?: "RATE_LIMITED" };
export type VerificationRecord = {
  address: string;
  overallStatus: "Pending" | "Verified" | "Failed";
  constructorArguments: `0x${string}`;
  sourceHash: `0x${string}`;
  providers: ProviderAttempt[];
  nextRetryAt?: number;
};

type Job = { project: VerificationProject; adapters: readonly VerificationAdapter[]; record: VerificationRecord };
const MAX_DELAY_MS = 6 * 60 * 60 * 1_000;

export class InMemoryVerificationQueue {
  private readonly jobs = new Map<string, Job>();
  private readonly sources = new Map<string, unknown>();

  get(address: string): VerificationRecord | undefined { return this.jobs.get(address.toLowerCase())?.record; }
  getSource(sourceHash: string): unknown { return this.sources.get(sourceHash.toLowerCase()); }
  storeSource(sourceHash: string, standardJsonInput: unknown): void { this.sources.set(sourceHash.toLowerCase(), standardJsonInput); }
  register(project: VerificationProject, adapters: readonly VerificationAdapter[], record: VerificationRecord): void { this.jobs.set(project.address.toLowerCase(), { project, adapters, record }); }

  async retryPending(now: number): Promise<VerificationRecord[]> {
    const changed: VerificationRecord[] = [];
    for (const job of this.jobs.values()) {
      if (job.record.overallStatus !== "Pending" || (job.record.nextRetryAt ?? Infinity) > now) continue;
      changed.push(await execute(job.project, job.adapters, this, now, job.record));
    }
    return changed;
  }
}

export async function execute(project: VerificationProject, adapters: readonly VerificationAdapter[], queue: InMemoryVerificationQueue, now: number, previous?: VerificationRecord): Promise<VerificationRecord> {
  if (previous?.overallStatus === "Verified") return previous;
  const prepared = prepareVerification(project);
  queue.storeSource(prepared.sourceHash, prepared.standardJsonInput);
  const old = new Map(previous?.providers.map((item) => [item.provider, item]));
  const providers: ProviderAttempt[] = [];
  let retryAttempts = 0;
  for (const adapter of adapters) {
    const prior = old.get(adapter.name);
    if (prior?.status === "Verified") { providers.push(prior); continue; }
    const response = await adapter.submit(prepared);
    const attempts = (prior?.attempts ?? 0) + 1;
    retryAttempts = Math.max(retryAttempts, attempts);
    providers.push({
      provider: adapter.name,
      status: response.status === "Verified" ? "Verified" : response.status === "Failed" ? "Failed" : "Pending",
      attempts,
      ...(response.url ? { url: response.url } : {}),
      ...(response.status === "RateLimited" ? { error: "RATE_LIMITED" as const } : {}),
    });
  }
  const overallStatus = providers.every((item) => item.status === "Verified") ? "Verified" : providers.every((item) => item.status === "Failed") ? "Failed" : "Pending";
  const delay = Math.min(MAX_DELAY_MS, 60_000 * 2 ** Math.max(0, retryAttempts - 1));
  const record: VerificationRecord = {
    address: project.address,
    overallStatus,
    constructorArguments: prepared.constructorArguments,
    sourceHash: prepared.sourceHash,
    providers,
    ...(overallStatus === "Pending" ? { nextRetryAt: now + delay } : {}),
  };
  queue.register(project, adapters, record);
  return record;
}
