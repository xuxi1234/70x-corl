export const PLATFORM_FEE_WEI = 5_000_000_000_000_000n;

export * from "./abi/index";

export {
  CommonConfigSchema,
  decodeCommonConfig,
  encodeCommonConfig,
  hashCommonConfig,
  type CommonConfig,
} from "./config";

export {
  compareProjectConfig,
  decodeProjectConfig,
  encodeDeployment,
  templateIds,
  templateFields,
  templateOnchainIds,
  templateSchemas,
  type ConfigComparison,
  type DecodedProjectConfig,
  type DeploymentInput,
  type EncodedDeployment,
  type TemplateId,
  type TemplateField,
} from "./registry";
