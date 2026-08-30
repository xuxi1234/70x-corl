import { z } from "zod";
import { defineTemplate, standardLaunchAbi, standardLaunchSchema } from "./shared";

const schema = z.object({
  launch: standardLaunchSchema,
  rewards: z.object({ holderBps: z.number().int().min(0).max(10_000), deadBps: z.number().int().min(0).max(10_000) }),
}).superRefine(({ rewards }, context) => {
  if (rewards.holderBps + rewards.deadBps !== 10_000) context.addIssue({ code: "custom", message: "Reward split must total 10000 bps", path: ["rewards"] });
});

export const holderDeadTemplate = defineTemplate({
  templateId: "HOLDER_DEAD",
  version: 1,
  label: "持币/黑洞分红",
  schema,
  abiParameters: [standardLaunchAbi, { name: "rewards", type: "tuple", components: [
    { name: "holderBps", type: "uint16" },
    { name: "deadBps", type: "uint16" },
  ] }],
  toAbiValues: (config) => [config.launch, config.rewards],
  fromAbiValues: ([launch, rewards]) => ({ launch, rewards }),
});
