import type { EvidenceTransaction } from "../evidence";
import type { TemplateId } from "@70x/protocol";

export type ScenarioStage = { name: string; requiredEvents: string[]; assertion: string };
export type LifecycleScenario = { id: string; templateId: TemplateId; stages: ScenarioStage[]; specializedAssertions: string[] };
export type TransactionExecutor = {
  send(stage: ScenarioStage): Promise<string>;
  waitReceipt(hash: string): Promise<EvidenceTransaction["receipt"] & { logs: EvidenceTransaction["decodedEvents"] }>;
};

export async function send(executor: TransactionExecutor, stage: ScenarioStage): Promise<string> { return executor.send(stage); }
export async function waitReceipt(executor: TransactionExecutor, hash: string) {
  const receipt = await executor.waitReceipt(hash);
  if (receipt.status !== 1) throw new Error(`FAILED_RECEIPT:${hash}`);
  return receipt;
}
export function decodeRequiredEvents(stage: ScenarioStage, logs: EvidenceTransaction["decodedEvents"]) {
  for (const required of stage.requiredEvents) if (!logs.some((log) => log.name === required)) throw new Error(`MISSING_EVENT:${stage.name}:${required}`);
  return logs;
}
