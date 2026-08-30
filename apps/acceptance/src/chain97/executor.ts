import { execFile as execFileCallback } from "node:child_process";
import { readFile, realpath } from "node:fs/promises";
import { relative, resolve } from "node:path";
import { promisify } from "node:util";

import { isAddress } from "viem";
import { z } from "zod";

import type { TemplateId } from "@70x/protocol";
import { canonicalReference, canonicalScenarioById, canonicalStagePolicy } from "../scenario-manifest";

export type WalletSlot = "A" | "B" | "C";
export type PlanReference = { ref: string };
export type PlanInteger = { uint: string };
export type PlanDeadline = { nowPlusSeconds: number };
export type PlanLocalAddress = { localAddress: "ZERO" | "DEAD" };
export type PlanValue = string | number | boolean | PlanReference | PlanInteger | PlanDeadline | PlanLocalAddress | PlanValue[] | { [key: string]: PlanValue };

export type Chain97ReadInput = {
  name: string;
  target: PlanReference;
  artifact: string;
  functionName: string;
  args: PlanValue[];
  captureRef?: string | undefined;
};

export type Chain97RequiredEventInput = { artifact: string; event: string; address?: PlanReference | undefined };
export type Chain97CaptureInput = { event: string; argument: string; ref: string; creation?: boolean | undefined };
export type Chain97RevertProbeInput = {
  name: string;
  target: PlanReference;
  artifact: string;
  functionName: string;
  args: PlanValue[];
  wallet: WalletSlot;
  valueWei: string;
  errorArtifact: string;
  errorName: string;
};
type Chain97StepBaseInput = {
  id: string;
  assertion: string;
  wallet: WalletSlot;
  artifact: string;
  valueWei: string;
  gasLimit: string;
  requiredEvents: Chain97RequiredEventInput[];
  captures: Chain97CaptureInput[];
  reads: Chain97ReadInput[];
  revertProbes?: Chain97RevertProbeInput[] | undefined;
};
export type Chain97DeployStepInput = Chain97StepBaseInput & {
  kind: "deploy";
  constructorArgs: PlanValue[];
  captureAddress: string;
};
export type Chain97CallStepInput = Chain97StepBaseInput & {
  kind: "call";
  target: PlanReference;
  functionName: string;
  args: PlanValue[];
};
export type Chain97FactoryDeployStepInput = Chain97StepBaseInput & {
  kind: "factoryDeploy";
  target: PlanReference;
};
export type Chain97StepInput = Chain97DeployStepInput | Chain97CallStepInput | Chain97FactoryDeployStepInput;

export type Chain97PlanInput = {
  schemaVersion: 1;
  chainId: 97;
  releaseCommit: string;
  confirmations: number;
  maxGasPriceWei: string;
  dependencies: Array<{ name: string; address: string; codeHash: string }>;
  assetRequirements: Array<{
    asset: PlanReference;
    wallet: WalletSlot;
    minimumBalance: string;
    spender: PlanReference;
    minimumAllowance: string;
    fundingExecutionKeys: string[];
    approvalExecutionKey?: string | undefined;
  }>;
  verificationTargets: Chain97VerificationTargetInput[];
  bootstrap: Chain97StepInput[];
  scenarios: Array<{
    id: string;
    form: { templateId: TemplateId; version: number; commonConfig: PlanValue; templateConfig: PlanValue };
    indexProjectRef: string;
    steps: Chain97StepInput[];
    verificationTargets: Chain97VerificationTargetInput[];
  }>;
};

export type Chain97VerificationTargetInput = {
  name: string;
  address: PlanReference;
  artifact: string;
  constructorArgs: PlanValue[];
  creationTransaction: string;
};

export type Chain97Plan = Chain97PlanInput & {
  confirmations: number;
  maxGasPriceWei: string;
};

type RunnerEnvironment = Record<string, string | undefined>;
const execFile = promisify(execFileCallback);

export type Chain97Runtime = {
  githubSha: string;
  planPath: string;
  bscscanApiKey: string;
  indexerBaseUrl: string;
  indexerAuthToken?: string;
  checkpointPath: string;
};

const commitHash = /^[0-9a-f]{40}$/i;
const hash = /^0x[0-9a-fA-F]{64}$/;
const nonzeroHash = /^0x(?!0{64}$)[0-9a-fA-F]{64}$/;
const positiveInteger = /^[1-9][0-9]*$/;
const unsignedInteger = /^(0|[1-9][0-9]*)$/;
const identifier = /^[A-Za-z][A-Za-z0-9_.-]*$/;
const artifactName = /^[A-Za-z0-9_./-]+\.sol\/[A-Za-z_][A-Za-z0-9_]*$/;

