import type { LifecycleScenario } from "./types";
import { validateEvidence, type EvidenceBundle } from "../evidence";
import { compareConfig, readBothRpcs } from "../rpc-compare";
import { canonicalScenarioManifests } from "../scenario-manifest";
import { decodeRequiredEvents, send, waitReceipt, type TransactionExecutor } from "./types";

export const scenarios: LifecycleScenario[] = canonicalScenarioManifests.map((item) => ({
  id: item.id,
  templateId: item.templateId,
  stages: item.stages.map((stage) => ({ ...stage, requiredEvents: [...stage.requiredEvents] })),
  specializedAssertions: [...item.specializedAssertions],
}));

export async function runLifecycleScenario(input: {
  scenario: LifecycleScenario;
  executor: TransactionExecutor;
  releaseCommit: string;
  addresses: Record<string, string>;
  deployedContracts: EvidenceBundle["deployedContracts"];
  readPrimary: () => Promise<Record<string, unknown>>;
  readSecondary: () => Promise<Record<string, unknown>>;
  rpcProviders: { primary: "publicnode" | "bnbchain"; secondary: "publicnode" | "bnbchain" };
  verification: EvidenceBundle["verification"];
  config: EvidenceBundle["config"];
}): Promise<EvidenceBundle> {
  const transactions: EvidenceBundle["transactions"] = [];
  const rpcSnapshots: EvidenceBundle["rpcSnapshots"] = [];
  for (const stage of input.scenario.stages) {
    const hash = await send(input.executor, stage);
    const receipt = await waitReceipt(input.executor, hash);
    const decodedEvents = decodeRequiredEvents(stage, receipt.logs);
    const { logs: _logs, ...receiptEvidence } = receipt;
    transactions.push({ scope: "lifecycle", stage: stage.name, assertion: stage.assertion, resumed: false, hash, receipt: receiptEvidence, requiredEvents: stage.requiredEvents, decodedEvents });
    rpcSnapshots.push({ scope: "lifecycle", ...await readBothRpcs(stage.name, input.readPrimary, input.readSecondary, {
      blockNumber: receipt.blockNumber,
      blockHash: receipt.blockHash,
      primaryProvider: input.rpcProviders.primary,
      secondaryProvider: input.rpcProviders.secondary,
    }) });
  }
  const evidence: EvidenceBundle = {
    schemaVersion: 1,
    releaseCommit: input.releaseCommit,
    scenario: input.scenario.id,
    chainId: 97,
    addresses: input.addresses,
    deployedContracts: input.deployedContracts,
    transactions,
    rpcSnapshots,
    verification: input.verification,
    config: { ...compareConfig(input.config.form, input.config.chain, input.config.index), direct: input.config.chain, encoded: input.config.encoded },
  };
  validateEvidence(evidence);
  return evidence;
}

export * from "./types";
