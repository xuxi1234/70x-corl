import type { TemplateId } from "@70x/protocol";

export type CanonicalLifecycleStage = {
  name: string;
  requiredEvents: readonly string[];
  assertion: string;
};

export type CanonicalReferenceRole = "factory" | "template" | "pancakeAdapter" | "bscUsdt" | "primaryVault" | "primaryToken" | "launchedToken" | "launchedPair" | "refundVault" | "rewardVault" | "rewardAccounting" | "buybackVault" | "financeVault" | "whitelist" | "limits";
export type CanonicalStagePolicy = {
  kind: "factoryDeploy" | "call";
  artifact: string;
  functionName?: string;
  target: CanonicalReferenceRole;
  wallet: "A" | "B" | "C";
  events: readonly { name: string; artifact: string; emitter: CanonicalReferenceRole }[];
  reads: readonly { name: string; artifact: string; functionName: string; target: CanonicalReferenceRole; args: readonly CanonicalPlanArgument[]; capture?: CanonicalReferenceRole }[];
  revertProbes: readonly { name: string; artifact: string; functionName: string; target: CanonicalReferenceRole; wallet: "A" | "B" | "C"; errorArtifact: string; errorName: string }[];
};

export type CanonicalPlanArgument = { ref: string } | { uint: string } | { localAddress: "ZERO" | "DEAD" };

export type CanonicalScenarioManifest = {
  id: string;
  templateId: TemplateId;
  stages: readonly CanonicalLifecycleStage[];
  specializedAssertions: readonly string[];
  requiredDependencies: readonly string[];
  requiredAssets: readonly string[];
  deploymentCaptures: readonly { event: string; argument: string; creation: boolean }[];
  economicPredicates: readonly CanonicalEconomicPredicate[];
};
export type CanonicalEconomicPredicate = "deployment-fee-recipient" | "exact-fill" | "proportional-claim" | "refund-delay-and-proportion" | "failed-execution-preserves-principal" | "tranche-aging-newest-first-cap" | "reward-funding-and-claim" | "buyback-threshold-max-spend-slippage" | "scheduled-buyback-early-rejection" | "lp-weight-and-reward" | "holder-dead-split" | "finance-lifetime-cap" | "wallet-limit-rejection-exemption-expiry" | "whitelist-epoch-proof-public-transition" | "flap-retry-and-protection";

const stage = (name: string, requiredEvents: string[], assertion: string): CanonicalLifecycleStage => ({ name, requiredEvents, assertion });
const launch = [
  stage("DEPLOY", ["ProjectDeployed"], "fee and immutable config"),
  stage("MINT", ["MintPurchased"], "paid shares"),
  stage("FILL", ["MintPurchased", "Filled"], "exact goal"),
  stage("FINALIZE", ["Launched", "LiquidityAdded"], "pair and LP disposition"),
  stage("CLAIM", ["Claimed"], "pro-rata claim"),
] as const;
const refund = [
  stage("REFUND_DEPLOY", ["ProjectDeployed"], "independent refund vault"),
  stage("REFUND_MINT", ["MintPurchased"], "refundable principal"),
  stage("REFUND_ENABLE", ["RefundsEnabled"], "24-hour on-chain delay reached"),
  stage("REFUND", ["Refunded"], "exact principal refund"),
] as const;
const commonDependencies = ["pancakeRouter", "pancakeFactory", "wbnb"] as const;
const projectCaptures = [{ event: "ProjectDeployed", argument: "token", creation: true }, { event: "ProjectDeployed", argument: "vault", creation: true }] as const;

const economicPredicatesFor = (id: string): readonly CanonicalEconomicPredicate[] => {
  const common: CanonicalEconomicPredicate[] = ["deployment-fee-recipient", "exact-fill", "proportional-claim"];
  if (id === "standard-mint") return [...common, "failed-execution-preserves-principal", "refund-delay-and-proportion"];
  if (id === "time-weighted-rewards") return [...common, "tranche-aging-newest-first-cap", "reward-funding-and-claim"];
  if (id === "threshold-buyback" || id === "external-token-burn") return [...common, "buyback-threshold-max-spend-slippage"];
  if (id === "scheduled-buyback") return [...common, "buyback-threshold-max-spend-slippage", "scheduled-buyback-early-rejection"];
  if (id === "native-lp-rewards") return [...common, "lp-weight-and-reward", "reward-funding-and-claim"];
  if (id === "holder-dead-rewards") return [...common, "holder-dead-split", "reward-funding-and-claim"];
  if (id === "finance-exit-multiple") return [...common, "finance-lifetime-cap"];
  if (id === "wallet-limit-windows") return [...common, "wallet-limit-rejection-exemption-expiry"];
  if (id === "whitelist-mint") return ["deployment-fee-recipient", "exact-fill", "proportional-claim", "whitelist-epoch-proof-public-transition"];
  if (id === "flap-joint-launch") return ["deployment-fee-recipient", "exact-fill", "proportional-claim", "failed-execution-preserves-principal", "refund-delay-and-proportion", "flap-retry-and-protection"];
  return common;
};