const referenceSchema = z.object({ ref: z.string().regex(identifier) }).strict();
const targetSchema = referenceSchema;
const planValueSchema: z.ZodType<PlanValue> = z.lazy(() => z.union([
  z.string(),
  z.number().finite(),
  z.boolean(),
  referenceSchema,
  z.object({ uint: z.string().regex(unsignedInteger) }).strict(),
  z.object({ nowPlusSeconds: z.number().int().positive().max(86_400) }).strict(),
  z.object({ localAddress: z.enum(["ZERO", "DEAD"]) }).strict(),
  z.array(planValueSchema),
  z.record(z.string(), planValueSchema),
]));
const readSchema = z.object({
  name: z.string().regex(identifier),
  target: targetSchema,
  artifact: z.string().regex(artifactName),
  functionName: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/),
  args: z.array(planValueSchema),
  captureRef: z.string().regex(identifier).optional(),
}).strict();
const requiredEventSchema = z.object({
  artifact: z.string().regex(artifactName),
  event: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/),
  address: targetSchema.optional(),
}).strict();
const stepBase = {
  id: z.string().regex(identifier),
  assertion: z.string().min(1).max(256),
  wallet: z.enum(["A", "B", "C"]),
  artifact: z.string().regex(artifactName),
  valueWei: z.string().regex(unsignedInteger),
  gasLimit: z.string().regex(positiveInteger),
  requiredEvents: z.array(requiredEventSchema),
  captures: z.array(z.object({ event: z.string().regex(identifier), argument: z.string().regex(identifier), ref: z.string().regex(identifier), creation: z.boolean().optional() }).strict()),
  reads: z.array(readSchema).min(1),
  revertProbes: z.array(z.object({
    name: z.string().regex(identifier), target: targetSchema, artifact: z.string().regex(artifactName), functionName: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/),
    args: z.array(planValueSchema), wallet: z.enum(["A", "B", "C"]), valueWei: z.string().regex(unsignedInteger), errorArtifact: z.string().regex(artifactName), errorName: z.string().regex(identifier),
  }).strict()).optional(),
};
const stepSchema = z.discriminatedUnion("kind", [
  z.object({ ...stepBase, kind: z.literal("deploy"), constructorArgs: z.array(planValueSchema), captureAddress: z.string().regex(identifier) }).strict(),
  z.object({ ...stepBase, kind: z.literal("call"), target: targetSchema, functionName: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/), args: z.array(planValueSchema) }).strict(),
  z.object({ ...stepBase, kind: z.literal("factoryDeploy"), target: targetSchema }).strict(),
]);
const dependencySchema = z.object({
  name: z.string().regex(identifier),
  address: z.string().refine(isAddress),
  codeHash: z.string().regex(hash),
}).strict();
const verificationTargetSchema = z.object({
  name: z.string().regex(identifier),
  address: targetSchema,
  artifact: z.string().regex(artifactName),
  constructorArgs: z.array(planValueSchema),
  creationTransaction: z.string().regex(identifier),
}).strict();
const planSchema: z.ZodType<Chain97PlanInput> = z.object({
  schemaVersion: z.literal(1),
  chainId: z.literal(97),
  releaseCommit: z.union([z.string().regex(commitHash), z.literal("self")]),
  confirmations: z.number().int().min(2).max(100),
  maxGasPriceWei: z.string().regex(positiveInteger),
  dependencies: z.array(dependencySchema).min(1),
  assetRequirements: z.array(z.object({
    asset: referenceSchema,
    wallet: z.enum(["A", "B", "C"]),
    minimumBalance: z.string().regex(unsignedInteger),
    spender: referenceSchema,
    minimumAllowance: z.string().regex(unsignedInteger),
    fundingExecutionKeys: z.array(z.string().regex(/^(?:bootstrap|[A-Za-z][A-Za-z0-9_.-]*):[A-Za-z][A-Za-z0-9_.-]*$/)).min(1),
    approvalExecutionKey: z.string().regex(/^(?:bootstrap|[A-Za-z][A-Za-z0-9_.-]*):[A-Za-z][A-Za-z0-9_.-]*$/).optional(),
  }).strict()),
  verificationTargets: z.array(verificationTargetSchema),
  bootstrap: z.array(stepSchema).min(1),
  scenarios: z.array(z.object({
    id: z.string().regex(identifier),
    form: z.object({
      templateId: z.enum(["STANDARD", "TIME_WEIGHTED", "LP_REWARDS", "HOLDER_DEAD", "AUTO_BUYBACK", "TIMED_BUYBACK", "EXTERNAL_BURN", "FINANCE_EXIT", "LAUNCH_LIMIT", "WHITELIST", "FLAP_JOINT"]),
      version: z.literal(1),
      commonConfig: planValueSchema,
      templateConfig: planValueSchema,
    }).strict(),
    indexProjectRef: z.string().regex(identifier),
    steps: z.array(stepSchema).min(1),
    verificationTargets: z.array(verificationTargetSchema).min(1),
  }).strict()).min(1),
}).strict();

