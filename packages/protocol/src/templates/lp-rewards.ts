import { z } from "zod";
import { bigintSchema, defineTemplate, nonzeroAddressSchema, standardLaunchAbi, standardLaunchSchema } from "./shared";

const schema = z.object({
  launch: standardLaunchSchema,
  rewards: z.object({ lpToken: nonzeroAddressSchema, minimumEligibleBalance: bigintSchema().pipe(z.bigint().min(1n)) }),
});

export const lpRewardsTemplate = defineTemplate({
  templateId: "LP_REWARDS",
  version: 1,
  label: "LP 持有者分红",
  schema,
  abiParameters: [standardLaunchAbi, { name: "rewards", type: "tuple", components: [
    { name: "lpToken", type: "address" },
    { name: "minimumEligibleBalance", type: "uint256" },
  ] }],
  toAbiValues: (config) => [config.launch, config.rewards],
  fromAbiValues: ([launch, rewards]) => ({ launch, rewards }),
});
