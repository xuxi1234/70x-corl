import { decodeFunctionData } from "viem";
import { describe, expect, it, vi } from "vitest";

import { loadFoundryArtifact } from "./artifacts";
import { canonicalRpcRequest, encodeFactoryDeployment, resolvePlanValue, resolveVerificationCreationProvenance, selectPrimaryFactoryDeployment } from "./engine";

const project = "0x1000000000000000000000000000000000000001";
const zeroHash = `0x${"0".repeat(64)}`;

describe("Chain 97 execution engine primitives", () => {
  it("falls back to a number-pinned call while proving the block hash stayed canonical", async () => {
    const hash = `0x${"a".repeat(64)}` as const;
    const unsupported = Object.assign(new Error("invalid argument 1: cannot unmarshal object into Go value of type string"), { code: -32602 });\n    const request = vi.fn().mockRejectedValueOnce(unsupported).mockResolvedValueOnce("0x1234");
    const getBlock = vi.fn().mockResolvedValue({ number: 123n, hash });
    const result = await canonicalRpcRequest({ request, getBlock } as never, "eth_call", { to: project, data: "0x" }, hash);
    expect(result).toBe("0x1234");
    expect(request).toHaveBeenNthCalledWith(2, { method: "eth_call", params: [{ to: project, data: "0x" }, "0x7b"] });
    expect(getBlock).toHaveBeenCalledTimes(3);
  });

  it("resolves references, uints, and bounded chain-relative deadlines without evaluating strings", () => {
    const value = resolvePlanValue([
      { ref: "project" },
      { uint: "2000000000000000000" },
      { nowPlusSeconds: 600 },
      { label: "literal" },
    ], new Map([["project", project]]), 1_000n);

    expect(value).toEqual([project, 2_000_000_000_000_000_000n, 1_600n, { label: "literal" }]);
    expect(() => resolvePlanValue({ ref: "missing" }, new Map(), 1_000n)).toThrow("CHAIN97_PLAN_REFERENCE_MISSING:missing");
  });

  it("encodes factory deployment calldata from the shared protocol schema and decodes it losslessly", async () => {
    const factory = await loadFoundryArtifact("LaunchFactory.sol/LaunchFactory", process.cwd());
    const form = {
      templateId: "STANDARD" as const,
      version: 1,
      commonConfig: {
        name: "Acceptance",
        symbol: "ACC",
        supply: "1000000",
        buyTaxBps: 0,
        sellTaxBps: 0,
        receiver: project,
        rewardToken: project,
        rewardThreshold: "0",
        lpMode: 0,
        allocationBps: [0, 0, 0, 0],
        metadataHash: zeroHash,
      },
      templateConfig: { totalShares: 2, pricePerShare: "100", claimTokenBps: 5000, minimumLiquidityOutput: "1" },
    };

    const encoded = encodeFactoryDeployment(form, factory.abi);
    const decoded = decodeFunctionData({ abi: factory.abi, data: encoded.data });

    expect(decoded.functionName).toBe("deploy");
    expect(decoded.args).toEqual([encoded.templateOnchainId, 1, encoded.commonConfig, encoded.templateConfig]);
    expect(encoded.normalizedConfig).toMatchObject({ templateId: "STANDARD", version: 1, commonConfig: { supply: 1_000_000n } });
  });

  it("selects the canonical primary deployment instead of the later refund deployment", () => {
    const primary = { marker: "primary" };
    const refund = { marker: "refund" };
    const compiled = { primaryFactoryDeploymentKeys: new Map([["flap-joint-launch", "flap-joint-launch:DEPLOY"]]) };
    const deployments = new Map([
      ["flap-joint-launch:DEPLOY", primary],
      ["flap-joint-launch:REFUND_DEPLOY", refund],
    ]);

    expect(selectPrimaryFactoryDeployment(compiled, "flap-joint-launch", deployments)).toBe(primary);
    expect(() => selectPrimaryFactoryDeployment(compiled, "missing", deployments)).toThrow("CHAIN97_PRIMARY_FACTORY_DEPLOYMENT_MISSING:missing");
  });

  it("binds a Factory child to the compiler-proven exact required-event argument", () => {
    const otherChild = "0x2000000000000000000000000000000000000002";
    const transaction = {
      receipt: { contractAddress: null },
      decodedEvents: [
        { name: "ProjectDeployed", address: "0x3000000000000000000000000000000000000003", logIndex: 0, args: { token: project, vault: "0x4000000000000000000000000000000000000004" } },
        { name: "CompanionDeployed", address: "0x3000000000000000000000000000000000000003", logIndex: 1, args: { companion: otherChild } },
      ],
    };
    const proof = { executionKey: "standard-mint:DEPLOY", creationKind: "event" as const, event: "ProjectDeployed", argument: "token", sameTransactionConstructorRefs: [] };

    expect(resolveVerificationCreationProvenance({ targetName: "token", address: project, proof, transaction, transactionTo: "0x3000000000000000000000000000000000000003" })).toEqual({ creationKind: "event", creationLocator: "ProjectDeployed.token" });
    expect(() => resolveVerificationCreationProvenance({ targetName: "token", address: otherChild, proof, transaction, transactionTo: "0x3000000000000000000000000000000000000003" })).toThrow("CHAIN97_FACTORY_CREATION_EVENT_MISMATCH:token");
  });
});