const required = (env: RunnerEnvironment, name: string) => {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name}_MISSING`);
  return value;
};

const parseServiceUrl = (raw: string, name: string) => {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`${name}_INVALID`);
  }
  if (url.protocol !== "https:" || url.username || url.password) throw new Error(`${name}_INVALID`);
  url.hash = "";
  return url.toString().replace(/\/$/, "");
};

export function loadChain97Runtime(env: RunnerEnvironment, releaseCommit: string, headCommit: string): Chain97Runtime {
  if (env.SEND_CHAIN97_TRANSACTIONS !== "SEND_CHAIN97_TRANSACTIONS") {
    throw new Error("CHAIN97_SEND_CONFIRMATION_REQUIRED");
  }
  const githubSha = required(env, "GITHUB_SHA");
  if (!commitHash.test(githubSha) || githubSha.toLowerCase() !== releaseCommit.toLowerCase()) {
    throw new Error("CHAIN97_RELEASE_COMMIT_MISMATCH");
  }
  if (headCommit.toLowerCase() !== githubSha.toLowerCase()) throw new Error("CHAIN97_CHECKOUT_COMMIT_MISMATCH");
  const planPath = required(env, "CHAIN97_PLAN_PATH");
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(planPath) || !planPath.endsWith(".json")) throw new Error("CHAIN97_PLAN_PATH_INVALID");
  const bscscanApiKey = required(env, "CHAIN97_BSCSCAN_API_KEY");
  const indexerBaseUrl = parseServiceUrl(required(env, "CHAIN97_INDEXER_BASE_URL"), "CHAIN97_INDEXER_BASE_URL");
  const indexerAuthToken = env.CHAIN97_INDEXER_AUTH_TOKEN?.trim();
  const checkpointPath = required(env, "CHAIN97_CHECKPOINT_PATH");
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(checkpointPath) || !checkpointPath.endsWith(".json")) throw new Error("CHAIN97_CHECKPOINT_PATH_INVALID");
  return { githubSha, planPath, bscscanApiKey, indexerBaseUrl, checkpointPath, ...(indexerAuthToken ? { indexerAuthToken } : {}) };
}

function containsCredentialUrl(value: unknown): boolean {
  if (typeof value === "string" && /^https?:\/\//i.test(value)) {
    return true;
  }
  if (Array.isArray(value)) return value.some(containsCredentialUrl);
  if (value && typeof value === "object") return Object.values(value).some(containsCredentialUrl);
  return false;
}

const assertUnique = (values: string[], error: string) => {
  if (new Set(values).size !== values.length) throw new Error(error);
};

const canonicalEqual = (left: readonly string[], right: readonly string[]) => left.length === right.length && left.every((item, index) => item === right[index]);
const collectRefs = (value: unknown, refs: Set<string>) => {
  if (Array.isArray(value)) return value.forEach((item) => collectRefs(item, refs));
  if (!value || typeof value !== "object") return;
  if ("ref" in value && typeof value.ref === "string") refs.add(value.ref);
  Object.values(value).forEach((item) => collectRefs(item, refs));
};

const assertNoAddressLiterals = (value: unknown, path: string): void => {
  if (typeof value === "string" && isAddress(value)) throw new Error(`CHAIN97_EXTERNAL_ADDRESS_LITERAL_FORBIDDEN:${path}`);
  if (Array.isArray(value)) return value.forEach((item, index) => assertNoAddressLiterals(item, `${path}.${index}`));
  if (value && typeof value === "object") Object.entries(value).forEach(([key, item]) => assertNoAddressLiterals(item, `${path}.${key}`));
};
const containsRelativeDeadline = (value: unknown): boolean => {
  if (Array.isArray(value)) return value.some(containsRelativeDeadline);
  if (!value || typeof value !== "object") return false;
  if ("nowPlusSeconds" in value) return true;
  return Object.values(value).some(containsRelativeDeadline);
};

export function assertCanonicalLifecycle(scenario: Chain97Plan["scenarios"][number]) {
  const manifest = canonicalScenarioById.get(scenario.id);
  if (!manifest) throw new Error(`CHAIN97_SCENARIO_UNKNOWN:${scenario.id}`);
  if (scenario.form.templateId !== manifest.templateId) throw new Error(`CHAIN97_SCENARIO_TEMPLATE_MISMATCH:${scenario.id}`);
  if (scenario.form.templateId === "FLAP_JOINT") {
    const config = scenario.form.templateConfig;
    const root = config && typeof config === "object" && !Array.isArray(config) ? (config as Record<string, PlanValue>).initialRoot : undefined;
    if (typeof root !== "string" || !/^0x0{64}$/i.test(root)) throw new Error(`CHAIN97_FLAP_WHITELIST_FORBIDDEN:${scenario.id}`);
    const common = scenario.form.commonConfig as Record<string, unknown>;
    const rewardToken = common.rewardToken;
    const tax = common.sellTaxBps;
    if (
      common.supply !== "1000000000" || common.buyTaxBps !== tax
      || typeof tax !== "number" || ![100, 300, 500, 1_000].includes(tax)
      || common.lpMode !== 0 || !rewardToken || typeof rewardToken !== "object" || Array.isArray(rewardToken)
      || (rewardToken as Record<string, unknown>).localAddress !== "ZERO"
    ) throw new Error(`CHAIN97_FLAP_COMMON_CONFIG_INVALID:${scenario.id}`);
  }
  if (scenario.steps.length !== manifest.stages.length) throw new Error(`CHAIN97_SCENARIO_STAGE_COVERAGE_INVALID:${scenario.id}`);
  let factoryDeployments = 0;
  for (let index = 0; index < manifest.stages.length; index += 1) {
    const expected = manifest.stages[index]!;
    const actual = scenario.steps[index]!;
    const policy = canonicalStagePolicy(scenario.id, expected.name);
    if (actual.id !== expected.name) throw new Error(`CHAIN97_SCENARIO_STAGE_ORDER_INVALID:${scenario.id}:${expected.name}`);
    if (actual.assertion !== expected.assertion) throw new Error(`CHAIN97_SCENARIO_ASSERTION_INVALID:${scenario.id}:${expected.name}`);
    const actualEvents = actual.requiredEvents.map(({ event }) => event);
    if (!canonicalEqual(actualEvents, expected.requiredEvents)) throw new Error(`CHAIN97_SCENARIO_EVENTS_INVALID:${scenario.id}:${expected.name}`);
    for (let eventIndex = 0; eventIndex < policy.events.length; eventIndex += 1) {
      const required = actual.requiredEvents[eventIndex]!;
      const eventPolicy = policy.events[eventIndex]!;
      if (required.artifact !== eventPolicy.artifact || required.address?.ref !== canonicalReference(scenario.id, manifest.templateId, eventPolicy.emitter)) {
        throw new Error(`CHAIN97_SCENARIO_EVENT_PROVENANCE_INVALID:${scenario.id}:${expected.name}:${eventPolicy.name}`);
      }
    }
    const isDeploymentStage = expected.requiredEvents.includes("ProjectDeployed");
    if ((actual.kind === "factoryDeploy") !== isDeploymentStage) throw new Error(`CHAIN97_FACTORY_DEPLOYMENT_STAGE_INVALID:${scenario.id}:${expected.name}`);
    if (actual.artifact !== policy.artifact || actual.wallet !== policy.wallet || actual.kind !== policy.kind || (actual.kind === "call" && actual.functionName !== policy.functionName) || ("target" in actual && actual.target.ref !== canonicalReference(scenario.id, manifest.templateId, policy.target))) {
      throw new Error(`CHAIN97_SCENARIO_ACTION_INVALID:${scenario.id}:${expected.name}`);
    }
    if (actual.reads.length !== policy.reads.length) throw new Error(`CHAIN97_SCENARIO_READ_COVERAGE_INVALID:${scenario.id}:${expected.name}`);
    for (let readIndex = 0; readIndex < policy.reads.length; readIndex += 1) {
      const read = actual.reads[readIndex]!;
      const readPolicy = policy.reads[readIndex]!;
      if (
        read.name !== readPolicy.name || read.artifact !== readPolicy.artifact || read.functionName !== readPolicy.functionName
        || read.target.ref !== canonicalReference(scenario.id, manifest.templateId, readPolicy.target)
        || canonicalValue(read.args) !== canonicalValue(readPolicy.args)
        || read.captureRef !== (readPolicy.capture ? canonicalReference(scenario.id, manifest.templateId, readPolicy.capture) : undefined)
      ) {
        throw new Error(`CHAIN97_SCENARIO_READ_INVALID:${scenario.id}:${expected.name}:${readPolicy.name}`);
      }
    }
    const probes = actual.revertProbes ?? [];
    if (probes.length !== policy.revertProbes.length) throw new Error(`CHAIN97_SCENARIO_REVERT_PROBE_COVERAGE_INVALID:${scenario.id}:${expected.name}`);
    for (let probeIndex = 0; probeIndex < policy.revertProbes.length; probeIndex += 1) {
      const probe = probes[probeIndex]!;
      const probePolicy = policy.revertProbes[probeIndex]!;
      if (
        probe.name !== probePolicy.name || probe.artifact !== probePolicy.artifact || probe.functionName !== probePolicy.functionName
        || probe.target.ref !== canonicalReference(scenario.id, manifest.templateId, probePolicy.target) || probe.wallet !== probePolicy.wallet
        || probe.errorArtifact !== probePolicy.errorArtifact || probe.errorName !== probePolicy.errorName
      ) throw new Error(`CHAIN97_SCENARIO_REVERT_PROBE_INVALID:${scenario.id}:${expected.name}:${probePolicy.name}`);
    }
    assertCanonicalStepEconomics(scenario, actual);
    if (scenario.form.templateId === "FLAP_JOINT" && expected.name === "FLAP_RETRY") {
      for (const argument of ["token"] as const) {
        const ref = `${scenario.id}.FLAP_RETRY.Launched.${argument}`;
        if (!actual.captures.some((capture) => capture.event === "Launched" && capture.argument === argument && capture.ref === ref && capture.creation !== true)) {
          throw new Error(`CHAIN97_FLAP_CREATION_CAPTURE_MISSING:${ref}`);
        }
      }
    }
    if (["REFUND_MINT", "REFUND_ENABLE", "REFUND"].includes(expected.name) && actual.kind === "call" && actual.target.ref !== `${scenario.id}.REFUND_DEPLOY.ProjectDeployed.vault`) {
      throw new Error(`CHAIN97_REFUND_TARGET_INVALID:${scenario.id}:${expected.name}`);
    }
    if (actual.kind === "factoryDeploy") factoryDeployments += 1;
  }
  const expectedFactoryDeployments = manifest.stages.filter(({ requiredEvents }) => requiredEvents.includes("ProjectDeployed")).length;
  if (factoryDeployments !== expectedFactoryDeployments) throw new Error(`CHAIN97_FACTORY_DEPLOYMENT_COUNT_INVALID:${scenario.id}`);
  if (!new RegExp(`^${scenario.id}\\.DEPLOY\\.ProjectDeployed\\.(token|vault)$`).test(scenario.indexProjectRef)) throw new Error(`CHAIN97_INDEX_PROJECT_REFERENCE_INVALID:${scenario.id}`);
  for (const deployment of scenario.steps.filter((step) => step.kind === "factoryDeploy")) {
    const expectedCaptures = deployment.id === "DEPLOY"
      ? manifest.deploymentCaptures
      : manifest.deploymentCaptures.filter(({ event }) => event === "ProjectDeployed");
    if (deployment.captures.length !== expectedCaptures.length) throw new Error(`CHAIN97_PROJECT_CREATION_CAPTURE_COVERAGE_INVALID:${scenario.id}:${deployment.id}`);
    for (const expected of expectedCaptures) {
      const ref = `${scenario.id}.${deployment.id}.${expected.event}.${expected.argument}`;
      if (!deployment.captures.some((capture) => capture.event === expected.event && capture.argument === expected.argument && capture.ref === ref && (capture.creation === true) === expected.creation)) {
        throw new Error(`CHAIN97_PROJECT_CREATION_CAPTURE_MISSING:${scenario.id}:${ref}`);
      }
    }
  }
  return manifest;
}

const configRecord = (value: PlanValue | undefined): Record<string, PlanValue> => value && typeof value === "object" && !Array.isArray(value) && !("ref" in value) && !("uint" in value) && !("nowPlusSeconds" in value) && !("localAddress" in value) ? value as Record<string, PlanValue> : {};
const canonicalValue = (value: unknown): string => Array.isArray(value) ? `[${value.map(canonicalValue).join(",")}]` : value && typeof value === "object" ? `{${Object.entries(value).sort(([left], [right]) => left.localeCompare(right)).map(([key, item]) => `${JSON.stringify(key)}:${canonicalValue(item)}`).join(",")}}` : JSON.stringify(value);
const configUint = (value: PlanValue | undefined, label: string) => {
  const raw = value && typeof value === "object" && !Array.isArray(value) && "uint" in value ? value.uint : value;
  if (!((typeof raw === "string" && /^\d+$/.test(raw)) || (typeof raw === "number" && Number.isSafeInteger(raw) && raw >= 0))) throw new Error(`CHAIN97_CANONICAL_CONFIG_VALUE_INVALID:${label}`);
  return BigInt(raw);
};
const exactUintArgument = (value: PlanValue | undefined, expected: bigint, label: string) => {
  if (!value || typeof value !== "object" || Array.isArray(value) || !("uint" in value) || BigInt(String(value.uint)) !== expected) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${label}`);
};
const exactArguments = (actual: readonly PlanValue[], expected: readonly PlanValue[], label: string) => {
  if (canonicalValue(actual) !== canonicalValue(expected)) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${label}`);
};

function assertCanonicalStepEconomics(scenario: Chain97Plan["scenarios"][number], step: Chain97StepInput) {
  const template = configRecord(scenario.form.templateConfig);
  const launch = configRecord(template.launch ?? scenario.form.templateConfig);
  const isFlap = scenario.form.templateId === "FLAP_JOINT";
  const totalShares = configUint(isFlap ? template.totalShares : launch.totalShares, `${scenario.id}:totalShares`);
  const pricePerShare = isFlap ? configUint(template.goal, `${scenario.id}:goal`) / totalShares : configUint(launch.pricePerShare, `${scenario.id}:pricePerShare`);
  let expectedValue = 0n;
  if (step.id === "DEPLOY" || step.id === "REFUND_DEPLOY") expectedValue = 5_000_000_000_000_000n;
  if (["MINT", "WHITELIST_PROOF_MINT"].includes(step.id)) {
    const shares = isFlap ? totalShares : 1n;
    expectedValue = pricePerShare * shares;
    if (step.kind !== "call") throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}`);
    exactUintArgument(step.args[0], shares, `${scenario.id}:${step.id}:shares`);
  }
  if (["FILL", "WHITELIST_PUBLIC_MINT"].includes(step.id)) {
    const shares = totalShares - 1n;
    if (shares <= 0n || step.kind !== "call") throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}`);
    expectedValue = pricePerShare * shares;
    exactUintArgument(step.args[0], shares, `${scenario.id}:${step.id}:shares`);
  }
  if (step.id === "REFUND_MINT") {
    expectedValue = pricePerShare;
    if (step.kind !== "call") throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}`);
    exactUintArgument(step.args[0], 1n, `${scenario.id}:${step.id}:shares`);
  }
  if (step.id === "BUYBACK_FUND") expectedValue = configUint(configRecord(template.buyback).threshold, `${scenario.id}:buyback.threshold`);
  if (step.id === "POSITION_OPEN_NATIVE" || step.id === "POSITION_FUND_NATIVE") expectedValue = 10_000_000_000_000_000n;
  if (BigInt(step.valueWei) !== expectedValue) throw new Error(`CHAIN97_SCENARIO_VALUE_INVALID:${scenario.id}:${step.id}`);
  const common = configRecord(scenario.form.commonConfig);
  if (!common.receiver || typeof common.receiver !== "object" || Array.isArray(common.receiver) || !("ref" in common.receiver) || common.receiver.ref !== "walletA") {
    throw new Error(`CHAIN97_CANONICAL_RECEIVER_INVALID:${scenario.id}`);
  }
  if (step.kind === "call" && step.id.startsWith("TRANCHE_")) {
    const recipient = step.id === "TRANCHE_RETURN" ? "walletB" : "walletC";
    if (!step.args[0] || typeof step.args[0] !== "object" || Array.isArray(step.args[0]) || !("ref" in step.args[0]) || step.args[0].ref !== recipient) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:recipient`);
    exactUintArgument(step.args[1], 1n, `${scenario.id}:${step.id}:amount`);
  }
  if (step.kind === "call" && step.id.startsWith("LIMIT_")) {
    const recipient = step.id === "LIMIT_EXEMPT_TRANSFER" ? { localAddress: "DEAD" } : { ref: "walletC" };
    if (canonicalValue(step.args[0]) !== canonicalValue(recipient)) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:recipient`);
    exactUintArgument(step.args[1], 1n, `${scenario.id}:${step.id}:amount`);
  }
  if (step.kind === "call" && step.id === "WHITELIST_EPOCH") {
    if (typeof step.args[0] !== "string" || !nonzeroHash.test(step.args[0])) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:root`);
  }
  if (step.kind === "call" && step.id === "WHITELIST_PROOF_MINT") {
    exactUintArgument(step.args[0], 1n, `${scenario.id}:${step.id}:shares`);
    exactUintArgument(step.args[1], 1n, `${scenario.id}:${step.id}:epoch`);
    if (!Array.isArray(step.args[2]) || step.args[2].length === 0) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:proof`);
  }
  if (step.kind === "call" && (step.id === "EXECUTE_FAIL" || step.id === "FINALIZE")) {
    const params = configRecord(step.args[0]);
    exactUintArgument(params.minOutput, configUint(launch.minimumLiquidityOutput, `${scenario.id}:minimumLiquidityOutput`), `${scenario.id}:${step.id}:minOutput`);
    if (!params.deadline || typeof params.deadline !== "object" || Array.isArray(params.deadline) || !("uint" in params.deadline)) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:deadline`);
    const failure = scenario.steps.find((candidate) => candidate.id === "EXECUTE_FAIL");
    if (step.id === "FINALIZE" && scenario.id === "standard-mint" && (!failure || failure.kind !== "call" || canonicalValue(failure.args) !== canonicalValue(step.args))) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:retryBinding`);
  }
  if (step.kind === "call" && step.id === "REWARD_FUND") exactArguments(step.args, [{ uint: "1000000000000000000" }], `${scenario.id}:${step.id}:funding`);
  if (step.kind === "call" && step.id === "REWARD_APPROVE") exactArguments(step.args, [{ ref: canonicalReference(scenario.id, scenario.form.templateId, "rewardVault") }, { uint: "1000000000000000000" }], `${scenario.id}:${step.id}:approval`);
  if (step.kind === "call" && step.id === "LP_SYNC") exactArguments(step.args, [{ ref: "walletB" }], `${scenario.id}:${step.id}:account`);
  if (step.kind === "call" && step.id === "POSITION_OPEN_NATIVE") exactArguments(step.args, [{ uint: "20000" }], `${scenario.id}:${step.id}:multiple`);
  if (step.kind === "call" && step.id === "POSITION_OPEN_TOKEN") exactArguments(step.args, [{ uint: "1000000000000000000" }, { uint: "20000" }], `${scenario.id}:${step.id}:position`);
  if (step.kind === "call" && step.id === "POSITION_OPEN_TOKEN_APPROVE") exactArguments(step.args, [{ ref: canonicalReference(scenario.id, scenario.form.templateId, "financeVault") }, { uint: "1000000000000000000" }], `${scenario.id}:${step.id}:approval`);
  if (step.kind === "call" && step.id === "POSITION_FUND_NATIVE") exactArguments(step.args, [], `${scenario.id}:${step.id}:funding`);
  if (step.kind === "call" && step.id === "POSITION_FUND_TOKEN") exactArguments(step.args, [{ uint: "1000000000000000000" }], `${scenario.id}:${step.id}:funding`);
  if (step.kind === "call" && step.id === "POSITION_FUND_TOKEN_APPROVE") exactArguments(step.args, [{ ref: canonicalReference(scenario.id, scenario.form.templateId, "financeVault") }, { uint: "1000000000000000000" }], `${scenario.id}:${step.id}:approval`);
  if (step.kind === "call" && step.id === "POSITION_CLAIM_NATIVE") exactArguments(step.args, [{ uint: "0" }, { uint: "20000000000000000" }], `${scenario.id}:${step.id}:claim`);
  if (step.kind === "call" && step.id === "POSITION_CLAIM_TOKEN") exactArguments(step.args, [{ uint: "1" }, { uint: "2000000000000000000" }], `${scenario.id}:${step.id}:claim`);
  if (step.kind === "call" && step.id === "BUYBACK_FLOOR") {
    const buyback = configRecord(template.buyback);
    const threshold = configUint(buyback.threshold, `${scenario.id}:buyback.threshold`);
    const maxSpend = configUint(buyback.maxSpend, `${scenario.id}:buyback.maxSpend`);
    exactUintArgument(step.args[0], threshold < maxSpend ? threshold : maxSpend, `${scenario.id}:${step.id}:inputAmount`);
    if (configUint(step.args[1], `${scenario.id}:${step.id}:minimumOutput`) === 0n || !step.args[2] || typeof step.args[2] !== "object" || Array.isArray(step.args[2]) || !("uint" in step.args[2])) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:floor`);
  }
  if (step.kind === "call" && step.id === "BUYBACK_EXECUTE") {
    const floor = scenario.steps.find((candidate) => candidate.id === "BUYBACK_FLOOR");
    if (!floor || floor.kind !== "call" || canonicalValue(step.args[0]) !== canonicalValue(floor.args[1]) || !step.args[1] || typeof step.args[1] !== "object" || Array.isArray(step.args[1]) || !("uint" in step.args[1]) || configUint(step.args[1], `${scenario.id}:${step.id}:deadline`) > configUint(floor.args[2], `${scenario.id}:BUYBACK_FLOOR:expiry`)) {
      throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:floorBinding`);
    }
  }
  if (step.kind === "call" && (step.id === "FLAP_FAIL" || step.id === "FLAP_RETRY")) {
    const request = configRecord(step.args[0]);
    if (configUint(request.minimumPurchased, `${scenario.id}:${step.id}:minimumPurchased`) === 0n || configUint(request.protectionDuration, `${scenario.id}:${step.id}:protectionDuration`) !== configUint(template.protectionDuration, `${scenario.id}:protectionDuration`)) {
      throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:request`);
    }
    const poolKind = configUint(request.poolKind, `${scenario.id}:${step.id}:poolKind`);
    const poolAsset = request.poolAsset;
    if (poolKind !== 0n || canonicalValue(poolAsset) !== canonicalValue({ localAddress: "ZERO" })) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:poolAsset`);
    if (typeof request.salt !== "string" || !nonzeroHash.test(request.salt)) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:salt`);
    if (!request.deadline || typeof request.deadline !== "object" || Array.isArray(request.deadline) || !("uint" in request.deadline)) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:deadline`);
    const failure = scenario.steps.find((candidate) => candidate.id === "FLAP_FAIL");
    if (step.id === "FLAP_RETRY" && (!failure || failure.kind !== "call" || canonicalValue(failure.args) !== canonicalValue(step.args))) throw new Error(`CHAIN97_SCENARIO_ARGUMENT_INVALID:${scenario.id}:${step.id}:retryBinding`);
  }
  if (step.kind === "call" && ["CLAIM", "REFUND_ENABLE", "REFUND", "REWARD_CLAIM", "BUYBACK_FUND", "FLAP_RETRY"].includes(step.id) && step.id !== "FLAP_RETRY") {
    exactArguments(step.args, [], `${scenario.id}:${step.id}:noArguments`);
  }
  for (const probe of step.revertProbes ?? []) {
    if (probe.valueWei !== "0" && probe.name !== "proofRequired") throw new Error(`CHAIN97_SCENARIO_REVERT_PROBE_VALUE_INVALID:${scenario.id}:${step.id}:${probe.name}`);
    if (probe.name === "earlyExecution" && step.kind === "call" && canonicalValue(probe.args) !== canonicalValue(step.args)) throw new Error(`CHAIN97_SCENARIO_REVERT_PROBE_ARGUMENT_INVALID:${scenario.id}:${step.id}:${probe.name}`);
    if (probe.name === "thresholdNotMet") {
      exactUintArgument(probe.args[0], 1n, `${scenario.id}:${step.id}:thresholdProbeMinimum`);
      if (!probe.args[1] || typeof probe.args[1] !== "object" || Array.isArray(probe.args[1]) || !("uint" in probe.args[1])) throw new Error(`CHAIN97_SCENARIO_REVERT_PROBE_ARGUMENT_INVALID:${scenario.id}:${step.id}:${probe.name}`);
    }
    if (probe.name === "proofRequired") {
      exactUintArgument(probe.args[0], 1n, `${scenario.id}:${step.id}:probeShares`);
      if (BigInt(probe.valueWei) !== pricePerShare) throw new Error(`CHAIN97_SCENARIO_REVERT_PROBE_VALUE_INVALID:${scenario.id}:${step.id}:${probe.name}`);
    }
    if (probe.name === "overLimit") {
      const limitConfig = configRecord(scenario.form.templateConfig);
      const limits = limitConfig.maximumWalletBps;
      if (!Array.isArray(limits) || limits.length === 0) throw new Error(`CHAIN97_CANONICAL_CONFIG_VALUE_INVALID:${scenario.id}:maximumWalletBps`);
      const supply = configUint(common.supply, `${scenario.id}:supply`) * 1_000_000_000_000_000_000n;
      const amount = supply * configUint(limits[0], `${scenario.id}:maximumWalletBps.0`) / 10_000n + 1n;
      if (!probe.args[0] || typeof probe.args[0] !== "object" || Array.isArray(probe.args[0]) || !("ref" in probe.args[0]) || probe.args[0].ref !== "walletC") throw new Error(`CHAIN97_SCENARIO_REVERT_PROBE_ARGUMENT_INVALID:${scenario.id}:${step.id}:${probe.name}`);
      exactUintArgument(probe.args[1], amount, `${scenario.id}:${step.id}:probeAmount`);
    }
  }
}

