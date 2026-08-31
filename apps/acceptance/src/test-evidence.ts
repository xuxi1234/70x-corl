import type { EvidenceBundle } from "./evidence";
import { canonicalReference, canonicalScenarioById, canonicalStagePolicy, type CanonicalReferenceRole } from "./scenario-manifest";

export const evidenceHash = (character: string) => `0x${character.repeat(64)}`;
export const evidenceProject = "0x1000000000000000000000000000000000000001";
export const evidenceFactory = "0x2000000000000000000000000000000000000002";
const roleAddress = (role: CanonicalReferenceRole) => role === "factory" || role === "template" || role === "pancakeAdapter" || role === "launchedPair" ? evidenceFactory : evidenceProject;
const eventArgs = (scenarioId: string, stage: string, name: string): Record<string, unknown> => {
  if (name === "ProjectDeployed") return { vault: evidenceProject, fee: "5000000000000000", recipient: evidenceFactory };
  if (name === "MintPurchased") {
    const paid = scenarioId === "flap-joint-launch" ? "100" : "50";
    return { buyer: evidenceProject, shares: 1, paid, totalSharesSold: stage === "FILL" || stage === "WHITELIST_PUBLIC_MINT" ? 2 : 1 };
  }
  if (name === "Approval") return { owner: stage === "POSITION_OPEN_TOKEN_APPROVE" ? evidenceProject : evidenceFactory, spender: evidenceProject, value: "1000000000000000000" };
  if (name === "Filled") return { totalPaid: "100" };
  if (name === "ExecutionAttempt") return { success: stage !== "FLAP_FAIL" && stage !== "EXECUTE_FAIL" };
  if (name === "Launched") return { token: evidenceProject, pair: evidenceFactory, purchasedAmount: "100" };
  if (name === "RefundsEnabled") return { enabledAt: "87400" };
  if (name === "Refunded") return { nativeAmount: scenarioId === "flap-joint-launch" ? "100" : "50", amount: scenarioId === "flap-joint-launch" ? "100" : "50", shares: 1 };
  if (name === "RewardFunded") return { amount: "1000000000000000000" };
  if (name === "RewardClaimed") return { amount: "1" };
  if (["BuybackFunded", "Burned", "Funded"].includes(name)) return { amount: "100" };
  if (name === "BuybackExecuted") return { nativeSpent: "100", tokenBurned: "100" };
  if (name === "PositionOpened") return { principal: "100" };
  if (name === "PositionClaimed") return { amount: "100" };
  if (name === "Transfer" && stage.startsWith("TRANCHE_")) {
    const from = stage === "TRANCHE_RETURN" ? evidenceFactory : evidenceProject;
    const to = stage === "TRANCHE_RETURN" ? evidenceProject : evidenceFactory;
    return { from, to, amount: "1" };
  }
  if (name === "Transfer") return { amount: "100" };
  if (name === "EpochAppended") return { root: evidenceHash("a") };
  if (name === "Claimed") return { account: evidenceProject, shares: 1, tokenAmount: scenarioId === "flap-joint-launch" ? "100" : "50" };
  return {};
};

const stateValues = (scenarioId: string, stageName: string) => {
  const policy = canonicalStagePolicy(scenarioId, stageName);
  const stateByStage: Record<string, string> = { DEPLOY: "0", MINT: scenarioId === "flap-joint-launch" ? "1" : "0", FILL: "1", EXECUTE_FAIL: "1", FINALIZE: "3", CLAIM: "5", FLAP_FAIL: "1", FLAP_RETRY: "3", REFUND_DEPLOY: "0", REFUND_MINT: "0", REFUND_ENABLE: "4", REFUND: "5" };
  const value = (name: string): unknown => {
    if (name === "state") return stateByStage[stageName] ?? "1";
    if (name === "totalPaid") return stageName === "MINT" && scenarioId !== "flap-joint-launch" ? "50" : stageName === "REFUND_MINT" && scenarioId !== "flap-joint-launch" ? "50" : "100";
    if (name === "totalSharesSold") return stageName === "MINT" || stageName === "REFUND_MINT" ? "1" : "2";
    if (name === "lastFailureAt") return "1100";
    if (name === "lastFailureHash") return evidenceHash("7");
    if (name === "liquidityToken" || name === "token") return evidenceProject;
    if (name === "rewardAccounting") return evidenceProject;
    if (name === "pair") return evidenceFactory;
    if (name === "liquidityAmount" || name === "purchasedAmount") return "100";
    if (name === "totalClaimedShares" || name === "totalRefundedShares") return "1";
    if (name === "totalShares") return "2";
    if (name === "claimTokenAllocation") return "100";
    if (name === "createdAt") return "1000";
    if (name === "filledAt") return "0";
    if (name === "protectionDuration") return "300";
    if (name === "sellProtectedUntil") return "2000";
    if (name === "totalFunded") return "1000000000000000000";
    if (name === "totalClaimed") return "1";
    if (name === "totalWeight" || name === "accountedFunds") return "100";
    if (name === "allowance") return "1000000000000000000";
    if (name === "remainingAllowance") return "0";
    if (name === "trancheCount") return stageName === "TRANCHE_RETURN" ? "2" : "1";
    if (name === "tranche0") return { amount: "10", acquiredAt: "1" };
    if (name === "trackedBalance") return stageName === "TRANCHE_RETURN" ? "11" : "10";
    if (name === "weightedBalance") return "10";
    if (name === "threshold" || name === "maxSpend") return "100";
    if (name === "nextExecutionAt") return "2000";
    if (name === "isPublic") return stageName === "WHITELIST_PUBLIC_MINT";
    return "1";
  };
  const blockTimestamp = stageName === "TRANCHE_SPLIT" ? "1000" : stageName === "TRANCHE_RETURN" ? "1100" : stageName === "TRANCHE_CONSUME" ? "1101" : "1100";
  return Object.fromEntries([["blockTimestamp", blockTimestamp], ...policy.reads.map((read) => [read.name, value(read.name)] as const)]);
};