const manifest = (
  id: string,
  templateId: TemplateId,
  specializedAssertions: string[],
  stages: readonly CanonicalLifecycleStage[] = launch,
  requiredDependencies: readonly string[] = commonDependencies,
  requiredAssets: readonly string[] = [],
  companionEvents: readonly string[] = [],
  companionCaptures: readonly { event: string; argument: string; creation: boolean }[] = [],
): CanonicalScenarioManifest => {
  const canonicalStages = stages.map((item, index) => index === 0 && item.name === "DEPLOY"
    ? { ...item, requiredEvents: [...item.requiredEvents, ...companionEvents] }
    : item);
  const captures = templateId === "FLAP_JOINT"
    ? [{ event: "ProjectDeployed", argument: "token", creation: false }, { event: "ProjectDeployed", argument: "vault", creation: true }, ...companionCaptures]
    : [...projectCaptures, ...companionCaptures];
  return { id, templateId, stages: canonicalStages, specializedAssertions, requiredDependencies, requiredAssets, deploymentCaptures: captures, economicPredicates: economicPredicatesFor(id) };
};

export const canonicalScenarioManifests = [
  manifest("standard-mint", "STANDARD", ["refund branch", "launch retry", "LP burn or lock"], [...launch.slice(0, 3), stage("EXECUTE_FAIL", ["ExecutionAttempt"], "failure preserves principal"), ...launch.slice(3), ...refund]),
  manifest("time-weighted-rewards", "TIME_WEIGHTED", ["tranche aging", "newest tranche consumed first", "3x cap"], [...launch,
    stage("TRANCHE_SPLIT", ["Transfer", "TranchesChanged"], "seed aged tranche"), stage("TRANCHE_RETURN", ["Transfer", "TranchesChanged"], "create newest tranche after aging"), stage("TRANCHE_CONSUME", ["Transfer", "TranchesChanged"], "consume newest tranche first"),
    stage("REWARD_APPROVE", ["Approval"], "approve exact reward funding"), stage("REWARD_FUND", ["RewardFunded"], "fund exact reward amount"), stage("REWARD_CLAIM", ["RewardClaimed"], "age-weighted claim")], commonDependencies, ["bscUsdt"], ["RewardCompanionDeployed"], [{ event: "RewardCompanionDeployed", argument: "rewardVault", creation: true }]),
  manifest("threshold-buyback", "AUTO_BUYBACK", ["threshold", "maximum spend", "slippage", "burn"], [...launch, stage("BUYBACK_FUND", ["BuybackFunded"], "threshold funding"), stage("BUYBACK_FLOOR", ["ExecutionFloorCommitted"], "quote-bound execution floor"), stage("BUYBACK_EXECUTE", ["BuybackExecuted", "Burned"], "bounded burn")], commonDependencies, [], ["BuybackCompanionDeployed", "BuybackTaxInfrastructureDeployed"], [{ event: "BuybackCompanionDeployed", argument: "buybackVault", creation: true }, { event: "BuybackTaxInfrastructureDeployed", argument: "taxProcessor", creation: true }, { event: "BuybackTaxInfrastructureDeployed", argument: "holderRewardVault", creation: true }, { event: "BuybackTaxInfrastructureDeployed", argument: "liquidityAdapter", creation: true }]),
  manifest("scheduled-buyback", "TIMED_BUYBACK", ["interval", "early execution rejection", "burn"], [...launch, stage("BUYBACK_FUND", ["BuybackFunded"], "scheduled funding"), stage("BUYBACK_FLOOR", ["ExecutionFloorCommitted"], "quote-bound execution floor"), stage("BUYBACK_EXECUTE", ["BuybackExecuted", "Burned"], "interval-respecting burn")], commonDependencies, [], ["BuybackCompanionDeployed", "BuybackTaxInfrastructureDeployed"], [{ event: "BuybackCompanionDeployed", argument: "buybackVault", creation: true }, { event: "BuybackTaxInfrastructureDeployed", argument: "taxProcessor", creation: true }, { event: "BuybackTaxInfrastructureDeployed", argument: "holderRewardVault", creation: true }, { event: "BuybackTaxInfrastructureDeployed", argument: "liquidityAdapter", creation: true }]),
  manifest("native-lp-rewards", "LP_REWARDS", ["canonical LP weight", "minimum LP", "reward claim"], [...launch, stage("LP_SYNC", ["LpWeightSynced"], "canonical LP weight"), stage("REWARD_APPROVE", ["Approval"], "approve exact reward funding"), stage("REWARD_FUND", ["RewardFunded"], "reward funding"), stage("REWARD_CLAIM", ["RewardClaimed"], "LP reward claim")], [...commonDependencies, "canonicalLpToken"], ["bscUsdt"], ["RewardCompanionDeployed"], [{ event: "RewardCompanionDeployed", argument: "rewardVault", creation: true }]),
  manifest("holder-dead-rewards", "HOLDER_DEAD", ["holder share", "dead share", "excluded liquidity"], [...launch, stage("REWARD_APPROVE", ["Approval"], "approve exact reward funding"), stage("REWARD_FUND", ["HolderDeadFunded"], "holder/dead split"), stage("REWARD_CLAIM", ["RewardClaimed"], "holder claim")], commonDependencies, ["bscUsdt"], ["RewardCompanionDeployed"], [{ event: "RewardCompanionDeployed", argument: "rewardVault", creation: true }]),
  manifest("finance-exit-multiple", "FINANCE_EXIT", ["BNB position", "USDT position", "lifetime payout cap"], [...launch,
    stage("POSITION_OPEN_NATIVE", ["PositionOpened"], "open native position"), stage("POSITION_OPEN_TOKEN_APPROVE", ["Approval"], "approve exact token position"), stage("POSITION_OPEN_TOKEN", ["PositionOpened"], "open USDT position"),
    stage("POSITION_FUND_NATIVE", ["Funded"], "fund native exit"), stage("POSITION_FUND_TOKEN_APPROVE", ["Approval"], "approve exact token funding"), stage("POSITION_FUND_TOKEN", ["Funded"], "fund USDT exit"),
    stage("POSITION_CLAIM_NATIVE", ["PositionClaimed"], "native lifetime cap"), stage("POSITION_CLAIM_TOKEN", ["PositionClaimed"], "USDT lifetime cap"),
  ], commonDependencies, ["bscUsdt"], ["FinanceCompanionDeployed"], [{ event: "FinanceCompanionDeployed", argument: "financeVault", creation: true }]),
  manifest("wallet-limit-windows", "LAUNCH_LIMIT", ["non-decreasing limits", "window expiry", "exemptions"], [...launch,
    stage("LIMIT_ACTIVE_TRANSFER", ["Transfer"], "active wallet window"), stage("LIMIT_EXEMPT_TRANSFER", ["Transfer"], "exempt transfer"), stage("LIMIT_EXPIRED_TRANSFER", ["Transfer"], "expired window transfer"),
  ], commonDependencies, [], ["LaunchLimitCompanionDeployed"], [{ event: "LaunchLimitCompanionDeployed", argument: "limits", creation: true }]),
  manifest("external-token-burn", "EXTERNAL_BURN", ["route validation", "target compatibility", "target burn"], [...launch, stage("BUYBACK_FUND", ["BuybackFunded"], "external route funding"), stage("BUYBACK_FLOOR", ["ExecutionFloorCommitted"], "quote-bound execution floor"), stage("BUYBACK_EXECUTE", ["BuybackExecuted", "Burned"], "external token burn")], [...commonDependencies, "externalBurnTarget"]),
  manifest("whitelist-mint", "WHITELIST", ["Merkle proof", "append-only epoch", "public mint after deadline"], [
    stage("DEPLOY", ["ProjectDeployed"], "whitelist deployment"), stage("WHITELIST_EPOCH", ["EpochAppended"], "append-only root"),
    stage("WHITELIST_PROOF_MINT", ["MintPurchased"], "valid Merkle proof mint"), stage("WHITELIST_PUBLIC_MINT", ["MintPurchased", "Filled"], "public mint after deadline"),
    ...launch.slice(3),
  ], commonDependencies, [], ["WhitelistCompanionDeployed"], [{ event: "WhitelistCompanionDeployed", argument: "whitelist", creation: true }]),
  manifest("flap-joint-launch", "FLAP_JOINT", ["2-16 BNB goal", "adapter retry", "24h refund", "anti-sell protection"], [
    stage("DEPLOY", ["ProjectDeployed"], "0.005 BNB fee"),
    stage("MINT", ["MintPurchased"], "BNB shares"),
    stage("FLAP_FAIL", ["ExecutionAttempt"], "adapter failure preserves principal"),
    stage("FLAP_RETRY", ["ExecutionAttempt", "Launched"], "permissionless adapter retry"),
    stage("CLAIM", ["Claimed"], "claims enabled"),
    ...refund,
  ], ["flapProtocol", "flapPoolAsset"], [], ["FlapVaultDeployed"]),
] as const satisfies readonly CanonicalScenarioManifest[];