export function validateChain97Plan(input: Chain97PlanInput, releaseCommit: string, selectedScenarioIds: readonly string[]): Chain97Plan {
  if (containsCredentialUrl(input)) throw new Error("CHAIN97_PLAN_CREDENTIAL_URL_FORBIDDEN");
  const parsed = planSchema.parse(input);
  const plan = parsed.releaseCommit === "self" ? { ...parsed, releaseCommit } : parsed;
  if (plan.releaseCommit.toLowerCase() !== releaseCommit.toLowerCase()) throw new Error("CHAIN97_PLAN_RELEASE_MISMATCH");
  assertUnique(plan.dependencies.map(({ name }) => name), "CHAIN97_DEPENDENCY_DUPLICATE");
  const dependencies = new Map(plan.dependencies.map((dependency) => [dependency.name, dependency]));
  const selectedManifests = selectedScenarioIds.map((id) => canonicalScenarioById.get(id)).filter((item) => item !== undefined);
  const requiredDependencyNames = new Set(selectedManifests.flatMap(({ requiredDependencies }) => [...requiredDependencies]));
  for (const name of requiredDependencyNames) {
    const dependency = dependencies.get(name);
    if (!dependency) throw new Error(`CHAIN97_DEPENDENCY_REQUIRED:${name}`);
    if (!nonzeroHash.test(dependency.codeHash)) throw new Error(`CHAIN97_DEPENDENCY_CODEHASH_INVALID:${name}`);
  }
  assertUnique(plan.scenarios.map(({ id }) => id), "CHAIN97_SCENARIO_DUPLICATE");
  const available = new Set(plan.scenarios.map(({ id }) => id));
  for (const id of selectedScenarioIds) if (!available.has(id)) throw new Error(`CHAIN97_SCENARIO_NOT_PLANNED:${id}`);
  assertUnique(plan.bootstrap.map(({ id }) => id), "CHAIN97_STEP_ID_DUPLICATE");
  for (const scenario of plan.scenarios) assertUnique(scenario.steps.map(({ id }) => id), `CHAIN97_STEP_ID_DUPLICATE:${scenario.id}`);
  const bootstrapTargets = new Set(plan.verificationTargets.map(({ address }) => address.ref));
  for (const step of plan.bootstrap) {
    if (step.kind === "deploy" && !bootstrapTargets.has(step.captureAddress)) {
      throw new Error(`CHAIN97_DEPLOYMENT_VERIFICATION_TARGET_MISSING:${step.captureAddress}`);
    }
  }
  const selected = plan.scenarios.filter(({ id }) => selectedScenarioIds.includes(id));
  const consumedRefs = new Set<string>();
  const manifests = new Map<string, ReturnType<typeof assertCanonicalLifecycle>>();
  for (const scenario of selected) {
    assertNoAddressLiterals(scenario.form, `${scenario.id}.form`);
    if (containsRelativeDeadline(scenario.form)) throw new Error(`CHAIN97_FORM_RELATIVE_DEADLINE_FORBIDDEN:${scenario.id}`);
    assertNoAddressLiterals(scenario.steps, `${scenario.id}.steps`);
    assertNoAddressLiterals(scenario.verificationTargets, `${scenario.id}.verificationTargets`);
    if (containsRelativeDeadline(scenario.steps) || containsRelativeDeadline(scenario.verificationTargets)) throw new Error(`CHAIN97_RELATIVE_DEADLINE_FORBIDDEN:${scenario.id}`);
    const manifest = assertCanonicalLifecycle(scenario);
    manifests.set(scenario.id, manifest);
    collectRefs(scenario, consumedRefs);
    for (const asset of manifest.requiredAssets) {
      if (!plan.assetRequirements.some((requirement) => requirement.asset.ref === asset && BigInt(requirement.minimumBalance) > 0n && BigInt(requirement.minimumAllowance) > 0n)) {
        throw new Error(`CHAIN97_ASSET_REQUIREMENT_MISSING:${scenario.id}:${asset}`);
      }
    }
  }
  assertNoAddressLiterals(plan.bootstrap, "bootstrap");
  assertNoAddressLiterals(plan.verificationTargets, "verificationTargets");
  if (containsRelativeDeadline(plan.bootstrap) || containsRelativeDeadline(plan.verificationTargets)) throw new Error("CHAIN97_RELATIVE_DEADLINE_FORBIDDEN:bootstrap");
  collectRefs(plan.bootstrap, consumedRefs);
  collectRefs(plan.verificationTargets, consumedRefs);
  collectRefs(plan.assetRequirements, consumedRefs);
  for (const [scenarioId, manifest] of manifests) {
    for (const dependency of manifest.requiredDependencies) {
      if (!consumedRefs.has(dependency)) throw new Error(`CHAIN97_DEPENDENCY_NOT_CONSUMED:${scenarioId}:${dependency}`);
    }
  }
  for (const dependency of plan.dependencies) {
    if (!consumedRefs.has(dependency.name)) throw new Error(`CHAIN97_DEPENDENCY_UNUSED:${dependency.name}`);
  }
  return plan;
}

