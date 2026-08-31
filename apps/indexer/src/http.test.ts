import { describe, expect, it } from "vitest";
import { encodeAbiParameters, encodeEventTopics, encodeFunctionData, keccak256 } from "viem";

import { encodeDeployment, launchFactoryAbi, templateOnchainIds } from "@70x/protocol";
import { buildIndexedConfigResponse, parseDeploymentBlock } from "./http";

const releaseCommit = "3188a29ed010089df2ce9b99a2cb09837096c9be";
const creator = "0x1000000000000000000000000000000000000001";
const token = "0x2000000000000000000000000000000000000002";
const vault = "0x3000000000000000000000000000000000000003";
const recipient = "0x4000000000000000000000000000000000000004";
const factory = "0x5000000000000000000000000000000000000005";
const transactionHash = `0x${"ab".repeat(32)}` as const;
const blockHash = `0x${"cd".repeat(32)}` as const;

describe("Chain 97 HTTP index response", () => {
  it("accepts an exact historical deployment block beyond the 24-hour refund delay", () => {
    expect(parseDeploymentBlock("128000000", 128030000n)).toBe(128000000n);
    expect(() => parseDeploymentBlock(null, 128030000n)).toThrow("CHAIN97_INDEX_DEPLOYMENT_BLOCK_REQUIRED");
    expect(() => parseDeploymentBlock("128030001", 128030000n)).toThrow("CHAIN97_INDEX_DEPLOYMENT_BLOCK_INVALID");
  });

  it("binds a requested project to its real deployment event and factory calldata", () => {
    const commonConfig = {
      name: "70X acceptance",
      symbol: "70XA",
      supply: "1000000000",
      buyTaxBps: 0,
      sellTaxBps: 0,
      receiver: creator,
      rewardToken: "0x0000000000000000000000000000000000000000",
      rewardThreshold: "0",
      lpMode: 0,
      allocationBps: [0, 0, 0, 0] as [number, number, number, number],
      metadataHash: `0x${"11".repeat(32)}`,
    };
    const templateConfig = { totalShares: 2, pricePerShare: "100", claimTokenBps: 5000, minimumLiquidityOutput: "1" };
    const encoded = encodeDeployment({ templateId: "STANDARD", version: 1, commonConfig, templateConfig });
    const input = encodeFunctionData({
      abi: launchFactoryAbi,
      functionName: "deploy",
      args: [templateOnchainIds.STANDARD, 1, encoded.commonConfig, encoded.templateConfig],
    });
    const topics = encodeEventTopics({
      abi: launchFactoryAbi,
      eventName: "ProjectDeployed",
      args: { id: templateOnchainIds.STANDARD, version: 1, creator },
    });
    const data = encodeAbiParameters([
      { name: "token", type: "address" },
      { name: "vault", type: "address" },
      { name: "fee", type: "uint96" },
      { name: "recipient", type: "address" },
      { name: "commonConfigHash", type: "bytes32" },
    ], [token, vault, 5_000_000_000_000_000n, recipient, keccak256(encoded.commonConfig)]);

    const response = buildIndexedConfigResponse({
      releaseCommit,
      factory,
      project: vault,
      deploymentLog: { address: factory, data, topics: topics as unknown as [`0x${string}`, ...`0x${string}`[]], transactionHash, blockHash },
      transactionInput: input,
    });

    expect(response).toEqual({
      chainId: 97,
      releaseCommit,
      factory,
      project: vault,
      deploymentTransaction: transactionHash,
      deploymentBlockHash: blockHash,
      config: {
        templateId: "STANDARD",
        version: 1,
        commonConfig: { ...commonConfig, supply: "1000000000", rewardThreshold: "0" },
        templateConfig: { totalShares: 2, pricePerShare: "100", claimTokenBps: 5000, minimumLiquidityOutput: "1" },
      },
    });

    expect(() => buildIndexedConfigResponse({
      releaseCommit,
      factory,
      project: vault,
      deploymentLog: { address: creator, data, topics: topics as unknown as [`0x${string}`, ...`0x${string}`[]], transactionHash, blockHash },
      transactionInput: input,
    })).toThrow("CHAIN97_INDEX_FACTORY_EVENT_MISMATCH");
  });
});