export const canonicalScenarioById = new Map(canonicalScenarioManifests.map((item) => [item.id, item]));

const launchFactoryArtifact = "LaunchFactory.sol/LaunchFactory";
const mintVaultArtifact = "MintVault.sol/MintVault";
const flapVaultArtifact = "FlapMintVault.sol/FlapMintVault";
const whitelistVaultArtifact = "WhitelistTemplateV1.sol/WhitelistMintVault";
const limitVaultArtifact = "LaunchLimitTemplateV1.sol/LaunchLimitMintVault";

const templateArtifacts: Record<TemplateId, string> = {
  STANDARD: "StandardTemplateV1.sol/StandardTemplateV1",
  TIME_WEIGHTED: "TimeWeightedTemplateV1.sol/TimeWeightedTemplateV1",
  LP_REWARDS: "LpRewardsTemplateV1.sol/LpRewardsTemplateV1",
  HOLDER_DEAD: "HolderDeadTemplateV1.sol/HolderDeadTemplateV1",
  AUTO_BUYBACK: "AutoBuybackTemplateV1.sol/AutoBuybackTemplateV1",
  TIMED_BUYBACK: "TimedBuybackTemplateV1.sol/TimedBuybackTemplateV1",
  EXTERNAL_BURN: "ExternalBurnTemplateV1.sol/ExternalBurnTemplateV1",
  FINANCE_EXIT: "FinanceExitTemplateV1.sol/FinanceExitTemplateV1",
  LAUNCH_LIMIT: "LaunchLimitTemplateV1.sol/LaunchLimitTemplateV1",
  WHITELIST: "WhitelistTemplateV1.sol/WhitelistTemplateV1",
  FLAP_JOINT: "FlapTemplateV1.sol/FlapTemplateV1",
};