export async function authorizeChain97Broadcast<Compiled, Senders>(input: {
  compile: () => Compiled;
  preflight: (compiled: Compiled) => Promise<void>;
  createSenders: (compiled: Compiled) => Senders;
}): Promise<{ compiled: Compiled; senders: Senders }> {
  const compiled = input.compile();
  await input.preflight(compiled);
  return { compiled, senders: input.createSenders(compiled) };
}

export function calculateChain97Budgets(plan: Chain97Plan, selectedScenarioIds: readonly string[], completedExecutionKeys: ReadonlySet<string> = new Set()): Record<WalletSlot, bigint> {
  const selected = new Set(selectedScenarioIds);
  const steps = [
    ...plan.bootstrap.map((step) => ({ key: `bootstrap:${step.id}`, step })),
    ...plan.scenarios.filter(({ id }) => selected.has(id)).flatMap((scenario) => scenario.steps.map((step) => ({ key: `${scenario.id}:${step.id}`, step }))),
  ].filter(({ key }) => !completedExecutionKeys.has(key)).map(({ step }) => step);
  const maxGasPrice = BigInt(plan.maxGasPriceWei);
  const budgets: Record<WalletSlot, bigint> = { A: 0n, B: 0n, C: 0n };
  for (const step of steps) budgets[step.wallet] += BigInt(step.valueWei) + BigInt(step.gasLimit) * maxGasPrice;
  return budgets;
}

