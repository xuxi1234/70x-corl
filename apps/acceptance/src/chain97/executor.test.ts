import { describe, expect, it, vi } from "vitest";
import { canonicalReference, canonicalScenarioById, canonicalStagePolicy } from "../scenario-manifest";

import {
  assertChain97Budgets,
  assertCanonicalLifecycle,
  authorizeChain97Broadcast,
  calculateChain97Budgets,
  loadChain97Runtime,
  redactChain97Error,
  validateChain97Plan,
  type Chain97PlanInput,
  type PlanValue,
} from "./executor";

const releaseCommit = "abcdef1234567890abcdef1234567890abcdef12";
const address = (digit: string) => `0x${digit.repeat(40)}`;
const codeHash = (digit: string) => `0x${digit.repeat(64)}`;
const assertionsByStage: Record<string, string> = {
  DEPLOY: "0.005 BNB fee", MINT: "BNB shares", FLAP_FAIL: "adapter failure preserves principal",
  FLAP_RETRY: "permissionless adapter retry", CLAIM: "claims enabled", REFUND_DEPLOY: "independent refund vault",
  REFUND_MINT: "refundable principal", REFUND: "exact principal refund",
  REFUND_ENABLE: "24-hour on-chain delay reached",
};
const flapStage = (id: string, _wallet: "A" | "B" | "C", valueWei = "0") => {
  const policy = canonicalStagePolicy("flap-joint-launch", id);
  return ({
  id,
  assertion: assertionsByStage[id]!,
  kind: policy.kind,
  wallet: policy.wallet,
  target: { ref: canonicalReference("flap-joint-launch", "FLAP_JOINT", policy.target) },
  artifact: policy.artifact,
  ...(policy.kind === "factoryDeploy" ? {} : { functionName: policy.functionName!, args: id === "MINT" ? [{ uint: "2" }] : id === "REFUND_MINT" ? [{ uint: "1" }] : id === "FLAP_FAIL" || id === "FLAP_RETRY" ? [{ poolKind: { uint: "0" }, poolAsset: { localAddress: "ZERO" }, salt: codeHash("9"), minimumPurchased: { uint: "1" }, deadline: { uint: "2000000000" }, protectionDuration: { uint: "0" } }] : [] }),
  valueWei,
  gasLimit: "500000",
  requiredEvents: policy.events.map((event) => ({ artifact: event.artifact, event: event.name, address: { ref: canonicalReference("flap-joint-launch", "FLAP_JOINT", event.emitter) } })),
  captures: id === "DEPLOY" ? [
    { event: "ProjectDeployed", argument: "token", ref: "flap-joint-launch.DEPLOY.ProjectDeployed.token" },
    { event: "ProjectDeployed", argument: "vault", ref: "flap-joint-launch.DEPLOY.ProjectDeployed.vault", creation: true },
  ] : id === "REFUND_DEPLOY" ? [
    { event: "ProjectDeployed", argument: "token", ref: "flap-joint-launch.REFUND_DEPLOY.ProjectDeployed.token" },
    { event: "ProjectDeployed", argument: "vault", ref: "flap-joint-launch.REFUND_DEPLOY.ProjectDeployed.vault", creation: true },
  ] : id === "FLAP_RETRY" ? [
    { event: "Launched", argument: "token", ref: "flap-joint-launch.FLAP_RETRY.Launched.token" },
  ] : [],
  reads: policy.reads.map((read) => ({ name: read.name, target: { ref: canonicalReference("flap-joint-launch", "FLAP_JOINT", read.target) }, artifact: read.artifact, functionName: read.functionName, args: [] })),
}); };

