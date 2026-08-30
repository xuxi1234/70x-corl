import { mkdtemp, mkdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { encodeFunctionResult } from "viem";
import { describe, expect, it, vi } from "vitest";

import { canonicalScenarioById } from "../scenario-manifest";
import { assertCanonicalLifecycle, authorizeChain97Broadcast, redactChain97Error, resolvePlanFile, type Chain97Plan, type Chain97StepInput } from "./executor";
import { assertAssetPreflight, assertCanonicalBlock, calculateRemainingAssetFunding, preflightAssets } from "./engine";
import { createCheckpoint, parseCheckpoint } from "./checkpoint";
import { compileChain97Plan } from "./compiler";
import { loadFoundryArtifact, type FoundryArtifact } from "./artifacts";

const hash = (digit: string) => `0x${digit.repeat(64)}` as const;
const address = (digit: string) => `0x${digit.repeat(40)}` as const;
const assetReadAbi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "balance", type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], outputs: [{ name: "remaining", type: "uint256" }] },
] as const;

const factoryArtifact: FoundryArtifact = {
  artifactId: "LaunchFactory.sol/LaunchFactory", contractName: "LaunchFactory", sourceName: "src/core/LaunchFactory.sol",
  abi: [
    { type: "constructor", stateMutability: "nonpayable", inputs: [] },
    { type: "function", name: "deploy", stateMutability: "nonpayable", inputs: [{ name: "id", type: "bytes32" }, { name: "version", type: "uint32" }, { name: "commonConfig", type: "bytes" }, { name: "templateConfig", type: "bytes" }], outputs: [{ name: "token", type: "address" }, { name: "vault", type: "address" }] },
    { type: "event", name: "ProjectDeployed", inputs: [{ name: "token", type: "address", indexed: true }, { name: "vault", type: "address", indexed: true }], anonymous: false },
  ],
  bytecode: "0x6000", deployedBytecode: "0x6001", compilerVersion: "0.8.28+commit.7893614a",
  metadata: { compiler: { version: "0.8.28+commit.7893614a" }, language: "Solidity", settings: { compilationTarget: { "src/core/LaunchFactory.sol": "LaunchFactory" } }, sources: { "src/core/LaunchFactory.sol": {} } },
  metadataJson: "{}", standardJsonInput: { language: "Solidity", sources: { "src/core/LaunchFactory.sol": { content: "contract LaunchFactory {}" } }, settings: {} },
};

const flapAdapterArtifact: FoundryArtifact = {
  ...factoryArtifact,
  artifactId: "FlapAdapterV1.sol/FlapAdapterV1", contractName: "FlapAdapterV1", sourceName: "src/adapters/FlapAdapterV1.sol",
  abi: [{ type: "constructor", stateMutability: "nonpayable", inputs: [{ name: "protocol_", type: "address" }, { name: "allowedAssets", type: "address[]" }] }],
};

const financeArtifact: FoundryArtifact = {
  ...factoryArtifact,
  artifactId: "FinanceVault.sol/FinanceVault", contractName: "FinanceVault", sourceName: "src/vaults/FinanceVault.sol",
  abi: [
    { type: "constructor", stateMutability: "nonpayable", inputs: [{ name: "supportedToken_", type: "address" }] },
    { type: "function", name: "fundToken", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  ],
};
const erc20Artifact: FoundryArtifact = {
  ...factoryArtifact,
  artifactId: "LaunchToken.sol/LaunchToken", contractName: "LaunchToken", sourceName: "src/tokens/LaunchToken.sol",
  abi: [
    { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ name: "success", type: "bool" }] },
    { type: "function", name: "allowance", stateMutability: "view", inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], outputs: [{ name: "remaining", type: "uint256" }] },
    { type: "event", name: "Approval", inputs: [{ name: "owner", type: "address", indexed: true }, { name: "spender", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }], anonymous: false },
  ],
};

const addressConsumerArtifact: FoundryArtifact = {
  ...factoryArtifact,
  artifactId: "AddressConsumer.sol/AddressConsumer", contractName: "AddressConsumer", sourceName: "src/AddressConsumer.sol",
  abi: [{ type: "constructor", stateMutability: "nonpayable", inputs: [{ name: "recipient", type: "address" }] }],
};

const decorativeRouterArtifact: FoundryArtifact = {
  ...factoryArtifact,
  artifactId: "Decorative.sol/Decorative", contractName: "Decorative", sourceName: "src/Decorative.sol",
  abi: [{ type: "constructor", stateMutability: "nonpayable", inputs: [{ name: "router", type: "address" }] }],
};

