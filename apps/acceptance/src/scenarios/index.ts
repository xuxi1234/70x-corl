import type { LifecycleScenario } from "./types";
import type { TemplateId } from "@70x/protocol";
import { validateEvidence, type EvidenceBundle } from "../evidence";
import { compareConfig, readBothRpcs } from "../rpc-compare";
import { decodeRequiredEvents, send, waitReceipt, type TransactionExecutor } from "./types";

const stage = (name: string, requiredEvents: string[], assertion: string) => ({ name, requiredEvents, assertion });
const launch = [stage("DEPLOY", ["ProjectDeployed"], "fee and immutable config"), stage("MINT", ["MintPurchased"], "paid shares"), stage("FILL", ["Filled"], "exact goal"), stage("FINALIZE", ["Launched", "LiquidityAdded"], "pair and LP disposition"), stage("CLAIM", ["Claimed"], "pro-rata claim")];
const refund = [stage("REFUND_DEPLOY", ["ProjectDeployed"], "independent refund vault"), stage("REFUND_MINT", ["MintPurchased"], "refundable principal"), stage("REFUND", ["RefundsEnabled", "Refunded"], "24-hour exact refund")];
const scenario = (id: string, templateId: TemplateId, specializedAssertions: string[], stages = launch): LifecycleScenario => ({ id, templateId, stages, specializedAssertions });

export const scenarios: LifecycleScenario[] = [
  scenario("standard-mint", "STANDARD", ["refund branch", "launch retry", "LP burn or lock"], [...launch.slice(0, 3), stage("EXECUTE_FAIL", ["ExecutionAttempt"], "failure preserves principal"), ...launch.slice(3), ...refund]),
  scenario("time-weighted-rewards", "TIME_WEIGHTED", ["tranche aging", "newest tranche consumed first", "3x cap"], [...launch, stage("REWARD_FUND", ["RewardFunded"], "fund exact reward amount"), stage("REWARD_CLAIM", ["RewardClaimed"], "age-weighted claim")]),
  scenario("threshold-buyback", "AUTO_BUYBACK", ["threshold", "maximum spend", "slippage", "burn"], [...launch, stage("BUYBACK_FUND", ["BuybackFunded"], "threshold funding"), stage("BUYBACK_EXECUTE", ["BuybackExecuted", "Burned"], "bounded burn")]),
  scenario("scheduled-buyback", "TIMED_BUYBACK", ["interval", "early execution rejection", "burn"], [...launch, stage("BUYBACK_FUND", ["BuybackFunded"], "scheduled funding"), stage("BUYBACK_EXECUTE", ["BuybackExecuted", "Burned"], "interval-respecting burn")]),
  scenario("native-lp-rewards", "LP_REWARDS", ["canonical LP weight", "minimum LP", "reward claim"], [...launch, stage("LP_SYNC", ["LpWeightSynced"], "canonical LP weight"), stage("REWARD_FUND", ["RewardFunded"], "reward funding"), stage("REWARD_CLAIM", ["RewardClaimed"], "LP reward claim")]),
  scenario("holder-dead-rewards", "HOLDER_DEAD", ["holder share", "dead share", "excluded liquidity"], [...launch, stage("REWARD_FUND", ["HolderDeadFunded"], "holder/dead split"), stage("REWARD_CLAIM", ["RewardClaimed"], "holder claim")]),
  scenario("finance-exit-multiple", "FINANCE_EXIT", ["BNB position", "USDT position", "lifetime payout cap"], [...launch, stage("POSITION_OPEN", ["PositionOpened"], "open native and token positions"), stage("POSITION_FUND", ["Funded"], "fund exits"), stage("POSITION_CLAIM", ["PositionClaimed"], "lifetime cap")]),
  scenario("wallet-limit-windows", "LAUNCH_LIMIT", ["non-decreasing limits", "window expiry", "exemptions"], [...launch, stage("LIMIT_TRANSFER", ["Transfer"], "active wallet window")]),
  scenario("external-token-burn", "EXTERNAL_BURN", ["route validation", "target compatibility", "target burn"], [...launch, stage("BUYBACK_FUND", ["BuybackFunded"], "external route funding"), stage("BUYBACK_EXECUTE", ["BuybackExecuted", "Burned"], "external token burn")]),
  scenario("whitelist-mint", "WHITELIST", ["Merkle proof", "append-only epoch", "public mint after deadline"], [stage("DEPLOY", ["ProjectDeployed"], "whitelist deployment"), stage("WHITELIST_EPOCH", ["EpochAppended"], "append-only root"), ...launch.slice(1)]),
  scenario("flap-joint-launch", "FLAP_JOINT", ["2-16 BNB goal", "adapter retry", "24h refund", "anti-sell protection"], [
    { name: "DEPLOY", requiredEvents: ["ProjectDeployed"], assertion: "0.005 BNB fee" },
    { name: "MINT", requiredEvents: ["MintPurchased"], assertion: "BNB shares" },
    { name: "FLAP_FAIL", requiredEvents: ["ExecutionAttempt"], assertion: "adapter failure preserves principal" },
    { name: "FLAP_RETRY", requiredEvents: ["ExecutionAttempt", "Launched"], assertion: "permissionless adapter retry" },
    { name: "CLAIM", requiredEvents: ["Claimed"], assertion: "claims enabled" },
    ...refund,
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
