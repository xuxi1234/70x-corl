import { autoBuybackSchema, buybackBaseAbi } from "./buyback";
import { defineTemplate, standardLaunchAbi } from "./shared";

export const autoBuybackTemplate = defineTemplate({
  templateId: "AUTO_BUYBACK", version: 1, label: "自动回购本币", schema: autoBuybackSchema,
  abiParameters: [standardLaunchAbi, { name: "buyback", type: "tuple", components: [
    ...buybackBaseAbi, { name: "maxSlippageBps", type: "uint16" },
  ] }],
  toAbiValues: (config) => [config.launch, config.buyback],
  fromAbiValues: ([launch, buyback]) => ({ launch, buyback }),
});