const namespacedFactoryPlan = (wrongScope: boolean): Chain97Plan => ({
  schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
  dependencies: [], assetRequirements: [],
  bootstrap: [{ id: "DEPLOY", assertion: "factory", kind: "deploy", wallet: "A", artifact: factoryArtifact.artifactId, constructorArgs: [], captureAddress: "factory", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] }],
  verificationTargets: wrongScope ? [] : [{ name: "factory", address: { ref: "factory" }, artifact: factoryArtifact.artifactId, constructorArgs: [], creationTransaction: "DEPLOY" }],
  scenarios: [{
    id: "synthetic-scenario",
    form: {
      templateId: "STANDARD", version: 1,
      commonConfig: { name: "Synthetic", symbol: "SYN", supply: "1000", buyTaxBps: 0, sellTaxBps: 0, receiver: { ref: "walletA" }, rewardToken: { localAddress: "ZERO" }, rewardThreshold: "0", lpMode: 0, allocationBps: [0, 0, 0, 0], metadataHash: hash("8") },
      templateConfig: { totalShares: 2, pricePerShare: "100", claimTokenBps: 5000, minimumLiquidityOutput: "1" },
    },
    indexProjectRef: "synthetic-scenario.DEPLOY.ProjectDeployed.vault",
    steps: [{ id: "DEPLOY", assertion: "project", kind: "factoryDeploy", wallet: "A", artifact: factoryArtifact.artifactId, target: { ref: "factory" }, valueWei: "0", gasLimit: "100000", requiredEvents: [{ artifact: factoryArtifact.artifactId, event: "ProjectDeployed", address: { ref: "factory" } }], captures: [{ event: "ProjectDeployed", argument: "vault", ref: "synthetic-scenario.DEPLOY.ProjectDeployed.vault", creation: true }], reads: [] }],
    verificationTargets: [
      ...(wrongScope ? [{ name: "factory-from-wrong-scope", address: { ref: "factory" }, artifact: factoryArtifact.artifactId, constructorArgs: [], creationTransaction: "DEPLOY" }] : []),
      { name: "vault", address: { ref: "synthetic-scenario.DEPLOY.ProjectDeployed.vault" }, artifact: factoryArtifact.artifactId, constructorArgs: [], creationTransaction: "DEPLOY" },
    ],
  }],
} as unknown as Chain97Plan);

async function canonicalFactoryCreationFixture(scenarioIds: readonly string[] = ["standard-mint"]) {
  const tokenArtifact = await loadFoundryArtifact("LaunchToken.sol/LaunchToken", process.cwd());
  const vaultArtifact = await loadFoundryArtifact("MintVault.sol/MintVault", process.cwd());
  const manifest = canonicalScenarioById.get("standard-mint")!;
  const scenario = (id: string): Chain97Plan["scenarios"][number] => {
    const tokenRef = `${id}.DEPLOY.ProjectDeployed.token`;
    const vaultRef = `${id}.DEPLOY.ProjectDeployed.vault`;
    return {
      id,
      form: {
        templateId: "STANDARD", version: 1,
        commonConfig: { name: "Canonical", symbol: "CAN", supply: "1000", buyTaxBps: 0, sellTaxBps: 0, receiver: { ref: "walletA" }, rewardToken: { localAddress: "ZERO" }, rewardThreshold: "0", lpMode: 0, allocationBps: [0, 0, 0, 0], metadataHash: hash("8") },
        templateConfig: { totalShares: 2, pricePerShare: "100", claimTokenBps: 5000, minimumLiquidityOutput: "1" },
      },
      indexProjectRef: vaultRef,
      steps: [{
        id: "DEPLOY", assertion: "canonical non-Flap child creation", kind: "factoryDeploy", wallet: "A", artifact: factoryArtifact.artifactId,
        target: { ref: "factory" }, valueWei: "0", gasLimit: "100000", requiredEvents: [{ artifact: factoryArtifact.artifactId, event: "ProjectDeployed", address: { ref: "factory" } }],
        captures: manifest.deploymentCaptures.map((capture) => ({ ...capture, ref: `${id}.DEPLOY.${capture.event}.${capture.argument}` })), reads: [],
      }],
      verificationTargets: [
        { name: `${id}-token`, address: { ref: tokenRef }, artifact: tokenArtifact.artifactId, constructorArgs: ["Canonical", "CAN", { uint: "1000" }, { ref: vaultRef }], creationTransaction: "DEPLOY" },
        { name: `${id}-vault`, address: { ref: vaultRef }, artifact: vaultArtifact.artifactId, constructorArgs: [{ ref: "walletA" }, { ref: "walletB" }, "Canonical", "CAN", { uint: "500" }, { uint: "500" }, { uint: "1" }, { uint: "2" }, { uint: "100" }], creationTransaction: "DEPLOY" },
      ],
    } as Chain97Plan["scenarios"][number];
  };
  const plan = {
    schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
    dependencies: [], assetRequirements: [],
    bootstrap: [{ id: "DEPLOY", assertion: "factory", kind: "deploy", wallet: "A", artifact: factoryArtifact.artifactId, constructorArgs: [], captureAddress: "factory", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] }],
    verificationTargets: [{ name: "factory", address: { ref: "factory" }, artifact: factoryArtifact.artifactId, constructorArgs: [], creationTransaction: "DEPLOY" }],
    scenarios: scenarioIds.map(scenario),
  } as Chain97Plan;
  return {
    plan,
    artifacts: new Map([[factoryArtifact.artifactId, factoryArtifact], [tokenArtifact.artifactId, tokenArtifact], [vaultArtifact.artifactId, vaultArtifact]]),
  };
}

