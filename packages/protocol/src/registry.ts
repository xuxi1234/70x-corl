import { decodeAbiParameters, encodeAbiParameters, keccak256, stringToHex, toBytes, type AbiParameter, type Hex } from "viem";
import { CommonConfigSchema, decodeCommonConfig, encodeCommonConfig, type CommonConfig } from "./config";
import { autoBuybackTemplate } from "./templates/auto-buyback";
import { externalBurnTemplate } from "./templates/external-burn";
import { financeExitTemplate } from "./templates/finance-exit";
import { flapJointTemplate } from "./templates/flap-joint";
import { holderDeadTemplate } from "./templates/holder-dead";
import { launchLimitTemplate } from "./templates/launch-limit";
import { lpRewardsTemplate } from "./templates/lp-rewards";
import type { TemplateDefinition } from "./templates/shared";
import { standardTemplate } from "./templates/standard";
import { timedBuybackTemplate } from "./templates/timed-buyback";
import { timeWeightedTemplate } from "./templates/time-weighted";
import { whitelistTemplate } from "./templates/whitelist";

export const templateIds = [
  "STANDARD",
  "TIME_WEIGHTED",
  "LP_REWARDS",
  "HOLDER_DEAD",
  "AUTO_BUYBACK",
  "TIMED_BUYBACK",
  "EXTERNAL_BURN",
  "FINANCE_EXIT",
  "LAUNCH_LIMIT",
  "WHITELIST",
  "FLAP_JOINT",
] as const;

export type TemplateId = typeof templateIds[number];

export type TemplateField = { path: string; label: string; input: "text" | "number" };
const launchFields: readonly TemplateField[] = [
  { path: "launch.totalShares", label: "Mint 份数", input: "number" },
  { path: "launch.pricePerShare", label: "每份价格（wei）", input: "number" },
  { path: "launch.claimTokenBps", label: "认领代币占比（BP）", input: "number" },
  { path: "launch.minimumLiquidityOutput", label: "最小流动性输出", input: "number" },
];
const standardFields = launchFields.map((field) => ({ ...field, path: field.path.replace(/^launch\./, "") }));

export const templateFields: Record<TemplateId, readonly TemplateField[]> = {
  STANDARD: standardFields,
  TIME_WEIGHTED: [...launchFields, { path: "rewards.maxMultiplierBps", label: "最高权重倍数（BP）", input: "number" }, { path: "rewards.growthDuration", label: "权重增长秒数", input: "number" }],
  LP_REWARDS: [...launchFields, { path: "rewards.lpToken", label: "LP 代币地址", input: "text" }, { path: "rewards.minimumEligibleBalance", label: "最低有效 LP 余额", input: "number" }],
  HOLDER_DEAD: [...launchFields, { path: "rewards.holderBps", label: "持币者分红（BP）", input: "number" }, { path: "rewards.deadBps", label: "黑洞分红（BP）", input: "number" }],
  AUTO_BUYBACK: [...launchFields, { path: "buyback.threshold", label: "回购触发阈值", input: "number" }, { path: "buyback.maxSpend", label: "单次最大回购", input: "number" }, { path: "buyback.maxSlippageBps", label: "最大滑点（BP）", input: "number" }],
  TIMED_BUYBACK: [...launchFields, { path: "buyback.threshold", label: "回购触发阈值", input: "number" }, { path: "buyback.maxSpend", label: "单次最大回购", input: "number" }, { path: "buyback.interval", label: "回购间隔秒数", input: "number" }, { path: "buyback.maxSlippageBps", label: "最大滑点（BP）", input: "number" }],
  EXTERNAL_BURN: [...launchFields, { path: "buyback.targetToken", label: "外部销毁代币", input: "text" }, { path: "buyback.threshold", label: "回购触发阈值", input: "number" }, { path: "buyback.maxSpend", label: "单次最大回购", input: "number" }, { path: "buyback.maxSlippageBps", label: "最大滑点（BP）", input: "number" }],
  FINANCE_EXIT: [...launchFields, { path: "supportedToken", label: "理财支持代币", input: "text" }],
  LAUNCH_LIMIT: [...launchFields, { path: "durationsMinutes", label: "限制窗口分钟数组", input: "text" }, { path: "maximumWalletBps", label: "最大持仓 BP 数组", input: "text" }],
  WHITELIST: [...launchFields, { path: "initialRoot", label: "初始白名单根", input: "text" }, { path: "whitelistDeadline", label: "白名单截止时间", input: "number" }],
  FLAP_JOINT: [
    { path: "goal", label: "BNB 目标（wei）", input: "number" }, { path: "totalShares", label: "联合 Mint 份数", input: "number" },
    { path: "initialRoot", label: "可选白名单根", input: "text" }, { path: "whitelistDeadline", label: "白名单截止时间", input: "number" },
    { path: "protectionDuration", label: "防卖保护秒数", input: "number" },
  ],
};

const literalId = (id: string) => stringToHex(id, { size: 32 });
const hashedId = (id: string) => keccak256(toBytes(id));
export const templateOnchainIds: Record<TemplateId, Hex> = {
  STANDARD: literalId("STANDARD"), TIME_WEIGHTED: literalId("TIME_WEIGHTED"), LP_REWARDS: literalId("LP_REWARDS"),
  HOLDER_DEAD: literalId("HOLDER_DEAD"), AUTO_BUYBACK: literalId("AUTO_BUYBACK"), TIMED_BUYBACK: literalId("TIMED_BUYBACK"),
  EXTERNAL_BURN: literalId("EXTERNAL_BURN"), FINANCE_EXIT: hashedId("FINANCE_EXIT"), LAUNCH_LIMIT: hashedId("LAUNCH_LIMIT"),
  WHITELIST: hashedId("WHITELIST"), FLAP_JOINT: hashedId("FLAP_JOINT"),
};

