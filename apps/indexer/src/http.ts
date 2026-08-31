import {
  decodeEventLog,
  decodeFunctionData,
  isAddressEqual,
  keccak256,
  type Address,
  type Hex,
} from "viem";

import {
  decodeProjectConfig,
  launchFactoryAbi,
  templateIds,
  templateOnchainIds,
  type TemplateId,
} from "@70x/protocol";

type DeploymentLog = {
  address: Address;
  data: Hex;
  topics: [Hex, ...Hex[]];
  transactionHash: Hex;
  blockHash: Hex;
};

export function parseDeploymentBlock(raw: string | null, latest: bigint): bigint {
  if (raw === null) throw new Error("CHAIN97_INDEX_DEPLOYMENT_BLOCK_REQUIRED");
  if (!/^(0|[1-9][0-9]*)$/.test(raw)) throw new Error("CHAIN97_INDEX_DEPLOYMENT_BLOCK_INVALID");
  const block = BigInt(raw);
  if (block > latest) throw new Error("CHAIN97_INDEX_DEPLOYMENT_BLOCK_INVALID");
  return block;
}

const jsonSafe = (value: unknown): unknown => {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, jsonSafe(item)]));
  }
  return value;
};

const templateIdFor = (onchainId: Hex): TemplateId => {
  const found = templateIds.find((templateId) => templateOnchainIds[templateId].toLowerCase() === onchainId.toLowerCase());
  if (!found) throw new Error("CHAIN97_INDEX_TEMPLATE_UNKNOWN");
  return found;
};

export function buildIndexedConfigResponse(input: {
  releaseCommit: string;
  factory: Address;
  project: Address;
  deploymentLog: DeploymentLog;
  transactionInput: Hex;
}) {
  if (!isAddressEqual(input.deploymentLog.address, input.factory)) throw new Error("CHAIN97_INDEX_FACTORY_EVENT_MISMATCH");
  const decodedEvent = decodeEventLog({
    abi: launchFactoryAbi,
    eventName: "ProjectDeployed",
    data: input.deploymentLog.data,
    topics: input.deploymentLog.topics,
    strict: true,
  });
  const args = decodedEvent.args;
  if (!isAddressEqual(args.token, input.project) && !isAddressEqual(args.vault, input.project)) {
    throw new Error("CHAIN97_INDEX_PROJECT_EVENT_MISMATCH");
  }

  const decodedTransaction = decodeFunctionData({ abi: launchFactoryAbi, data: input.transactionInput });
  if (decodedTransaction.functionName !== "deploy" || !decodedTransaction.args) {
    throw new Error("CHAIN97_INDEX_DEPLOYMENT_INPUT_INVALID");
  }
  const [onchainId, version, commonConfig, templateConfig] = decodedTransaction.args;
  if (
    onchainId.toLowerCase() !== args.id.toLowerCase()
    || Number(version) !== Number(args.version)
    || keccak256(commonConfig).toLowerCase() !== args.commonConfigHash.toLowerCase()
  ) throw new Error("CHAIN97_INDEX_DEPLOYMENT_BINDING_INVALID");

  const templateId = templateIdFor(onchainId);
  const config = decodeProjectConfig(templateId, Number(version), commonConfig, templateConfig);
  return {
    chainId: 97,
    releaseCommit: input.releaseCommit,
    factory: input.factory,
    project: input.project,
    deploymentTransaction: input.deploymentLog.transactionHash,
    deploymentBlockHash: input.deploymentLog.blockHash,
    config: jsonSafe(config),
  };
}
