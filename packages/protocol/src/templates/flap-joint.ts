import { z } from "zod";
import { bigintSchema, bytes32Schema, defineTemplate, MAX_UINT64, uint32Schema } from "./shared";

const approvedProtection = new Set([0n, 300n, 600n, 1_800n, 3_600n, 86_400n]);
const schema = z.object({
  goal: bigintSchema().pipe(z.bigint().min(2_000_000_000_000_000_000n).max(16_000_000_000_000_000_000n)),
  totalShares: uint32Schema.min(1),
  initialRoot: bytes32Schema,
  whitelistDeadline: bigintSchema(MAX_UINT64),
  protectionDuration: bigintSchema(MAX_UINT64).refine((value) => approvedProtection.has(value), "Unsupported protection duration"),
}).superRefine((config, context) => {
  if (config.goal % BigInt(config.totalShares) !== 0n) context.addIssue({ code: "custom", message: "Goal must divide exactly by shares", path: ["totalShares"] });
  const rootIsZero = /^0x0{64}$/i.test(config.initialRoot);
  if (!rootIsZero && config.whitelistDeadline === 0n) context.addIssue({ code: "custom", message: "Whitelist deadline required", path: ["whitelistDeadline"] });
});
const configAbi = { name: "config", type: "tuple", components: [
  { name: "goal", type: "uint256" }, { name: "totalShares", type: "uint32" },
  { name: "initialRoot", type: "bytes32" }, { name: "whitelistDeadline", type: "uint64" },
  { name: "protectionDuration", type: "uint64" },
] } as const;

export const flapJointTemplate = defineTemplate({
  templateId: "FLAP_JOINT", version: 1, label: "Flap 联合发射", schema,
  abiParameters: [configAbi],
  toAbiValues: (config) => [config],
  fromAbiValues: ([config]) => config,
});
