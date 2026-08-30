import type { LifecycleScenario } from "./types";
import { validateEvidence, type EvidenceBundle } from "../evidence";
import { compareConfig, readBothRpcs } from "../rpc-compare";
import { decodeRequiredEvents, send, waitReceipt, type TransactionExecutor } from "./types";

const base = [{ name: "DEPLOY", requiredEvents: ["ProjectDeployed"], assertion: "fee and immutable config" }, { name: "MINT", requiredEvents: ["MintPurchased"], assertion: "paid shares" }, { name: "FILL", requiredEvents: ["Filled"], assertion: "exact goal" }, { name: "FINALIZE", requiredEvents: ["Launched", "LiquidityAdded"], assertion: "pair and LP disposition" }, { name: "CLAIM", requiredEvents: ["Claimed"], assertion: "pro-rata claim" }];
const scenario = (id: string, templateId: string, specializedAssertions: string[], extra = base): LifecycleScenario => ({ id, templateId, stages: extra, specializedAssertions });

export const scenarios: LifecycleScenario[] = [
  scenario("standard-mint", "STANDARD", ["refund branch", "launch retry", "LP burn or lock"]),
  scenario("time-weighted-rewards", "TIME_WEIGHTED", ["tranche aging", "newest tranche consumed first", "3x cap"]),
  scenario("threshold-buyback", "AUTO_BUYBACK", ["threshold", "maximum spend", "slippage", "burn"]),
  scenario("scheduled-buyback", "TIMED_BUYBACK", ["interval", "early execution rejection", "burn"]),
  scenario("native-lp-rewards", "LP_REWARDS", ["canonical LP weight", "minimum LP", "reward claim"]),
  scenario("holder-dead-rewards", "HOLDER_DEAD", ["holder share", "dead share", "excluded liquidity"]),
  scenario("finance-exit-multiple", "FINANCE_EXIT", ["BNB position", "USDT position", "lifetime payout cap"]),
  scenario("wallet-limit-windows", "WALLET_LIMITS", ["non-decreasing limits", "window expiry", "exemptions"]),
  scenario("external-token-burn", "EXTERNAL_BURN", ["route validation", "target compatibility", "target burn"]),
  scenario("whitelist-mint", "WHITELIST", ["Merkle proof", "append-only epoch", "public mint after deadline"]),
  scenario("flap-joint-launch", "FLAP", ["2-16 BNB goal", "adapter retry", "24h refund", "anti-sell protection"], [
    { name: "DEPLOY", requiredEvents: ["ProjectDeployed"], assertion: "0.005 BNB fee" },
    { name: "MINT", requiredEvents: ["MintPurchased"], assertion: "BNB shares" },
    { name: "FLAP_EXECUTE", requiredEvents: ["ExecutionAttempt", "Launched"], assertion: "adapter and first purchase atomic" },
    { name: "CLAIM", requiredEvents: ["Claimed"], assertion: "claims enabled" },
  ]),
];

export async function runLifecycleScenario(input: {
  scenario: LifecycleScenario;
  executor: TransactionExecutor;
  releaseCommit: string;
  addresses: Record<string, string>;
  readPrimary: () => Promise<Record<string, unknown>>;
  readSecondary: () => Promise<Record<string, unknown>>;
  verification: EvidenceBundle["verification"];
  config: EvidenceBundle["config"];
}): Promise<EvidenceBundle> {
  const transactions: EvidenceBundle["transactions"] = [];
  const rpcSnapshots: EvidenceBundle["rpcSnapshots"] = [];
  for (const stage of input.scenario.stages) {
    const hash = await send(input.executor, stage);
    const receipt = await waitReceipt(input.executor, hash);
    const decodedEvents = decodeRequiredEvents(stage, receipt.logs);
    transactions.push({ stage: stage.name, hash, receipt: { status: receipt.status, blockNumber: receipt.blockNumber, blockHash: receipt.blockHash }, requiredEvents: stage.requiredEvents, decodedEvents });
    rpcSnapshots.push(await readBothRpcs(stage.name, input.readPrimary, input.readSecondary));
  }
  const evidence: EvidenceBundle = {
    schemaVersion: 1,
    releaseCommit: input.releaseCommit,
    scenario: input.scenario.id,
    chainId: 97,
    addresses: input.addresses,
    transactions,
    rpcSnapshots,
    verification: input.verification,
    config: compareConfig(input.config.form, input.config.chain, input.config.index),
  };
  validateEvidence(evidence);
  return evidence;
}

export * from "./types";
