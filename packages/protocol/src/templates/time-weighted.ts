import { z } from "zod";
import { defineTemplate, standardLaunchAbi, standardLaunchSchema } from "./shared";

const rewardsSchema = z.object({
  maxMultiplierBps: z.number().int().min(10_000).max(30_000),
  growthDuration: z.number().int().min(86_400).max(2_592_000),
});
const schema = z.object({ launch: standardLaunchSchema, rewards: rewardsSchema });

export const timeWeightedTemplate = defineTemplate({
  templateId: "TIME_WEIGHTED",
  version: 1,
  label: "持币时长加权分红",
  schema,
  abiParameters: [standardLaunchAbi, { name: "rewards", type: "tuple", components: [
    { name: "maxMultiplierBps", type: "uint16" },
    { name: "growthDuration", type: "uint32" },
  ] }],
  toAbiValues: (config) => [config.launch, config.rewards],
  fromAbiValues: ([launch, rewards]) => ({ launch, rewards }),
});