export function assertChain97Budgets(budgets: Record<WalletSlot, bigint>, balances: Record<WalletSlot, bigint>): void {
  for (const slot of ["A", "B", "C"] as const) {
    if (balances[slot] < budgets[slot]) throw new Error(`CHAIN97_PREFLIGHT_BUDGET_INSUFFICIENT:${slot}`);
  }
}

export function redactChain97Error(error: unknown, env: RunnerEnvironment): string {
  let message = error instanceof Error ? error.message : "CHAIN97_EXECUTION_FAILED";
  const sensitive = Object.entries(env)
    .filter(([name, value]) => Boolean(value) && /PRIVATE_KEY|MNEMONIC|API_KEY|AUTH_TOKEN|RPC_(PRIMARY|SECONDARY)/i.test(name))
    .map(([, value]) => value!)
    .flatMap((value) => {
      const variants = new Set([value]);
      try {
        const url = new URL(value);
        variants.add(url.toString());
        variants.add(url.hostname);
        for (const segment of url.pathname.split("/").filter((item) => item.length > 2)) {
          variants.add(segment);
          try { variants.add(decodeURIComponent(segment)); } catch { /* invalid escape */ }
        }
        for (const item of url.searchParams.values()) variants.add(item);
      } catch { /* non-URL secret */ }
      return [...variants];
    })
    .filter((value) => value.length > 2)
    .sort((left, right) => right.length - left.length);
  for (const value of sensitive) message = message.split(value).join("[REDACTED]");
  return message
    .replace(/https?:\/\/[^\s)]+/gi, "[REDACTED_URL]")
    .replace(/https:\/\/[^/@\s]+@/gi, "https://[REDACTED]@")
    .replace(/([?&](?:api[-_]?key|access[-_]?token|auth|secret|token)=)[^&\s]+/gi, "$1[REDACTED]")
    .replace(/0x[0-9a-fA-F]{64}/g, "[REDACTED_HEX]");
}