export function validTestEvidence(scenarioId = "flap-joint-launch"): EvidenceBundle {
  const manifest = canonicalScenarioById.get(scenarioId);
  if (!manifest) throw new Error(`unknown test scenario: ${scenarioId}`);
  const transactions: EvidenceBundle["transactions"] = manifest.stages.map((stage, index) => {
    const character = (index + 1).toString(16);
    return {
      scope: "lifecycle", stage: stage.name, assertion: stage.assertion, resumed: false, hash: evidenceHash(character),
      receipt: { status: 1, blockNumber: BigInt(100 + index), blockHash: evidenceHash(character === "1" ? "a" : character), transactionIndex: index, gasUsed: 100_000n, effectiveGasPrice: 3_000_000_000n, from: evidenceProject, to: evidenceFactory, contractAddress: null },
      requiredEvents: [...stage.requiredEvents],
      decodedEvents: canonicalStagePolicy(scenarioId, stage.name).events.map((event, logIndex) => ({ name: event.name, address: roleAddress(event.emitter), logIndex, args: eventArgs(scenarioId, stage.name, event.name) })),
    };
  });
  const sourceHash = evidenceHash("c");
  const runtimeCodeHash = evidenceHash("d");
  const constructorArgumentsHash = evidenceHash("e");
  const verificationBase = { address: evidenceProject, status: "Verified" as const, compilerVersion: "0.8.28+commit.7893614a", sourceHash, constructorArgumentsHash, runtimeCodeHash };
  return {
    schemaVersion: 1, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", scenario: scenarioId, chainId: 97,
    addresses: Object.fromEntries([
      ["project", evidenceProject], ["walletA", evidenceFactory], ["walletB", evidenceProject], ["walletC", evidenceFactory],
      ...manifest.stages.flatMap((stage) => {
        const policy = canonicalStagePolicy(scenarioId, stage.name);
        return [...policy.events.map(({ emitter }) => emitter), ...policy.reads.map(({ target }) => target), policy.target].map((role) => [canonicalReference(scenarioId, manifest.templateId, role), roleAddress(role)] as const);
      }),
    ]),
    deployedContracts: [{
      name: "project", address: evidenceProject, artifact: "LaunchToken.sol/LaunchToken", transactionHash: transactions[0]!.hash,
      creationKind: "event", creationLocator: "ProjectDeployed.vault", creationTransactionInputHash: evidenceHash("9"), creationBytecodeHash: evidenceHash("b"), runtimeCodeHash,
      constructorArgumentsHash, sourceHash, compilerVersion: "0.8.28+commit.7893614a",
    }],
    transactions,
    rpcSnapshots: transactions.map((transaction) => ({
      scope: transaction.scope, stage: transaction.stage, blockNumber: transaction.receipt.blockNumber, blockHash: transaction.receipt.blockHash,
      primaryProvider: "publicnode", secondaryProvider: "bnbchain", primary: stateValues(scenarioId, transaction.stage), secondary: stateValues(scenarioId, transaction.stage),
    })),
    verification: [
      { ...verificationBase, provider: "bscscan", url: `https://testnet.bscscan.com/address/${evidenceProject}#code` },
      { ...verificationBase, provider: "sourcify", url: `https://repo.sourcify.dev/97/${evidenceProject}` },
    ],
    config: {
      form: scenarioId === "flap-joint-launch" ? { goal: "100", totalShares: 1, protectionDuration: "300", receiver: evidenceFactory } : scenarioId === "time-weighted-rewards" ? { totalShares: 2, pricePerShare: "50", growthDuration: "100", maxMultiplierBps: "30000", receiver: evidenceFactory } : { totalShares: 2, pricePerShare: "50", receiver: evidenceFactory },
      encoded: { commonConfig: "0x01", templateConfig: "0x02", deploymentTransaction: transactions[0]!.hash },
      chain: scenarioId === "flap-joint-launch" ? { goal: "100", totalShares: 1, protectionDuration: "300", receiver: evidenceFactory } : scenarioId === "time-weighted-rewards" ? { totalShares: 2, pricePerShare: "50", growthDuration: "100", maxMultiplierBps: "30000", receiver: evidenceFactory } : { totalShares: 2, pricePerShare: "50", receiver: evidenceFactory },
      direct: scenarioId === "flap-joint-launch" ? { goal: "100", totalShares: 1, protectionDuration: "300", receiver: evidenceFactory } : scenarioId === "time-weighted-rewards" ? { totalShares: 2, pricePerShare: "50", growthDuration: "100", maxMultiplierBps: "30000", receiver: evidenceFactory } : { totalShares: 2, pricePerShare: "50", receiver: evidenceFactory },
      index: scenarioId === "flap-joint-launch" ? { goal: "100", totalShares: 1, protectionDuration: "300", receiver: evidenceFactory } : scenarioId === "time-weighted-rewards" ? { totalShares: 2, pricePerShare: "50", growthDuration: "100", maxMultiplierBps: "30000", receiver: evidenceFactory } : { totalShares: 2, pricePerShare: "50", receiver: evidenceFactory },
    },
  };
}
