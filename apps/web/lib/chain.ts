import {
  CommonConfigSchema,
  PLATFORM_FEE_WEI,
  encodeDeployment,
  hashCommonConfig,
  launchFactoryAbi,
  templateIds,
  templateOnchainIds,
  templateSchemas,
  type TemplateId,
} from "@70x/protocol";
import { encodeFunctionData, type Address } from "viem";
import { z } from "zod";

const kindByTemplate: Record<TemplateId, "mint" | "rewards" | "buyback" | "finance" | "limits" | "flap"> = {
  STANDARD: "mint", TIME_WEIGHTED: "rewards", LP_REWARDS: "rewards", HOLDER_DEAD: "rewards",
  AUTO_BUYBACK: "buyback", TIMED_BUYBACK: "buyback", EXTERNAL_BURN: "buyback", FINANCE_EXIT: "finance",
  LAUNCH_LIMIT: "limits", WHITELIST: "mint", FLAP_JOINT: "flap",
};

export const templateCatalog = templateIds.map((id) => ({
  id,
  label: templateSchemas[id].label,
  kind: kindByTemplate[id],
}));

const launchDraftSchema = CommonConfigSchema.safeExtend({
  templateId: z.enum(templateIds),
  version: z.number().int().positive(),
  templateConfig: z.unknown(),
});

export type LaunchDraft = z.input<typeof launchDraftSchema>;

export function buildLaunchReview(input: LaunchDraft) {
  if (!templateIds.includes(input.templateId as TemplateId)) throw new Error("UNKNOWN_TEMPLATE");
  const draft = launchDraftSchema.parse(input);
  const { templateId, version, templateConfig, ...commonConfig } = draft;
  const encoded = encodeDeployment({ templateId, version, commonConfig, templateConfig });
  return {
    templateId,
    onchainTemplateId: templateOnchainIds[templateId],
    version,
    commonConfig: encoded.commonConfig,
    templateConfig: encoded.templateConfig,
    configHash: hashCommonConfig(commonConfig),
    feeWei: PLATFORM_FEE_WEI,
  };
}

export function buildFactoryTransaction(input: LaunchDraft, factory?: Address) {
  const review = buildLaunchReview(input);
  const args = [review.onchainTemplateId, review.version, review.commonConfig, review.templateConfig] as const;
  return {
    chainId: 97,
    ...(factory ? { to: factory } : {}),
    data: encodeFunctionData({ abi: launchFactoryAbi, functionName: "deploy", args }),
    functionName: "deploy" as const,
    args,
    value: review.feeWei,
  };
}
