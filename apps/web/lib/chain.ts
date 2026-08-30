import { CommonConfigSchema, encodeCommonConfig, hashCommonConfig } from "@70x/protocol";
import { z } from "zod";

export const templateCatalog = [
  { id: "STANDARD", label: "标准 Mint 发射", kind: "mint" },
  { id: "TIME_WEIGHTED", label: "时间加权持币分红", kind: "rewards" },
  { id: "AUTO_BUYBACK", label: "阈值回购销毁", kind: "buyback" },
  { id: "TIMED_BUYBACK", label: "定时回购销毁", kind: "buyback" },
  { id: "LP_REWARDS", label: "原生 LP 分红", kind: "rewards" },
  { id: "HOLDER_DEAD", label: "持币与黑洞分红", kind: "rewards" },
  { id: "FINANCE_EXIT", label: "金融倍数出局", kind: "finance" },
  { id: "WALLET_LIMITS", label: "分时段持仓限制", kind: "limits" },
  { id: "EXTERNAL_BURN", label: "指定外币回购销毁", kind: "buyback" },
  { id: "WHITELIST", label: "白名单 Mint", kind: "mint" },
  { id: "FLAP", label: "Flap 联合发射", kind: "flap" },
] as const;

export type TemplateId = typeof templateCatalog[number]["id"];

const launchDraftSchema = CommonConfigSchema.safeExtend({
  templateId: z.string(),
  version: z.number().int().positive(),
});

export type LaunchDraft = z.input<typeof launchDraftSchema>;

export function buildLaunchReview(input: LaunchDraft) {
  const draft = launchDraftSchema.parse(input);
  if (!templateCatalog.some((template) => template.id === draft.templateId)) throw new Error("UNKNOWN_TEMPLATE");
  const { templateId, version, ...common } = draft;
  const commonConfig = encodeCommonConfig(common);
  return { templateId: templateId as TemplateId, version, commonConfig, configHash: hashCommonConfig(common), feeWei: 5_000_000_000_000_000n };
}

export function buildFactoryTransaction(input: LaunchDraft, templateConfig: `0x${string}` = "0x") {
  const review = buildLaunchReview(input);
  return { functionName: "deploy" as const, args: [review.templateId, review.version, review.commonConfig, templateConfig] as const, value: review.feeWei };
}
