import { buybackBaseAbi, externalBurnSchema } from "./buyback";
import { defineTemplate, standardLaunchAbi } from "./shared";

export const externalBurnTemplate = defineTemplate({
  templateId: "EXTERNAL_BURN", version: 1, label: "回购销毁外部币", schema: externalBurnSchema,
  abiParameters: [standardLaunchAbi, { name: "buyback", type: "tuple", components: [
    { name: "targetToken", type: "address" }, ...buybackBaseAbi, { name: "maxSlippageBps", type: "uint16" },
  ] }],
  toAbiValues: (config) => [config.launch, config.buyback],
  fromAbiValues: ([launch, buyback]) => ({ launch, buyback }),
});