function erase<T>(definition: TemplateDefinition<T>): TemplateDefinition<unknown> {
  return definition as unknown as TemplateDefinition<unknown>;
}

export const templateSchemas: Record<TemplateId, TemplateDefinition<unknown>> = {
  STANDARD: erase(standardTemplate),
  TIME_WEIGHTED: erase(timeWeightedTemplate),
  LP_REWARDS: erase(lpRewardsTemplate),
  HOLDER_DEAD: erase(holderDeadTemplate),
  AUTO_BUYBACK: erase(autoBuybackTemplate),
  TIMED_BUYBACK: erase(timedBuybackTemplate),
  EXTERNAL_BURN: erase(externalBurnTemplate),
  FINANCE_EXIT: erase(financeExitTemplate),
  LAUNCH_LIMIT: erase(launchLimitTemplate),
  WHITELIST: erase(whitelistTemplate),
  FLAP_JOINT: erase(flapJointTemplate),
};

function assertNever(value: never): never {
  throw new Error(`UNKNOWN_TEMPLATE:${String(value)}`);
}

function definitionFor(templateId: TemplateId): TemplateDefinition<unknown> {
  switch (templateId) {
    case "STANDARD": return templateSchemas.STANDARD;
    case "TIME_WEIGHTED": return templateSchemas.TIME_WEIGHTED;
    case "LP_REWARDS": return templateSchemas.LP_REWARDS;
    case "HOLDER_DEAD": return templateSchemas.HOLDER_DEAD;
    case "AUTO_BUYBACK": return templateSchemas.AUTO_BUYBACK;
    case "TIMED_BUYBACK": return templateSchemas.TIMED_BUYBACK;
    case "EXTERNAL_BURN": return templateSchemas.EXTERNAL_BURN;
    case "FINANCE_EXIT": return templateSchemas.FINANCE_EXIT;
    case "LAUNCH_LIMIT": return templateSchemas.LAUNCH_LIMIT;
    case "WHITELIST": return templateSchemas.WHITELIST;
    case "FLAP_JOINT": return templateSchemas.FLAP_JOINT;
    default: return assertNever(templateId);
  }
}

function versionedDefinition(templateId: TemplateId, version: number): TemplateDefinition<unknown> {
  const definition = definitionFor(templateId);
  if (version !== definition.version) throw new Error(`UNKNOWN_TEMPLATE_VERSION:${templateId}:${version}`);
  return definition;
}

export interface DeploymentInput {
  templateId: TemplateId;
  version: number;
  commonConfig: unknown;
  templateConfig: unknown;
}

export interface EncodedDeployment {
  commonConfig: Hex;
  templateConfig: Hex;
}

export function encodeDeployment(input: DeploymentInput): EncodedDeployment {
  const definition = versionedDefinition(input.templateId, input.version);
  const templateConfig = definition.schema.parse(input.templateConfig);
  const values = definition.toAbiValues(templateConfig);
  return {
    commonConfig: encodeCommonConfig(input.commonConfig),
    templateConfig: encodeAbiParameters(
      definition.abiParameters as readonly AbiParameter[],
      values as never,
    ),
  };
}

export interface DecodedProjectConfig {
  templateId: TemplateId;
  version: 1;
  commonConfig: CommonConfig;
  templateConfig: unknown;
}

export function decodeProjectConfig(
  templateId: TemplateId,
  version: number,
  encodedCommon: Hex,
  encodedTemplate: Hex,
): DecodedProjectConfig {
  const definition = versionedDefinition(templateId, version);
  const values = decodeAbiParameters(definition.abiParameters as readonly AbiParameter[], encodedTemplate);
  return {
    templateId,
    version: 1,
    commonConfig: decodeCommonConfig(encodedCommon),
    templateConfig: definition.schema.parse(definition.fromAbiValues(values)),
  };
}

export interface ConfigComparison {
  matches: boolean;
  differences: string[];
}

function comparable(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(comparable);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, comparable(item)]));
  }
  return typeof value === "string" && value.startsWith("0x") ? value.toLowerCase() : value;
}

function collectDifferences(expected: unknown, actual: unknown, path: string, differences: string[]): void {
  if (Array.isArray(expected) && Array.isArray(actual)) {
    if (expected.length !== actual.length) differences.push(path);
    const length = Math.min(expected.length, actual.length);
    for (let index = 0; index < length; index += 1) collectDifferences(expected[index], actual[index], `${path}.${index}`, differences);
    return;
  }
  if (expected && actual && typeof expected === "object" && typeof actual === "object") {
    const keys = new Set([...Object.keys(expected), ...Object.keys(actual)]);
    for (const key of keys) collectDifferences(
      (expected as Record<string, unknown>)[key],
      (actual as Record<string, unknown>)[key],
      path ? `${path}.${key}` : key,
      differences,
    );
    return;
  }
  if (expected !== actual) differences.push(path);
}

export function compareProjectConfig(
  expected: { commonConfig: unknown; templateConfig: unknown },
  actual: DecodedProjectConfig,
): ConfigComparison {
  const definition = versionedDefinition(actual.templateId, actual.version);
  const normalizedExpected = comparable({
    commonConfig: CommonConfigSchema.parse(expected.commonConfig),
    templateConfig: definition.schema.parse(expected.templateConfig),
  });
  const normalizedActual = comparable({ commonConfig: actual.commonConfig, templateConfig: actual.templateConfig });
  const differences: string[] = [];
  collectDifferences(normalizedExpected, normalizedActual, "", differences);
  return { matches: differences.length === 0, differences };
}
