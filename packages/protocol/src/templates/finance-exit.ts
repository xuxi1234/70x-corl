import { z } from "zod";
import { defineTemplate, nonzeroAddressSchema, standardLaunchAbi, standardLaunchSchema } from "./shared";

const schema = z.object({ launch: standardLaunchSchema, supportedToken: nonzeroAddressSchema });
const configAbi = { name: "config", type: "tuple", components: [standardLaunchAbi, { name: "supportedToken", type: "address" }] } as const;

export const financeExitTemplate = defineTemplate({
  templateId: "FINANCE_EXIT", version: 1, label: "理财退本", schema,
  abiParameters: [configAbi],
  toAbiValues: (config) => [config],
  fromAbiValues: ([config]) => config,
});