const primaryArtifact = (templateId: TemplateId) => templateId === "FLAP_JOINT" ? flapVaultArtifact : templateId === "WHITELIST" ? whitelistVaultArtifact : templateId === "LAUNCH_LIMIT" ? limitVaultArtifact : mintVaultArtifact;
const companionArtifact = (templateId: TemplateId, stageName: string) => {
  if (stageName === "REWARD_APPROVE" || stageName.endsWith("_TOKEN_APPROVE")) return "LaunchToken.sol/LaunchToken";
  if (["REWARD_FUND", "REWARD_CLAIM", "LP_SYNC"].includes(stageName)) {
    if (templateId === "TIME_WEIGHTED") return "TimeWeightedRewardVault.sol/TimeWeightedRewardVault";
    if (templateId === "LP_REWARDS") return "LpRewardVault.sol/LpRewardVault";
    return "HolderDeadRewardVault.sol/HolderDeadRewardVault";
  }
  if (stageName.startsWith("TRANCHE_")) return "LaunchToken.sol/LaunchToken";
  if (["BUYBACK_FUND", "BUYBACK_FLOOR", "BUYBACK_EXECUTE"].includes(stageName)) return "BuybackVault.sol/BuybackVault";
  if (stageName.startsWith("POSITION_")) return "FinanceVault.sol/FinanceVault";
  if (stageName === "WHITELIST_EPOCH") return "WhitelistMint.sol/WhitelistMint";
  if (stageName.startsWith("LIMIT_")) return "LaunchToken.sol/LaunchToken";
  return primaryArtifact(templateId);
};

