import { buybackBaseAbi, timedBuybackSchema } from "./buyback";
import { defineTemplate, standardLaunchAbi } from "./shared";

export const timedBuybackTemplate = defineTemplate({
  templateId: "TIMED_BUYBACK", version: 1, label: "定时回购本币", schema: timedBuybackSchema,
  abiParameters: [standardLaunchAbi, { name: "buyback", type: "tuple", components: [
    ...buybackBaseAbi, { name: "interval", type: "uint32" }, { name: "maxSlippageBps", type: "uint16" },
  ] }],
  toAbiValues: (config) => [config.launch, config.buyback],
  fromAbiValues: ([launch, buyback]) => ({ launch, buyback }),
});
