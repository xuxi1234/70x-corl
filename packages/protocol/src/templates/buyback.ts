import { z } from "zod";
import { bigintSchema, nonzeroAddressSchema, standardLaunchSchema } from "./shared";

export const buybackBaseSchema = z.object({
  threshold: bigintSchema().pipe(z.bigint().min(1n)),
  maxSpend: bigintSchema().pipe(z.bigint().min(1n)),
  maxSlippageBps: z.number().int().min(0).max(9_999),
});

export const autoBuybackSchema = z.object({ launch: standardLaunchSchema, buyback: buybackBaseSchema });
export const timedBuybackSchema = z.object({
  launch: standardLaunchSchema,
  buyback: buybackBaseSchema.extend({ interval: z.number().int().min(300).max(2_592_000) }),
});
export const externalBurnSchema = z.object({
  launch: standardLaunchSchema,
  buyback: buybackBaseSchema.extend({ targetToken: nonzeroAddressSchema }),
});

export const buybackBaseAbi = [
  { name: "threshold", type: "uint256" },
  { name: "maxSpend", type: "uint256" },
] as const;