const functionNames: Record<string, string> = {
  MINT: "mint", FILL: "mint", EXECUTE_FAIL: "finalize", FINALIZE: "finalize", CLAIM: "claim",
  REFUND_MINT: "mint", REFUND_ENABLE: "enableRefunds", REFUND: "refund", FLAP_FAIL: "executeLaunch", FLAP_RETRY: "retryLaunch",
  REWARD_APPROVE: "approve", REWARD_FUND: "fundRewards", REWARD_CLAIM: "claimRewards", BUYBACK_FUND: "fundBuyback", BUYBACK_FLOOR: "commitExecutionFloor", BUYBACK_EXECUTE: "executeBuyback", LP_SYNC: "syncWeight",
  POSITION_OPEN_NATIVE: "openNative", POSITION_OPEN_TOKEN: "openToken", POSITION_FUND_NATIVE: "fundNative", POSITION_FUND_TOKEN: "fundToken",
  POSITION_OPEN_TOKEN_APPROVE: "approve", POSITION_FUND_TOKEN_APPROVE: "approve",
  POSITION_CLAIM_NATIVE: "claim", POSITION_CLAIM_TOKEN: "claim", LIMIT_ACTIVE_TRANSFER: "transfer", LIMIT_EXEMPT_TRANSFER: "transfer", LIMIT_EXPIRED_TRANSFER: "transfer",
  WHITELIST_EPOCH: "appendEpoch", WHITELIST_PROOF_MINT: "mintWithProof", WHITELIST_PUBLIC_MINT: "mint",
  TRANCHE_SPLIT: "transfer", TRANCHE_RETURN: "transfer", TRANCHE_CONSUME: "transfer",
};

const actionTarget = (stageName: string): CanonicalReferenceRole => {
  if (stageName === "DEPLOY" || stageName === "REFUND_DEPLOY") return "factory";
  if (stageName === "REWARD_APPROVE" || stageName.endsWith("_TOKEN_APPROVE")) return "bscUsdt";
  if (stageName === "REFUND" || stageName.startsWith("REFUND_")) return "refundVault";
  if (["REWARD_FUND", "REWARD_CLAIM", "LP_SYNC"].includes(stageName)) return "rewardVault";
  if (stageName.startsWith("TRANCHE_")) return "primaryToken";
  if (stageName.startsWith("BUYBACK_")) return "buybackVault";
  if (stageName.startsWith("POSITION_")) return "financeVault";
  if (stageName === "WHITELIST_EPOCH") return "whitelist";
  if (stageName.startsWith("LIMIT_")) return "primaryToken";
  return "primaryVault";
};

const actionWallet = (stageName: string): "A" | "B" | "C" => {
  if (["DEPLOY", "REFUND_DEPLOY", "REFUND_ENABLE", "REWARD_APPROVE", "REWARD_FUND", "BUYBACK_FUND", "BUYBACK_FLOOR", "POSITION_FUND_NATIVE", "POSITION_FUND_TOKEN_APPROVE", "POSITION_FUND_TOKEN", "WHITELIST_EPOCH"].includes(stageName)) return "A";
  if (stageName === "POSITION_OPEN_TOKEN_APPROVE") return "B";
  if (["MINT", "CLAIM", "REWARD_CLAIM", "LP_SYNC", "POSITION_OPEN_NATIVE", "POSITION_OPEN_TOKEN", "POSITION_CLAIM_NATIVE", "POSITION_CLAIM_TOKEN", "WHITELIST_PROOF_MINT"].includes(stageName)) return "B";
  if (stageName === "TRANCHE_SPLIT" || stageName === "TRANCHE_CONSUME") return "B";
  if (stageName === "TRANCHE_RETURN") return "C";
  return "C";
};