const plan: Chain97PlanInput = {
  schemaVersion: 1,
  chainId: 97,
  releaseCommit,
  confirmations: 12,
  maxGasPriceWei: "3000000000",
  dependencies: [
    { name: "flapProtocol", address: address("5"), codeHash: codeHash("5") },
    { name: "template.FLAP_JOINT", address: address("7"), codeHash: codeHash("7") },
  ],
  assetRequirements: [],
  verificationTargets: [{
    name: "factory",
    address: { ref: "factory" },
    artifact: "LaunchFactory.sol/LaunchFactory",
    constructorArgs: [],
    creationTransaction: "DEPLOY_FACTORY",
  }],
  bootstrap: [{
    id: "DEPLOY_FACTORY",
    assertion: "deterministic factory deployment",
    kind: "deploy",
    wallet: "A",
    artifact: "LaunchFactory.sol/LaunchFactory",
    constructorArgs: [{ ref: "flapProtocol" }, []],
    captureAddress: "factory",
    valueWei: "0",
    gasLimit: "1000000",
    requiredEvents: [],
    captures: [],
    reads: [{ name: "owner", target: { ref: "factory" }, artifact: "LaunchFactory.sol/LaunchFactory", functionName: "owner", args: [] }],
  }],
  scenarios: [{
    id: "flap-joint-launch",
    form: {
      templateId: "FLAP_JOINT",
      version: 1,
      commonConfig: {
        name: "Flap acceptance",
        symbol: "FLAPA",
        supply: "1000000000",
        buyTaxBps: 100,
        sellTaxBps: 100,
        receiver: { ref: "walletA" },
        rewardToken: { localAddress: "ZERO" },
        rewardThreshold: "0",
        lpMode: 0,
        allocationBps: [2500, 2500, 2500, 2500],
        metadataHash: codeHash("8"),
      },
      templateConfig: {
        goal: "2000000000000000000",
        totalShares: 2,
        initialRoot: codeHash("0"),
        whitelistDeadline: "0",
        protectionDuration: "0",
      },
    },
    indexProjectRef: "flap-joint-launch.DEPLOY.ProjectDeployed.vault",
    steps: [
      flapStage("DEPLOY", "A", "5000000000000000"), flapStage("MINT", "B", "2000000000000000000"),
      flapStage("FLAP_FAIL", "C"), flapStage("FLAP_RETRY", "C"), flapStage("CLAIM", "B"),
      flapStage("REFUND_DEPLOY", "A", "5000000000000000"), flapStage("REFUND_MINT", "C", "1000000000000000000"), flapStage("REFUND_ENABLE", "A"), flapStage("REFUND", "C"),
    ] as Chain97PlanInput["scenarios"][number]["steps"],
    verificationTargets: [{
      name: "flapVault",
      address: { ref: "flap-joint-launch.DEPLOY.ProjectDeployed.vault" },
      artifact: "FlapMintVault.sol/FlapMintVault",
      constructorArgs: [],
      creationTransaction: "DEPLOY",
    }],
  }],
};

const financeScenario = (): Chain97PlanInput["scenarios"][number] => {
  const scenarioId = "finance-exit-multiple";
  const manifest = canonicalScenarioById.get(scenarioId)!;
  const args: Record<string, PlanValue[]> = {
    MINT: [{ uint: "1" }], FILL: [{ uint: "1" }], FINALIZE: [{ minOutput: { uint: "1" }, deadline: { uint: "2000000000" } }], CLAIM: [],
    POSITION_OPEN_NATIVE: [{ uint: "20000" }], POSITION_OPEN_TOKEN_APPROVE: [{ ref: `${scenarioId}.DEPLOY.FinanceCompanionDeployed.financeVault` }, { uint: "1000000000000000000" }], POSITION_OPEN_TOKEN: [{ uint: "1000000000000000000" }, { uint: "20000" }],
    POSITION_FUND_NATIVE: [], POSITION_FUND_TOKEN_APPROVE: [{ ref: `${scenarioId}.DEPLOY.FinanceCompanionDeployed.financeVault` }, { uint: "1000000000000000000" }], POSITION_FUND_TOKEN: [{ uint: "1000000000000000000" }],
    POSITION_CLAIM_NATIVE: [{ uint: "0" }, { uint: "20000000000000000" }], POSITION_CLAIM_TOKEN: [{ uint: "1" }, { uint: "2000000000000000000" }],
  };
  const valueWei: Record<string, string> = {
    DEPLOY: "5000000000000000", MINT: "50", FILL: "50", POSITION_OPEN_NATIVE: "10000000000000000", POSITION_FUND_NATIVE: "10000000000000000",
  };
  const steps = manifest.stages.map((stage) => {
    const policy = canonicalStagePolicy(scenarioId, stage.name);
    return {
      id: stage.name, assertion: stage.assertion, kind: policy.kind, wallet: policy.wallet, artifact: policy.artifact,
      target: { ref: canonicalReference(scenarioId, manifest.templateId, policy.target) },
      ...(policy.kind === "call" ? { functionName: policy.functionName!, args: args[stage.name] ?? [] } : {}),
      valueWei: valueWei[stage.name] ?? "0", gasLimit: "500000",
      requiredEvents: policy.events.map((event) => ({ artifact: event.artifact, event: event.name, address: { ref: canonicalReference(scenarioId, manifest.templateId, event.emitter) } })),
      captures: stage.name === "DEPLOY" ? manifest.deploymentCaptures.map((capture) => ({ ...capture, ref: `${scenarioId}.DEPLOY.${capture.event}.${capture.argument}` })) : [],
      reads: policy.reads.map((read) => ({ name: read.name, target: { ref: canonicalReference(scenarioId, manifest.templateId, read.target) }, artifact: read.artifact, functionName: read.functionName, args: [...read.args] })),
    };
  }) as Chain97PlanInput["scenarios"][number]["steps"];
  return {
    id: scenarioId,
    form: {
      templateId: "FINANCE_EXIT", version: 1,
      commonConfig: { name: "Finance", symbol: "FIN", supply: "1", buyTaxBps: 0, sellTaxBps: 0, receiver: { ref: "walletA" }, rewardToken: { localAddress: "ZERO" }, rewardThreshold: "0", lpMode: 0, allocationBps: [2500, 2500, 2500, 2500], metadataHash: codeHash("8") },
      templateConfig: { launch: { totalShares: 2, pricePerShare: "50", claimTokenBps: 5000, minimumLiquidityOutput: "1" }, supportedToken: { ref: "bscUsdt" } },
    },
    indexProjectRef: `${scenarioId}.DEPLOY.ProjectDeployed.vault`, steps, verificationTargets: [],
  };
};