export async function resolvePlanFile(repositoryRoot: string, configuredPath: string): Promise<string> {
  const [root, file] = await Promise.all([realpath(repositoryRoot), realpath(resolve(repositoryRoot, configuredPath))]);
  const relationship = relative(root, file);
  if (!relationship || relationship.startsWith("..") || resolve(root, relationship) !== file) throw new Error("CHAIN97_PLAN_PATH_OUTSIDE_REPOSITORY");
  return file;
}

async function runAcceptanceUnsafe(input: { scenarioIds: string[]; releaseCommit: string }) {
  const [{ stdout: repositoryOutput }, { stdout: headOutput }] = await Promise.all([
    execFile("git", ["rev-parse", "--show-toplevel"]),
    execFile("git", ["rev-parse", "HEAD"]),
  ]);
  const repositoryRoot = repositoryOutput.trim();
  const headCommit = headOutput.trim();
  const runtime = loadChain97Runtime(process.env, input.releaseCommit, headCommit);
  const planPath = await resolvePlanFile(repositoryRoot, runtime.planPath);
  let rawPlan: unknown;
  try {
    rawPlan = JSON.parse(await readFile(planPath, "utf8"));
  } catch {
    throw new Error("CHAIN97_PLAN_UNREADABLE");
  }
  const plan = validateChain97Plan(rawPlan as Chain97PlanInput, input.releaseCommit, input.scenarioIds);
  const { executeChain97Plan } = await import("./engine");
  return executeChain97Plan({
    plan,
    selectedScenarioIds: input.scenarioIds,
    releaseCommit: input.releaseCommit,
    runtime,
    env: process.env,
    repositoryRoot,
  });
}

export async function runAcceptance(input: { scenarioIds: string[]; releaseCommit: string }) {
  try {
    return await runAcceptanceUnsafe(input);
  } catch (error) {
    throw new Error(redactChain97Error(error, process.env));
  }
}