const eventPolicy = (templateId: TemplateId, stageName: string, name: string): { name: string; artifact: string; emitter: CanonicalReferenceRole } => {
  if (name === "ProjectDeployed") return { name, artifact: launchFactoryArtifact, emitter: "factory" };
  if (name === "Approval") return { name, artifact: "LaunchToken.sol/LaunchToken", emitter: "bscUsdt" };
  if (name.endsWith("CompanionDeployed") || name === "FlapVaultDeployed" || name === "BuybackTaxInfrastructureDeployed") return { name, artifact: templateArtifacts[templateId], emitter: "template" };
  if (name === "LiquidityAdded") return { name, artifact: "PancakeV2Adapter.sol/PancakeV2Adapter", emitter: "pancakeAdapter" };
  if (name === "TranchesChanged") return { name, artifact: "TimeWeightedRewardVault.sol/TimeWeightedRewardVault", emitter: "rewardVault" };
  if ((templateId === "LP_REWARDS" || templateId === "HOLDER_DEAD") && name === "RewardClaimed") return { name, artifact: "RewardVault.sol/RewardVault", emitter: "rewardAccounting" };
  if (templateId === "LP_REWARDS" && name === "RewardFunded") return { name, artifact: "RewardVault.sol/RewardVault", emitter: "rewardAccounting" };
  return { name, artifact: companionArtifact(templateId, stageName), emitter: actionTarget(stageName) };
};