function completedAssetCheckpointFixture(remainingAllowance: bigint, approvalArgs: Record<string, unknown> = {}, currentAllowance = remainingAllowance) {
  const amount = "1000000000000000000";
  const blockHash = hash("a");
  const asset = address("7");
  const spender = address("8");
  const owner = address("1");
  const plan = {
    schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
    dependencies: [], scenarios: [], verificationTargets: [],
    assetRequirements: [{ asset: { ref: "bscUsdt" }, wallet: "A", spender: { ref: "financeVault" }, minimumBalance: amount, minimumAllowance: amount, fundingExecutionKeys: ["bootstrap:FUND"], approvalExecutionKey: "bootstrap:APPROVE" }],
    bootstrap: [
      { id: "APPROVE", assertion: "approval", kind: "call", wallet: "A", artifact: erc20Artifact.artifactId, target: { ref: "bscUsdt" }, functionName: "approve", args: [{ ref: "financeVault" }, { uint: amount }], valueWei: "0", gasLimit: "100000", requiredEvents: [{ artifact: erc20Artifact.artifactId, event: "Approval", address: { ref: "bscUsdt" } }], captures: [], reads: [{ name: "allowance", target: { ref: "bscUsdt" }, artifact: erc20Artifact.artifactId, functionName: "allowance", args: [{ ref: "walletA" }, { ref: "financeVault" }] }] },
      { id: "FUND", assertion: "fund", kind: "call", wallet: "A", artifact: financeArtifact.artifactId, target: { ref: "financeVault" }, functionName: "fundToken", args: [{ uint: amount }], valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [{ name: "remainingAllowance", target: { ref: "bscUsdt" }, artifact: erc20Artifact.artifactId, functionName: "allowance", args: [{ ref: "walletA" }, { ref: "financeVault" }] }] },
    ],
  } as unknown as Chain97Plan;
  const receipt = { status: 1 as const, blockNumber: 100n, blockHash, transactionIndex: 0, gasUsed: 1n, effectiveGasPrice: 1n, from: owner, to: asset, contractAddress: null };
  const snapshot = (stage: string, values: Record<string, unknown>) => ({
    scope: "bootstrap" as const, stage, blockNumber: 100n, blockHash, primaryProvider: "publicnode" as const, secondaryProvider: "bnbchain" as const, primary: values, secondary: values,
  });
  const historical = new Map([
    ["bootstrap:APPROVE", {
      nonce: 0,
      transaction: { scope: "bootstrap" as const, stage: "APPROVE", assertion: "approval", resumed: true, hash: hash("b"), receipt, requiredEvents: ["Approval"], decodedEvents: [{ name: "Approval", address: asset, logIndex: 0, args: { owner, spender, amount, ...approvalArgs } }] },
      snapshot: snapshot("APPROVE", { allowance: amount }),
    }],
    ["bootstrap:FUND", {
      nonce: 1,
      transaction: { scope: "bootstrap" as const, stage: "FUND", assertion: "fund", resumed: true, hash: hash("c"), receipt: { ...receipt, to: spender }, requiredEvents: [], decodedEvents: [] },
      snapshot: snapshot("FUND", { remainingAllowance: remainingAllowance.toString() }),
    }],
  ]);
  const client = () => ({
    request: vi.fn()
      .mockResolvedValueOnce(encodeFunctionResult({ abi: assetReadAbi, functionName: "balanceOf", result: 0n }))
      .mockResolvedValueOnce(encodeFunctionResult({ abi: assetReadAbi, functionName: "allowance", result: currentAllowance })),
    getBlock: vi.fn().mockResolvedValue({ hash: blockHash }),
  });
  return {
    plan,
    references: new Map<string, unknown>([["bscUsdt", asset], ["financeVault", spender]]),
    completed: new Set(["bootstrap:APPROVE", "bootstrap:FUND"]),
    accounts: { A: { address: owner }, B: { address: address("2") }, C: { address: address("3") } },
    rpc: { primary: client(), secondary: client(), primaryProvider: "publicnode", secondaryProvider: "bnbchain" },
    canonicalBlock: { blockNumber: 100n, blockHash },
    historical,
  };
}

const flapSteps = [
  ["DEPLOY", ["ProjectDeployed"], "0.005 BNB fee"],
  ["MINT", ["MintPurchased"], "BNB shares"],
  ["FLAP_FAIL", ["ExecutionAttempt"], "adapter failure preserves principal"],
  ["FLAP_RETRY", ["ExecutionAttempt", "Launched"], "permissionless adapter retry"],
  ["CLAIM", ["Claimed"], "claims enabled"],
  ["REFUND_DEPLOY", ["ProjectDeployed"], "independent refund vault"],
  ["REFUND_MINT", ["MintPurchased"], "refundable principal"],
  ["REFUND_ENABLE", ["RefundsEnabled"], "24-hour on-chain delay reached"],
  ["REFUND", ["Refunded"], "exact principal refund"],
] as const;

const scenario = {
  id: "flap-joint-launch",
  form: { templateId: "FLAP_JOINT", version: 1, commonConfig: {}, templateConfig: {} },
  indexProjectRef: "flap-joint-launch.DEPLOY.ProjectDeployed.vault",
  steps: flapSteps.map(([id, events, assertion]) => ({
    id,
    kind: id === "DEPLOY" || id === "REFUND_DEPLOY" ? "factoryDeploy" : "call",
    assertion,
    requiredEvents: events.map((event) => ({ artifact: "LaunchFactory.sol/LaunchFactory", event })),
  })),
} as unknown as Chain97Plan["scenarios"][number];

