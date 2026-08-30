import { z } from "zod";
import { bigintSchema, defineTemplate, MAX_UINT64, nonzeroBytes32Schema, standardLaunchAbi, standardLaunchSchema } from "./shared";

const schema = z.object({
  launch: standardLaunchSchema,
  initialRoot: nonzeroBytes32Schema,
  whitelistDeadline: bigintSchema(MAX_UINT64).pipe(z.bigint().min(1n)),
});
const configAbi = { name: "config", type: "tuple", components: [
  standardLaunchAbi, { name: "initialRoot", type: "bytes32" }, { name: "whitelistDeadline", type: "uint64" },
] } as const;

export const whitelistTemplate = defineTemplate({
  templateId: "WHITELIST", version: 1, label: "白名单 Mint", schema,
  abiParameters: [configAbi],
  toAbiValues: (config) => [config],
  fromAbiValues: ([config]) => config,
});