const readPolicies = (scenarioId: string, templateId: TemplateId, stageName: string): CanonicalStagePolicy["reads"] => {
  const target: CanonicalReferenceRole = stageName === "DEPLOY" ? "primaryVault" : stageName === "REFUND_DEPLOY" ? "refundVault" : actionTarget(stageName);
  const artifact = (stageName === "DEPLOY" || stageName === "REFUND_DEPLOY") ? primaryArtifact(templateId) : companionArtifact(templateId, stageName);
  const definitions: Record<string, readonly [string, string][]> = {
    DEPLOY: [["state", "state"], ...(["LP_REWARDS", "HOLDER_DEAD"].includes(templateId) ? [["rewardAccounting", "rewardAccounting"]] as [string, string][] : [])], MINT: [["state", "state"], ["totalPaid", "totalPaid"], ["totalSharesSold", "totalSharesSold"]],
    FILL: [["state", "state"], ["totalPaid", "totalPaid"], ["totalSharesSold", "totalSharesSold"]],
    EXECUTE_FAIL: [["state", "state"], ["totalPaid", "totalPaid"], ["lastFailureAt", "lastFailureAt"], ["lastFailureHash", "lastFailureHash"]],
    FINALIZE: [["state", "state"], ["liquidityToken", "liquidityToken"], ["liquidityAmount", "liquidityAmount"]],
    CLAIM: [["state", "state"], ["totalClaimedShares", "totalClaimedShares"], ...(templateId === "FLAP_JOINT" ? [] : [["totalShares", "totalShares"], ["claimTokenAllocation", "claimTokenAllocation"]] satisfies [string, string][])],
    REFUND_DEPLOY: [["state", "state"], ["createdAt", "createdAt"]], REFUND_MINT: [["state", "state"], ["totalPaid", "totalPaid"], ["totalSharesSold", "totalSharesSold"]],
    REFUND_ENABLE: [["state", "state"], ["createdAt", "createdAt"], ["filledAt", "filledAt"]], REFUND: [["state", "state"], ["totalRefundedShares", "totalRefundedShares"]],
    FLAP_FAIL: [["state", "state"], ["totalPaid", "totalPaid"], ["lastFailureAt", "lastFailureAt"], ["lastFailureHash", "lastFailureHash"]],
    FLAP_RETRY: [["state", "state"], ["token", "token"], ["pair", "pair"], ["purchasedAmount", "purchasedAmount"], ["protectionDuration", "protectionDuration"], ["sellProtectedUntil", "sellProtectedUntil"]],
    REWARD_FUND: [["totalFunded", "totalFunded"], ["remainingAllowance", "allowance"]], REWARD_CLAIM: [["totalClaimed", "totalClaimed"]], LP_SYNC: [["totalWeight", "totalWeight"]],
    REWARD_APPROVE: [["allowance", "allowance"]], POSITION_OPEN_TOKEN_APPROVE: [["allowance", "allowance"]], POSITION_FUND_TOKEN_APPROVE: [["allowance", "allowance"]],
    BUYBACK_FUND: [["accountedFunds", "accountedFunds"]], BUYBACK_FLOOR: [["floorInputAmount", "floorInputAmount"], ["floorMinimumOutput", "floorMinimumOutput"], ["floorExpiry", "floorExpiry"]], BUYBACK_EXECUTE: [["accountedFunds", "accountedFunds"], ["threshold", "threshold"], ["maxSpend", "maxSpend"], ["maxSlippageBps", "maxSlippageBps"], ["floorMinimumOutput", "floorMinimumOutput"], ["interval", "interval"], ["nextExecutionAt", "nextExecutionAt"]],
    POSITION_OPEN_NATIVE: [["position", "positions"]], POSITION_OPEN_TOKEN: [["position", "positions"], ["remainingAllowance", "allowance"]], POSITION_FUND_NATIVE: [["remainingPayout", "remainingPayout"]], POSITION_FUND_TOKEN: [["remainingPayout", "remainingPayout"], ["remainingAllowance", "allowance"]],
    POSITION_CLAIM_NATIVE: [["position", "positions"]], POSITION_CLAIM_TOKEN: [["position", "positions"]],
    LIMIT_ACTIVE_TRANSFER: [["activeWindow", "window"], ["activatedAt", "activatedAt"]], LIMIT_EXEMPT_TRANSFER: [["activatedAt", "activatedAt"]], LIMIT_EXPIRED_TRANSFER: [["activatedAt", "activatedAt"]],
    WHITELIST_EPOCH: [["epochRoot", "rootAt"]], WHITELIST_PROOF_MINT: [["isPublic", "isPublic"], ["state", "state"]], WHITELIST_PUBLIC_MINT: [["isPublic", "isPublic"], ["state", "state"]],
    TRANCHE_SPLIT: [["trancheCount", "trancheCount"], ["tranche0", "trancheAt"], ["trackedBalance", "trackedBalanceOf"], ["weightedBalance", "weightedBalanceOf"]],
    TRANCHE_RETURN: [["trancheCount", "trancheCount"], ["tranche0", "trancheAt"], ["trackedBalance", "trackedBalanceOf"], ["weightedBalance", "weightedBalanceOf"]],
    TRANCHE_CONSUME: [["trancheCount", "trancheCount"], ["tranche0", "trancheAt"], ["trackedBalance", "trackedBalanceOf"], ["weightedBalance", "weightedBalanceOf"]],
  };
  return (definitions[stageName] ?? []).map(([name, functionName]) => {
    const args: readonly CanonicalPlanArgument[] = stageName === "REWARD_APPROVE" || (stageName === "REWARD_FUND" && name === "remainingAllowance")
      ? [{ ref: "walletA" }, { ref: canonicalReference(scenarioId, templateId, "rewardVault") }]
      : stageName === "POSITION_OPEN_TOKEN_APPROVE" || (stageName === "POSITION_OPEN_TOKEN" && name === "remainingAllowance") ? [{ ref: "walletB" }, { ref: canonicalReference(scenarioId, templateId, "financeVault") }]
      : stageName === "POSITION_FUND_TOKEN_APPROVE" || (stageName === "POSITION_FUND_TOKEN" && name === "remainingAllowance") ? [{ ref: "walletA" }, { ref: canonicalReference(scenarioId, templateId, "financeVault") }]
      : stageName.startsWith("TRANCHE_")
      ? name === "tranche0" ? [{ ref: "walletB" }, { uint: "0" }] : [{ ref: "walletB" }]
      : stageName === "LIMIT_ACTIVE_TRANSFER" && name === "activeWindow" ? [{ uint: "0" }]
      : stageName === "WHITELIST_EPOCH" && name === "epochRoot" ? [{ uint: "1" }]
      : stageName === "POSITION_OPEN_NATIVE" || stageName === "POSITION_FUND_NATIVE" || stageName === "POSITION_CLAIM_NATIVE" ? [{ uint: "0" }]
      : stageName === "POSITION_OPEN_TOKEN" || stageName === "POSITION_FUND_TOKEN" || stageName === "POSITION_CLAIM_TOKEN" ? [{ uint: "1" }]
      : [];
    if (stageName === "DEPLOY" && name === "rewardAccounting") return { name, functionName, artifact: companionArtifact(templateId, "REWARD_FUND"), target: "rewardVault" as const, args, capture: "rewardAccounting" as const };
    if (name === "remainingAllowance") return { name, functionName, artifact: "LaunchToken.sol/LaunchToken", target: "bscUsdt" as const, args };
    if (stageName.startsWith("LIMIT_")) return { name, functionName, artifact: "LaunchLimits.sol/LaunchLimits", target: "limits" as const, args };
    if (stageName.startsWith("TRANCHE_")) return { name, functionName, artifact: "TimeWeightedRewardVault.sol/TimeWeightedRewardVault", target: "rewardVault" as const, args };
    if ((stageName === "WHITELIST_PROOF_MINT" || stageName === "WHITELIST_PUBLIC_MINT") && name === "isPublic") return { name, functionName, artifact: "WhitelistMint.sol/WhitelistMint", target: "whitelist" as const, args };
    if (stageName === "FLAP_RETRY" && name === "sellProtectedUntil") return { name, functionName, artifact: "FlapMintVault.sol/IFlapToken", target: "launchedToken" as const, args };
    return { name, functionName, artifact, target, args };
  });
};