describe("Chain 97 pre-broadcast security compiler", () => {
  it.each([
    ["missing stage", { ...scenario, steps: scenario.steps.slice(0, -1) }],
    ["wrong order", { ...scenario, steps: [scenario.steps[1]!, scenario.steps[0]!, ...scenario.steps.slice(2)] }],
    ["wrong template", { ...scenario, form: { ...scenario.form, templateId: "STANDARD" } }],
    ["wrong event", { ...scenario, steps: scenario.steps.map((step, index) => index === 1 ? { ...step, requiredEvents: [] } : step) }],
    ["missing assertion", { ...scenario, steps: scenario.steps.map((step, index) => index === 1 ? { ...step, assertion: "" } : step) }],
    ["second factory deployment", { ...scenario, steps: scenario.steps.map((step, index) => index === 2 ? { ...step, kind: "factoryDeploy" } : step) }],
  ])("rejects %s before a mocked sender is constructed", async (_name, exploit) => {
    const senderFactory = vi.fn();
    await expect(authorizeChain97Broadcast({
      compile: () => assertCanonicalLifecycle(exploit as never),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow(/CHAIN97_/);
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("rejects a scenario verification target cross-linked to a same-named bootstrap step", async () => {
    const senderFactory = vi.fn();
    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: namespacedFactoryPlan(true), selectedScenarioIds: ["synthetic-scenario"], artifacts: new Map([[factoryArtifact.artifactId, factoryArtifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_CREATION_PROVENANCE_MISMATCH:factory-from-wrong-scope");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("records namespaced provenance and the canonical primary Factory deployment", () => {
    const compiled = compileChain97Plan({ plan: namespacedFactoryPlan(false), selectedScenarioIds: ["synthetic-scenario"], artifacts: new Map([[factoryArtifact.artifactId, factoryArtifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } });
    expect((compiled.provenance.get("factory") as unknown as { executionKey: string }).executionKey).toBe("bootstrap:DEPLOY");
    expect((compiled.provenance.get("synthetic-scenario.DEPLOY.ProjectDeployed.vault") as unknown as { executionKey: string }).executionKey).toBe("synthetic-scenario:DEPLOY");
    expect((compiled as unknown as { primaryFactoryDeploymentKeys: Map<string, string> }).primaryFactoryDeploymentKeys.get("synthetic-scenario")).toBe("synthetic-scenario:DEPLOY");
  });

  it("compiles the canonical non-Flap token and vault as one required-event creation group", async () => {
    const { plan, artifacts } = await canonicalFactoryCreationFixture();
    const vaultRef = "standard-mint.DEPLOY.ProjectDeployed.vault";
    const compiled = compileChain97Plan({ plan, selectedScenarioIds: ["standard-mint"], artifacts, walletAddresses: { A: address("1"), B: address("2"), C: address("3") } });
    const proofs = (compiled as unknown as { verificationProofs: Map<string, { executionKey: string; creationKind: string; event?: string; argument?: string; sameTransactionConstructorRefs: string[] }> }).verificationProofs;

    expect(proofs.get("standard-mint-token")).toEqual({
      executionKey: "standard-mint:DEPLOY", creationKind: "event", event: "ProjectDeployed", argument: "token", sameTransactionConstructorRefs: [vaultRef],
    });
    expect(proofs.get("standard-mint-vault")).toMatchObject({ executionKey: "standard-mint:DEPLOY", creationKind: "event", event: "ProjectDeployed", argument: "vault" });
  });

  it("rejects a same-scope creation constructor cross-linked to a different transaction before sender construction", async () => {
    const { plan, artifacts } = await canonicalFactoryCreationFixture();
    const scenario = plan.scenarios[0]!;
    const deploy = scenario.steps[0]!;
    const laterToken = "standard-mint.DEPLOY_LATER.ProjectDeployed.token";
    const laterVault = "standard-mint.DEPLOY_LATER.ProjectDeployed.vault";
    const laterStep = {
      ...deploy,
      id: "DEPLOY_LATER",
      captures: deploy.captures.map((capture) => ({ ...capture, ref: capture.argument === "token" ? laterToken : laterVault })),
    };
    const [tokenTarget, vaultTarget] = scenario.verificationTargets;
    const exploit = {
      ...plan,
      scenarios: [{
        ...scenario,
        steps: [deploy, laterStep],
        verificationTargets: [
          { ...tokenTarget!, constructorArgs: ["Canonical", "CAN", { uint: "1000" }, { ref: laterVault }] },
          vaultTarget!,
          { ...tokenTarget!, name: "later-token", address: { ref: laterToken }, constructorArgs: ["Canonical", "CAN", { uint: "1000" }, { ref: laterVault }], creationTransaction: "DEPLOY_LATER" },
          { ...vaultTarget!, name: "later-vault", address: { ref: laterVault }, creationTransaction: "DEPLOY_LATER" },
        ],
      }],
    } as Chain97Plan;
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: exploit, selectedScenarioIds: ["standard-mint"], artifacts, walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow(`CHAIN97_CREATION_GROUP_MISMATCH:standard-mint:standard-mint-token.verificationConstructor.3:${laterVault}`);
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("rejects a same-transaction event address not marked as a creation proof before sender construction", async () => {
    const { plan, artifacts } = await canonicalFactoryCreationFixture();
    const scenario = plan.scenarios[0]!;
    const deploy = scenario.steps[0]!;
    const vaultRef = "standard-mint.DEPLOY.ProjectDeployed.vault";
    const exploit = {
      ...plan,
      scenarios: [{
        ...scenario,
        steps: [{ ...deploy, captures: deploy.captures.map((capture) => capture.argument === "vault" ? { ...capture, creation: false } : capture) }],
        verificationTargets: [scenario.verificationTargets[0]!],
      }],
    } as Chain97Plan;
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: exploit, selectedScenarioIds: ["standard-mint"], artifacts, walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow(`CHAIN97_CREATION_GROUP_PROOF_INVALID:standard-mint:standard-mint-token.verificationConstructor.3:${vaultRef}`);
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("rejects a verification constructor creation reference from another scenario scope before sender construction", async () => {
    const { plan, artifacts } = await canonicalFactoryCreationFixture(["scope-one", "scope-two"]);
    const first = plan.scenarios[0]!;
    const secondVault = "scope-two.DEPLOY.ProjectDeployed.vault";
    const exploit = {
      ...plan,
      scenarios: [{
        ...first,
        verificationTargets: first.verificationTargets.map((target) => target.name.endsWith("-token")
          ? { ...target, constructorArgs: ["Canonical", "CAN", { uint: "1000" }, { ref: secondVault }] }
          : target),
      }, plan.scenarios[1]!],
    } as Chain97Plan;
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: exploit, selectedScenarioIds: ["scope-one", "scope-two"], artifacts, walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow(`CHAIN97_REFERENCE_SCOPE_VIOLATION:scope-one:scope-one-token.verificationConstructor.3:${secondVault}`);
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("rejects a later scenario consuming an earlier scenario capture before sender construction", async () => {
    const exploit = namespacedFactoryPlan(false);
    const first = exploit.scenarios[0]!;
    const laterVault = "later-scenario.DEPLOY.ProjectDeployed.vault";
    const later = {
      ...first,
      id: "later-scenario",
      form: {
        ...first.form,
        commonConfig: { ...(first.form.commonConfig as Record<string, unknown>), receiver: { ref: first.indexProjectRef } },
      },
      indexProjectRef: laterVault,
      steps: first.steps.map((step) => ({
        ...step,
        captures: step.captures.map((capture) => ({ ...capture, ref: laterVault })),
      })),
      verificationTargets: [{
        ...first.verificationTargets[0]!, name: "later-vault", address: { ref: laterVault },
      }],
    };
    const plan = { ...exploit, scenarios: [first, later] } as Chain97Plan;
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan, selectedScenarioIds: [first.id, later.id], artifacts: new Map([[factoryArtifact.artifactId, factoryArtifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_REFERENCE_SCOPE_VIOLATION:later-scenario.form.commonConfig.receiver:synthetic-scenario.DEPLOY.ProjectDeployed.vault");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("rejects verification constructor references created after the target before sender construction", async () => {
    const exploit = {
      schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
      dependencies: [], assetRequirements: [], scenarios: [],
      bootstrap: [
        { id: "CREATE_EARLY", assertion: "early", kind: "deploy", wallet: "A", artifact: addressConsumerArtifact.artifactId, constructorArgs: [{ ref: "walletA" }], captureAddress: "early", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] },
        { id: "CREATE_LATER", assertion: "later", kind: "deploy", wallet: "A", artifact: factoryArtifact.artifactId, constructorArgs: [], captureAddress: "later", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] },
      ],
      verificationTargets: [
        { name: "early", address: { ref: "early" }, artifact: addressConsumerArtifact.artifactId, constructorArgs: [{ ref: "later" }], creationTransaction: "CREATE_EARLY" },
        { name: "later", address: { ref: "later" }, artifact: factoryArtifact.artifactId, constructorArgs: [], creationTransaction: "CREATE_LATER" },
      ],
    } as unknown as Chain97Plan;
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: exploit, selectedScenarioIds: [], artifacts: new Map([[addressConsumerArtifact.artifactId, addressConsumerArtifact], [factoryArtifact.artifactId, factoryArtifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_REFERENCE_ORDER_VIOLATION:bootstrap:early.verificationConstructor.0:later");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("rejects a direct verification constructor that differs from the compiled creation", async () => {
    const exploit = {
      schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
      dependencies: [], assetRequirements: [], scenarios: [],
      bootstrap: [{ id: "CREATE", assertion: "create", kind: "deploy", wallet: "A", artifact: addressConsumerArtifact.artifactId, constructorArgs: [{ ref: "walletA" }], captureAddress: "consumer", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] }],
      verificationTargets: [{ name: "consumer", address: { ref: "consumer" }, artifact: addressConsumerArtifact.artifactId, constructorArgs: [{ ref: "walletB" }], creationTransaction: "CREATE" }],
    } as unknown as Chain97Plan;
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: exploit, selectedScenarioIds: [], artifacts: new Map([[addressConsumerArtifact.artifactId, addressConsumerArtifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_DIRECT_CREATION_PLAN_MISMATCH:consumer");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("rejects swapped dependency roles and local constants in external dependency slots", async () => {
    const makePlan = (constructorArgs: Chain97Plan["bootstrap"][number] extends infer _ ? unknown[] : never, dependencies = [{ name: "flapProtocol", address: address("5"), codeHash: hash("5") }, { name: "flapPoolAsset", address: address("6"), codeHash: hash("6") }]) => ({
      schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
      dependencies,
      assetRequirements: [], scenarios: [],
      bootstrap: [{ id: "DEPLOY_ADAPTER", assertion: "adapter", kind: "deploy", wallet: "A", artifact: flapAdapterArtifact.artifactId, constructorArgs, captureAddress: "adapter", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] }],
      verificationTargets: [{ name: "adapter", address: { ref: "adapter" }, artifact: flapAdapterArtifact.artifactId, constructorArgs, creationTransaction: "DEPLOY_ADAPTER" }],
    } as unknown as Chain97Plan);
    const compile = (constructorArgs: unknown[], dependencies?: { name: string; address: string; codeHash: string }[]) => compileChain97Plan({ plan: makePlan(constructorArgs as never, dependencies), selectedScenarioIds: [], artifacts: new Map([[flapAdapterArtifact.artifactId, flapAdapterArtifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } });

    expect(() => compile([{ ref: "flapPoolAsset" }, [{ ref: "flapProtocol" }]])).toThrow("CHAIN97_DEPENDENCY_ROLE_MISMATCH");
    expect(() => compile([{ localAddress: "ZERO" }, [{ ref: "flapPoolAsset" }]])).toThrow("CHAIN97_LOCAL_ADDRESS_ROLE_FORBIDDEN");
    expect(() => compile([{ ref: "flapProtocol" }, []], [{ name: "flapProtocol", address: address("5"), codeHash: hash("5") }])).not.toThrow();
    expect(() => compile([{ ref: "flapProtocol" }, [{ ref: "flapPoolAsset" }]])).toThrow("CHAIN97_FLAP_ALLOWED_ASSETS_UNSUPPORTED");
  });

  it("requires dependency provenance in a designated role slot", async () => {
    const exploit = {
      schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
      dependencies: [{ name: "flapPoolAsset", address: address("6"), codeHash: hash("6") }], assetRequirements: [], scenarios: [],
      bootstrap: [
        { id: "DEPLOY_FAKE", assertion: "fake", kind: "deploy", wallet: "A", artifact: factoryArtifact.artifactId, constructorArgs: [], captureAddress: "fakeProtocol", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] },
        { id: "DEPLOY_ADAPTER", assertion: "adapter", kind: "deploy", wallet: "A", artifact: flapAdapterArtifact.artifactId, constructorArgs: [{ ref: "fakeProtocol" }, [{ ref: "flapPoolAsset" }]], captureAddress: "adapter", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] },
      ],
      verificationTargets: [
        { name: "fake", address: { ref: "fakeProtocol" }, artifact: factoryArtifact.artifactId, constructorArgs: [], creationTransaction: "DEPLOY_FAKE" },
        { name: "adapter", address: { ref: "adapter" }, artifact: flapAdapterArtifact.artifactId, constructorArgs: [{ ref: "fakeProtocol" }, [{ ref: "flapPoolAsset" }]], creationTransaction: "DEPLOY_ADAPTER" },
      ],
    } as unknown as Chain97Plan;
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: exploit, selectedScenarioIds: [], artifacts: new Map([[factoryArtifact.artifactId, factoryArtifact], [flapAdapterArtifact.artifactId, flapAdapterArtifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_DEPENDENCY_PROVENANCE_INVALID:bootstrap:DEPLOY_ADAPTER.constructor.protocol_:flapProtocol:deploy");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("does not count a decorative same-named ABI field as canonical dependency use", async () => {
    const exploit = {
      schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
      dependencies: [{ name: "pancakeRouter", address: address("5"), codeHash: hash("5") }], assetRequirements: [], scenarios: [],
      bootstrap: [{ id: "DECORATIVE", assertion: "decorative", kind: "deploy", wallet: "A", artifact: decorativeRouterArtifact.artifactId, constructorArgs: [{ ref: "pancakeRouter" }], captureAddress: "decorative", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] }],
      verificationTargets: [{ name: "decorative", address: { ref: "decorative" }, artifact: decorativeRouterArtifact.artifactId, constructorArgs: [{ ref: "pancakeRouter" }], creationTransaction: "DECORATIVE" }],
    } as unknown as Chain97Plan;
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: exploit, selectedScenarioIds: [], artifacts: new Map([[decorativeRouterArtifact.artifactId, decorativeRouterArtifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_DEPENDENCY_ROLE_FORBIDDEN:bootstrap:DECORATIVE.constructor.router:pancakeRouter");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("binds an ERC20 prerequisite to the exact funding call, wallet, spender, and amount", () => {
    const amount = "1000000000000000000";
    const makePlan = (minimumBalance: string, spender = "financeVault") => ({
      schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
      dependencies: [{ name: "bscUsdt", address: address("7"), codeHash: hash("7") }], scenarios: [],
      bootstrap: [
        { id: "DEPLOY_FINANCE", assertion: "finance", kind: "deploy", wallet: "A", artifact: financeArtifact.artifactId, constructorArgs: [{ ref: "bscUsdt" }], captureAddress: "financeVault", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] },
        { id: "APPROVE", assertion: "approval", kind: "call", wallet: "B", artifact: erc20Artifact.artifactId, target: { ref: "bscUsdt" }, functionName: "approve", args: [{ ref: "financeVault" }, { uint: amount }], valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] },
        { id: "FUND", assertion: "fund", kind: "call", wallet: "B", artifact: financeArtifact.artifactId, target: { ref: "financeVault" }, functionName: "fundToken", args: [{ uint: amount }], valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] },
      ],
      verificationTargets: [{ name: "financeVault", address: { ref: "financeVault" }, artifact: financeArtifact.artifactId, constructorArgs: [{ ref: "bscUsdt" }], creationTransaction: "DEPLOY_FINANCE" }],
      assetRequirements: [{ asset: { ref: "bscUsdt" }, wallet: "B", spender: { ref: spender }, minimumBalance, minimumAllowance: minimumBalance, fundingExecutionKeys: ["bootstrap:FUND"], approvalExecutionKey: "bootstrap:APPROVE" }],
    } as unknown as Chain97Plan);
    const compile = (candidate: Chain97Plan) => compileChain97Plan({ plan: candidate, selectedScenarioIds: [], artifacts: new Map([[financeArtifact.artifactId, financeArtifact], [erc20Artifact.artifactId, erc20Artifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } });

    expect(() => compile(makePlan("1"))).toThrow("CHAIN97_ASSET_CANONICAL_MINIMUM_INVALID");
    expect(() => compile(makePlan(amount, "walletA"))).toThrow("CHAIN97_ASSET_SPENDER_MISMATCH");
    expect(() => compile({ ...makePlan(amount), assetRequirements: [] } as unknown as Chain97Plan)).toThrow("CHAIN97_ASSET_FUNDING_REQUIREMENT_MISSING:bootstrap:FUND");
    expect(() => compile(makePlan(amount))).not.toThrow();
  });

  it("rejects literal external addresses and provenance mismatches before a mocked send", async () => {
    const senderFactory = vi.fn();
    await expect(authorizeChain97Broadcast({
      compile: () => { throw new Error("CHAIN97_EXTERNAL_ADDRESS_LITERAL_FORBIDDEN:pancakeRouter"); },
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_EXTERNAL_ADDRESS_LITERAL_FORBIDDEN");
    expect(senderFactory).not.toHaveBeenCalled();

    await expect(authorizeChain97Broadcast({
      compile: () => { throw new Error("CHAIN97_CREATION_PROVENANCE_MISMATCH:vault"); },
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_CREATION_PROVENANCE_MISMATCH");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it.each([
    ["unresolved target", "CHAIN97_PLAN_REFERENCE_MISSING", { ref: "unknown" }, "DEPLOY_DIRECT"],
    ["wrong creation transaction", "CHAIN97_CREATION_PROVENANCE_MISMATCH", { ref: "factory" }, "NOT_THE_DEPLOYMENT"],
  ])("statically rejects an %s before constructing mocked senders", async (_name, error, target, creationTransaction) => {
    const artifact: FoundryArtifact = {
      artifactId: "Example.sol/Example", contractName: "Example", sourceName: "src/Example.sol", abi: [
        { type: "constructor", stateMutability: "nonpayable", inputs: [] },
        { type: "function", name: "ping", stateMutability: "nonpayable", inputs: [], outputs: [] },
      ], bytecode: "0x6000", deployedBytecode: "0x6001", compilerVersion: "0.8.28+commit.7893614a",
      metadata: { compiler: { version: "0.8.28+commit.7893614a" }, language: "Solidity", settings: { compilationTarget: { "src/Example.sol": "Example" } }, sources: { "src/Example.sol": {} } },
      metadataJson: "{}", standardJsonInput: { language: "Solidity", sources: { "src/Example.sol": { content: "contract Example {}" } }, settings: {} },
    };
    const bootstrap = [{ id: "DEPLOY_DIRECT", assertion: "deploy", kind: "deploy", wallet: "A", artifact: artifact.artifactId, constructorArgs: [], captureAddress: "factory", valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] }];
    if (target.ref === "unknown") bootstrap.push({ id: "BAD_CALL", assertion: "call", kind: "call", wallet: "A", artifact: artifact.artifactId, target, functionName: "ping", args: [], valueWei: "0", gasLimit: "100000", requiredEvents: [], captures: [], reads: [] } as never);
    const exploit = {
      schemaVersion: 1, chainId: 97, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12", confirmations: 12, maxGasPriceWei: "1",
      dependencies: [], assetRequirements: [], bootstrap, scenarios: [],
      verificationTargets: [{ name: "factory", address: { ref: "factory" }, artifact: artifact.artifactId, constructorArgs: [], creationTransaction }],
    } as unknown as Chain97Plan;
    const senderFactory = vi.fn();
    await expect(authorizeChain97Broadcast({
      compile: () => compileChain97Plan({ plan: exploit, selectedScenarioIds: [], artifacts: new Map([[artifact.artifactId, artifact]]), walletAddresses: { A: address("1"), B: address("2"), C: address("3") } }),
      preflight: async () => undefined,
      createSenders: senderFactory,
    })).rejects.toThrow(error);
    expect(senderFactory).not.toHaveBeenCalled();
  });
});

describe("Chain 97 preflight integrity", () => {
  it("rejects a canonical block replacement after confirmation", async () => {
    const getBlock = vi.fn().mockResolvedValue({ hash: hash("b") });
    await expect(assertCanonicalBlock({ getBlock } as never, 100n, hash("a"), "primary")).rejects.toThrow("CHAIN97_REORG_DETECTED:primary");
  });

  it("rejects ERC20 balance shortfalls and any non-exact allowance, including over-approval", () => {
    expect(() => assertAssetPreflight({ balance: 9n, allowance: 20n }, { minimumBalance: 10n, minimumAllowance: 20n }, "bscUsdt:B")).toThrow("CHAIN97_ASSET_BALANCE_INSUFFICIENT:bscUsdt:B");
    expect(() => assertAssetPreflight({ balance: 20n, allowance: 9n }, { minimumBalance: 10n, minimumAllowance: 10n }, "bscUsdt:B")).toThrow("CHAIN97_ASSET_ALLOWANCE_MISMATCH:bscUsdt:B:10:9");
    expect(() => assertAssetPreflight({ balance: 20n, allowance: 11n }, { minimumBalance: 10n, minimumAllowance: 10n }, "bscUsdt:B")).toThrow("CHAIN97_ASSET_ALLOWANCE_MISMATCH:bscUsdt:B:10:11");
    expect(() => assertAssetPreflight({ balance: 20n, allowance: 10n }, { minimumBalance: 10n, minimumAllowance: 10n }, "bscUsdt:B")).not.toThrow();
  });

  it("requires the exact remaining allowance when resuming after a completed funding prefix", () => {
    const funding = (amount: string) => ({ kind: "call", args: [{ uint: amount }] }) as Chain97StepInput;
    const steps = new Map<string, Chain97StepInput>([["scenario:FUND_ONE", funding("600")], ["scenario:FUND_TWO", funding("400")]]);
    const remaining = calculateRemainingAssetFunding(["scenario:FUND_ONE", "scenario:FUND_TWO"], new Set(["scenario:FUND_ONE"]), steps);
    expect(remaining).toBe(400n);
    expect(() => assertAssetPreflight({ balance: 400n, allowance: 1_000n }, { minimumBalance: remaining, minimumAllowance: remaining }, "bscUsdt:A:resume")).toThrow("CHAIN97_ASSET_ALLOWANCE_MISMATCH:bscUsdt:A:resume:400:1000");
    expect(() => assertAssetPreflight({ balance: 400n, allowance: 400n }, { minimumBalance: remaining, minimumAllowance: remaining }, "bscUsdt:A:resume")).not.toThrow();
  });

  it("rejects a fully completed funding checkpoint with residual allowance before constructing a sender", async () => {
    const fixture = completedAssetCheckpointFixture(1n);
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => fixture.plan,
      preflight: async () => preflightAssets(fixture.plan, [], fixture.references, fixture.completed, fixture.accounts as never, fixture.rpc as never, fixture.canonicalBlock, fixture.historical as never),
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_CHECKPOINT_ASSET_ALLOWANCE_MISMATCH:bootstrap:FUND:0:1");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("still reads fully completed asset state and rejects a later residual allowance before constructing a sender", async () => {
    const fixture = completedAssetCheckpointFixture(0n, {}, 1n);
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => fixture.plan,
      preflight: async () => preflightAssets(fixture.plan, [], fixture.references, fixture.completed, fixture.accounts as never, fixture.rpc as never, fixture.canonicalBlock, fixture.historical as never),
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_ASSET_ALLOWANCE_MISMATCH:bscUsdt:A:0:1");
    expect(fixture.rpc.primary.request).toHaveBeenCalledTimes(2);
    expect(fixture.rpc.secondary.request).toHaveBeenCalledTimes(2);
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it.each([
    ["owner", { owner: address("2") }],
    ["spender", { spender: address("9") }],
    ["amount", { amount: "999999999999999999" }],
  ])("rejects a checkpoint approval with the wrong %s before constructing a sender", async (_field, approvalArgs) => {
    const fixture = completedAssetCheckpointFixture(0n, approvalArgs);
    const senderFactory = vi.fn();

    await expect(authorizeChain97Broadcast({
      compile: () => fixture.plan,
      preflight: async () => preflightAssets(fixture.plan, [], fixture.references, fixture.completed, fixture.accounts as never, fixture.rpc as never, fixture.canonicalBlock, fixture.historical as never),
      createSenders: senderFactory,
    })).rejects.toThrow("CHAIN97_CHECKPOINT_ASSET_APPROVAL_INVALID:bootstrap:APPROVE");
    expect(senderFactory).not.toHaveBeenCalled();
  });

  it("does not expose normalized or original credential path segments", () => {
    const raw = "https://bsc-testnet-rpc.publicnode.com/v3/super-secret-path?token=query-secret";
    const message = redactChain97Error(new Error(`request to ${new URL(raw).toString()} failed: /v3/super-secret-path`), { CHAIN97_RPC_PRIMARY: raw });
    expect(message).not.toContain("super-secret-path");
    expect(message).not.toContain("query-secret");
    expect(message).not.toContain("publicnode.com");
  });

  it("rejects checkpoint tampering while preserving release and plan binding", () => {
    const checkpoint = createCheckpoint({
      releaseCommit: "abcdef1234567890abcdef1234567890abcdef12",
      planHash: hash("a"),
      completed: [{ executionKey: "flap-joint-launch:DEPLOY", transactionHash: hash("b"), blockNumber: "100", blockHash: hash("c") }],
    });
    expect(parseCheckpoint(JSON.stringify(checkpoint), checkpoint.releaseCommit, checkpoint.planHash)).toEqual(checkpoint);
    expect(() => parseCheckpoint(JSON.stringify({ ...checkpoint, completed: [{ ...checkpoint.completed[0], blockHash: hash("d") }] }), checkpoint.releaseCommit, checkpoint.planHash)).toThrow("CHAIN97_CHECKPOINT_INTEGRITY_MISMATCH");
  });

  it("rejects one checkpoint transaction hash reused for two execution keys", () => {
    expect(() => createCheckpoint({
      releaseCommit: "abcdef1234567890abcdef1234567890abcdef12",
      planHash: hash("a"),
      completed: [
        { executionKey: "flap-joint-launch:MINT", transactionHash: hash("b"), blockNumber: "100", blockHash: hash("c") },
        { executionKey: "flap-joint-launch:FLAP_FAIL", transactionHash: hash("b"), blockNumber: "101", blockHash: hash("d") },
      ],
    })).toThrow("CHAIN97_CHECKPOINT_TRANSACTION_DUPLICATE");
  });

  it("rejects a plan path that escapes the repository through a symlink", async () => {
    const root = await mkdtemp(join(tmpdir(), "chain97-root-"));
    const outside = await mkdtemp(join(tmpdir(), "chain97-outside-"));
    await mkdir(join(root, "config"));
    await writeFile(join(outside, "plan.json"), "{}");
    await symlink(outside, join(root, "config", "linked"));
    await expect(resolvePlanFile(root, "config/linked/plan.json")).rejects.toThrow("CHAIN97_PLAN_PATH_OUTSIDE_REPOSITORY");
  });
});
