import { z } from "zod";
import { defineTemplate, standardLaunchAbi, standardLaunchSchema } from "./shared";

const schema = z.object({
  launch: standardLaunchSchema,
  durationsMinutes: z.array(z.number().int().min(1).max(1_440)).min(1).max(5),
  maximumWalletBps: z.array(z.number().int().min(1).max(10_000)).min(1).max(5),
}).superRefine((config, context) => {
  if (config.durationsMinutes.length !== config.maximumWalletBps.length) context.addIssue({ code: "custom", message: "Limit arrays must have equal length" });
  for (let index = 1; index < config.maximumWalletBps.length; index += 1) {
    if (config.maximumWalletBps[index]! < config.maximumWalletBps[index - 1]!) context.addIssue({ code: "custom", message: "Wallet limits must be non-decreasing", path: ["maximumWalletBps", index] });
  }
});
const configAbi = { name: "config", type: "tuple", components: [
  standardLaunchAbi,
  { name: "durationsMinutes", type: "uint32[]" },
  { name: "maximumWalletBps", type: "uint16[]" },
] } as const;

export const launchLimitTemplate = defineTemplate({
  templateId: "LAUNCH_LIMIT", version: 1, label: "分时段持仓限制", schema,
  abiParameters: [configAbi],
  toAbiValues: (config) => [config],
  fromAbiValues: ([config]) => config,
});