export function canonicalReference(scenarioId: string, templateId: TemplateId, role: CanonicalReferenceRole): string {
  const refs: Record<CanonicalReferenceRole, string> = {
    factory: "factory", template: `template.${templateId}`, pancakeAdapter: "pancakeAdapter", bscUsdt: "bscUsdt",
    primaryVault: `${scenarioId}.DEPLOY.ProjectDeployed.vault`, primaryToken: `${scenarioId}.DEPLOY.ProjectDeployed.token`, refundVault: `${scenarioId}.REFUND_DEPLOY.ProjectDeployed.vault`,
    launchedToken: `${scenarioId}.FLAP_RETRY.Launched.token`, launchedPair: `${scenarioId}.FLAP_RETRY.Launched.pair`,
    rewardVault: `${scenarioId}.DEPLOY.RewardCompanionDeployed.rewardVault`, rewardAccounting: `${scenarioId}.DEPLOY.rewardAccounting`, buybackVault: `${scenarioId}.DEPLOY.BuybackCompanionDeployed.buybackVault`,
    financeVault: `${scenarioId}.DEPLOY.FinanceCompanionDeployed.financeVault`, whitelist: `${scenarioId}.DEPLOY.WhitelistCompanionDeployed.whitelist`, limits: `${scenarioId}.DEPLOY.LaunchLimitCompanionDeployed.limits`,
  };
  return refs[role];
}

export function canonicalStagePolicy(scenarioId: string, stageName: string): CanonicalStagePolicy {
  const scenario = canonicalScenarioById.get(scenarioId);
  const stage = scenario?.stages.find(({ name }) => name === stageName);
  if (!scenario || !stage) throw new Error(`CHAIN97_CANONICAL_STAGE_UNKNOWN:${scenarioId}:${stageName}`);
  const kind = stageName === "DEPLOY" || stageName === "REFUND_DEPLOY" ? "factoryDeploy" : "call";
  const artifact = kind === "factoryDeploy" ? launchFactoryArtifact : companionArtifact(scenario.templateId, stageName);
  const revertProbes: CanonicalStagePolicy["revertProbes"] = ["threshold-buyback", "scheduled-buyback", "external-token-burn"].includes(scenarioId) && stageName === "DEPLOY"
    ? [{ name: "thresholdNotMet", artifact: "BuybackVault.sol/BuybackVault", functionName: "executeBuyback", target: "buybackVault", wallet: "C", errorArtifact: "BuybackVault.sol/BuybackVault", errorName: "ThresholdNotMet" }]
    : scenarioId === "scheduled-buyback" && stageName === "BUYBACK_EXECUTE"
    ? [{ name: "earlyExecution", artifact: "BuybackVault.sol/BuybackVault", functionName: "executeBuyback", target: "buybackVault", wallet: "C", errorArtifact: "BuybackVault.sol/BuybackVault", errorName: "ExecutionTooEarly" }]
    : scenarioId === "wallet-limit-windows" && stageName === "LIMIT_ACTIVE_TRANSFER"
      ? [{ name: "overLimit", artifact: "LaunchToken.sol/LaunchToken", functionName: "transfer", target: "primaryToken", wallet: "B", errorArtifact: "LaunchLimits.sol/LaunchLimits", errorName: "WalletLimitExceeded" }]
      : scenarioId === "whitelist-mint" && stageName === "WHITELIST_PROOF_MINT"
        ? [{ name: "proofRequired", artifact: whitelistVaultArtifact, functionName: "mint", target: "primaryVault", wallet: "C", errorArtifact: whitelistVaultArtifact, errorName: "WhitelistProofRequired" }]
        : [];
  return {
    kind, artifact, ...(kind === "call" ? { functionName: functionNames[stageName]! } : {}), target: actionTarget(stageName), wallet: actionWallet(stageName),
    events: stage.requiredEvents.map((name) => eventPolicy(scenario.templateId, stageName, name)), reads: readPolicies(scenarioId, scenario.templateId, stageName), revertProbes,
  };
}