describe("real Chain 97 executor guardrails", () => {
  it("requires the exact manual confirmation and binds release identity to GITHUB_SHA and checked-out HEAD", () => {
    const env = {
      SEND_CHAIN97_TRANSACTIONS: "SEND_CHAIN97_TRANSACTIONS",
      GITHUB_SHA: releaseCommit,
      CHAIN97_PLAN_PATH: "apps/acceptance/config/chain97.json",
      CHAIN97_BSCSCAN_API_KEY: "configured",
      CHAIN97_INDEXER_BASE_URL: "https://indexer.example",
      CHAIN97_CHECKPOINT_PATH: ".chain97/checkpoint.json",
    };

    expect(loadChain97Runtime(env, releaseCommit, releaseCommit)).toMatchObject({ githubSha: releaseCommit });
    expect(() => loadChain97Runtime({ ...env, SEND_CHAIN97_TRANSACTIONS: "yes" }, releaseCommit, releaseCommit)).toThrow("CHAIN97_SEND_CONFIRMATION_REQUIRED");
    expect(() => loadChain97Runtime({ ...env, GITHUB_SHA: codeHash("a") }, releaseCommit, releaseCommit)).toThrow("CHAIN97_RELEASE_COMMIT_MISMATCH");
    expect(() => loadChain97Runtime(env, releaseCommit, "0123456789012345678901234567890123456789")).toThrow("CHAIN97_CHECKOUT_COMMIT_MISMATCH");
  });

  it("requires exact external dependency addresses/code hashes and all live service configuration", () => {
    expect(() => validateChain97Plan(plan, releaseCommit, ["flap-joint-launch"])).not.toThrow();
    expect(validateChain97Plan({ ...plan, releaseCommit: "self" }, releaseCommit, ["flap-joint-launch"]).releaseCommit).toBe(releaseCommit);
    expect(() => validateChain97Plan({ ...plan, releaseCommit: "0123456789012345678901234567890123456789" }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_PLAN_RELEASE_MISMATCH");
    expect(() => validateChain97Plan({ ...plan, dependencies: [{ ...plan.dependencies[0]!, codeHash: codeHash("0") }, ...plan.dependencies.slice(1)] }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_DEPENDENCY_CODEHASH_INVALID:flapProtocol");
    expect(() => validateChain97Plan({ ...plan, dependencies: [...plan.dependencies, { name: "decorativeRouter", address: address("9"), codeHash: codeHash("9") }] }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_DEPENDENCY_UNUSED:decorativeRouter");
    expect(() => validateChain97Plan({
      ...plan,
      scenarios: [{ ...plan.scenarios[0]!, form: { ...plan.scenarios[0]!.form, commonConfig: { ...(plan.scenarios[0]!.form.commonConfig as object), supply: "999999999" } } }],
    }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_FLAP_COMMON_CONFIG_INVALID:flap-joint-launch");
    expect(() => validateChain97Plan({
      ...plan,
      scenarios: [{ ...plan.scenarios[0]!, form: { ...plan.scenarios[0]!.form, commonConfig: { ...(plan.scenarios[0]!.form.commonConfig as object), receiver: address("8") } } }],
    }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_EXTERNAL_ADDRESS_LITERAL_FORBIDDEN");
  });

  it("rejects checkpoint migrations that do not bind the exact next failed deploy and gas increase", () => {
    const retry = { ...plan.bootstrap[0]!, id: "RETRY_FACTORY", captureAddress: "retryFactory", gasLimit: "2000000", reads: [{ ...plan.bootstrap[0]!.reads[0]!, target: { ref: "retryFactory" } }] };
    const migrationPlan: Chain97PlanInput = {
      ...plan,
      bootstrap: [...plan.bootstrap, retry],
      verificationTargets: [...plan.verificationTargets, { ...plan.verificationTargets[0]!, name: "retryFactory", address: { ref: "retryFactory" }, creationTransaction: "RETRY_FACTORY" }],
    };
    const base = {
      releaseCommit,
      planHash: codeHash("a"),
      completedExecutionKeys: ["bootstrap:DEPLOY_FACTORY"],
      failedAttempt: { executionKey: "bootstrap:RETRY_FACTORY", transactionHash: codeHash("b"), gasLimit: "999999" },
    };
    expect(() => validateChain97Plan({ ...migrationPlan, checkpointMigrations: [base] }, releaseCommit, ["flap-joint-launch"])).not.toThrow();
    expect(() => validateChain97Plan({ ...migrationPlan, checkpointMigrations: [{ ...base, completedExecutionKeys: ["bootstrap:WRONG"] }] }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_CHECKPOINT_MIGRATION_PREFIX_INVALID");
    expect(() => validateChain97Plan({ ...migrationPlan, checkpointMigrations: [{ ...base, failedAttempt: { ...base.failedAttempt, executionKey: "flap-joint-launch:MINT" } }] }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_CHECKPOINT_MIGRATION_SEQUENCE_INVALID");
    expect(() => validateChain97Plan({ ...migrationPlan, checkpointMigrations: [{ ...base, failedAttempt: { ...base.failedAttempt, gasLimit: "2000000" } }] }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_CHECKPOINT_MIGRATION_GAS_INVALID");
  });

  it("rejects literal-address and unused-dependency bypass plans before constructing a mocked sender", async () => {
    const createSenders = vi.fn();
    const literalPlan = {
      ...plan,
      scenarios: [{ ...plan.scenarios[0]!, form: { ...plan.scenarios[0]!.form, commonConfig: { ...(plan.scenarios[0]!.form.commonConfig as object), receiver: address("8") } } }],
    };
    await expect(authorizeChain97Broadcast({
      compile: () => validateChain97Plan(literalPlan, releaseCommit, ["flap-joint-launch"]),
      preflight: async () => undefined,
      createSenders,
    })).rejects.toThrow("CHAIN97_EXTERNAL_ADDRESS_LITERAL_FORBIDDEN");
    expect(createSenders).not.toHaveBeenCalled();

    await expect(authorizeChain97Broadcast({
      compile: () => validateChain97Plan({ ...plan, dependencies: [...plan.dependencies, { name: "decorativeRouter", address: address("9"), codeHash: codeHash("9") }] }, releaseCommit, ["flap-joint-launch"]),
      preflight: async () => undefined,
      createSenders,
    })).rejects.toThrow("CHAIN97_DEPENDENCY_UNUSED:decorativeRouter");
    expect(createSenders).not.toHaveBeenCalled();
  });

  it("rejects canonical action, emitter, read, and amount tampering before sender construction", async () => {
    const mutateStage = (id: string, mutate: (step: Chain97PlanInput["scenarios"][number]["steps"][number]) => Chain97PlanInput["scenarios"][number]["steps"][number]) => ({
      ...plan,
      scenarios: [{ ...plan.scenarios[0]!, steps: plan.scenarios[0]!.steps.map((step) => step.id === id ? mutate(step) : step) }],
    });
    const exploits = [
      mutateStage("MINT", (step) => ({ ...step, artifact: "MintVault.sol/MintVault" })),
      mutateStage("MINT", (step) => ({ ...step, requiredEvents: step.requiredEvents.map((event) => ({ ...event, address: { ref: "factory" } })) })),
      mutateStage("MINT", (step) => ({ ...step, reads: step.reads.map((read, index) => index === 0 ? { ...read, functionName: "totalPaid" } : read) })),
      mutateStage("MINT", (step) => ({ ...step, valueWei: "1" })),
      mutateStage("MINT", (step) => step.kind === "call" ? { ...step, args: [{ uint: "1" }] } : step),
    ];
    for (const exploit of exploits) {
      const createSenders = vi.fn();
      await expect(authorizeChain97Broadcast({ compile: () => validateChain97Plan(exploit, releaseCommit, ["flap-joint-launch"]), preflight: async () => undefined, createSenders })).rejects.toThrow(/CHAIN97_/);
      expect(createSenders).not.toHaveBeenCalled();
    }
  });

  it("binds finance action amounts, position ids, and direct-state read arguments to canonical economics", () => {
    const valid = financeScenario();
    expect(() => assertCanonicalLifecycle(valid as never)).not.toThrow();
    const wrongClaim = { ...valid, steps: valid.steps.map((step) => step.id === "POSITION_CLAIM_TOKEN" && step.kind === "call" ? { ...step, args: [{ uint: "0" }, { uint: "1" }] } : step) };
    expect(() => assertCanonicalLifecycle(wrongClaim as never)).toThrow("CHAIN97_SCENARIO_ARGUMENT_INVALID:finance-exit-multiple:POSITION_CLAIM_TOKEN:claim");
    const wrongRead = { ...valid, steps: valid.steps.map((step) => step.id === "POSITION_CLAIM_TOKEN" ? { ...step, reads: step.reads.map((read) => read.name === "position" ? { ...read, args: [{ uint: "0" }] } : read) } : step) };
    expect(() => assertCanonicalLifecycle(wrongRead as never)).toThrow("CHAIN97_SCENARIO_READ_INVALID:finance-exit-multiple:POSITION_CLAIM_TOKEN:position");
  });

  it("rejects selecting the later refund Factory deployment as the indexed primary project before sender construction", async () => {
    const createSenders = vi.fn();
    const exploit = { ...plan, scenarios: [{ ...plan.scenarios[0]!, indexProjectRef: "flap-joint-launch.REFUND_DEPLOY.ProjectDeployed.vault" }] };
    await expect(authorizeChain97Broadcast({ compile: () => validateChain97Plan(exploit, releaseCommit, ["flap-joint-launch"]), preflight: async () => undefined, createSenders })).rejects.toThrow("CHAIN97_INDEX_PROJECT_REFERENCE_INVALID");
    expect(createSenders).not.toHaveBeenCalled();
  });

  it("computes the complete worst-case wallet budget before broadcast", () => {
    const parsed = validateChain97Plan(plan, releaseCommit, ["flap-joint-launch"]);
    const budgets = calculateChain97Budgets(parsed, ["flap-joint-launch"]);

    expect(budgets.A).toBeGreaterThan(10_000_000_000_000_000n);
    expect(budgets.B).toBeGreaterThan(2_000_000_000_000_000_000n);
    expect(budgets.C).toBeGreaterThan(100_000_000_000_000_000n);
    expect(() => assertChain97Budgets(budgets, { A: 1_000_000_000_000_000_000n, B: 741_000_000_000_000_000n, C: 150_000_000_000_000_000n })).toThrow("CHAIN97_PREFLIGHT_BUDGET_INSUFFICIENT:B");
  });

  it("rejects a plan that could persist a credential-bearing URL", () => {
    expect(() => validateChain97Plan({
      ...plan,
      scenarios: [{ ...plan.scenarios[0]!, indexProjectRef: "https://user:secret@indexer.example/project" }],
    }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_PLAN_CREDENTIAL_URL_FORBIDDEN");
  });

  it("requires verification coverage for every deterministic top-level deployment", () => {
    expect(() => validateChain97Plan({ ...plan, verificationTargets: [] }, releaseCommit, ["flap-joint-launch"])).toThrow("CHAIN97_DEPLOYMENT_VERIFICATION_TARGET_MISSING:factory");
  });

  it("sanitizes provider errors before they can reach Actions logs", () => {
    const secretKey = `0x${"9".repeat(64)}`;
    const rpc = "https://user:password@bsc-testnet-rpc.publicnode.com/v3/private-token?apiKey=also-secret";
    const message = redactChain97Error(new Error(`request failed ${secretKey} ${rpc}`), {
      CHAIN97_PRIVATE_KEY_A: secretKey,
      CHAIN97_RPC_PRIMARY: rpc,
      CHAIN97_BSCSCAN_API_KEY: "also-secret",
    });

    expect(message).toContain("request failed");
    expect(message).not.toContain(secretKey);
    expect(message).not.toContain("password");
    expect(message).not.toContain("private-token");
    expect(message).not.toContain("also-secret");
  });
});
