import { concatHex, encodeDeployData, encodeFunctionData, keccak256, stringToHex, type AbiParameter, type Address, type Hex } from "viem";

import { encodeDeployment, templateOnchainIds, type DeploymentInput } from "@70x/protocol";
import type { FoundryArtifact } from "./artifacts";
import type { Chain97Plan, Chain97StepInput, PlanValue, WalletSlot } from "./executor";

type ReferenceScope = "global" | "bootstrap" | string;
type Provenance = {
  kind: "dependency" | "wallet" | "deploy" | "event" | "read";
  scope: ReferenceScope;
  availableAfterOrder?: number;
  executionKey?: string;
  event?: string;
  argument?: string;
  creation: boolean;
};
export type VerificationCreationProof = {
  executionKey: string;
  creationKind: "receipt" | "event";
  event?: string;
  argument?: string;
  sameTransactionConstructorRefs: string[];
};
export type CompiledChain97Plan = {
  planHash: `0x${string}`;
  forms: Map<string, DeploymentInput>;
  references: Map<string, Address>;
  provenance: Map<string, Provenance>;
  factoryDeployments: Map<string, { scenarioId: string; stepId: string; form: DeploymentInput }>;
  primaryFactoryDeploymentKeys: Map<string, string>;
  verificationProofs: Map<string, VerificationCreationProof>;
};

const ZERO = "0x0000000000000000000000000000000000000000" as Address;
const DEAD = "0x000000000000000000000000000000000000dEaD" as Address;
const canonical = (value: unknown): string => {
  if (typeof value === "bigint") return JSON.stringify(value.toString());
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
  return JSON.stringify(value);
};

const dummyAddress = (index: number) => `0x${index.toString(16).padStart(40, "0")}` as Address;

function materialize(value: PlanValue, references: Map<string, Address>, timestamp: bigint): unknown {
  if (Array.isArray(value)) return value.map((item) => materialize(item, references, timestamp));
  if (value && typeof value === "object") {
    if ("ref" in value && typeof value.ref === "string") {
      const resolved = references.get(value.ref);
      if (!resolved) throw new Error(`CHAIN97_PLAN_REFERENCE_MISSING:${value.ref}`);
      return resolved;
    }
    if ("uint" in value && typeof value.uint === "string") return BigInt(value.uint);
    if ("nowPlusSeconds" in value && typeof value.nowPlusSeconds === "number") return timestamp + BigInt(value.nowPlusSeconds);
    if ("localAddress" in value) return value.localAddress === "ZERO" ? ZERO : DEAD;
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, materialize(item, references, timestamp)]));
  }
  return value;
}

const artifact = (artifacts: Map<string, FoundryArtifact>, id: string) => {
  const item = artifacts.get(id);
  if (!item) throw new Error(`CHAIN97_ARTIFACT_NOT_LOADED:${id}`);
  return item;
};

const eventInput = (item: FoundryArtifact, event: string, argument: string) => {
  const abiEvent = item.abi.find((candidate): candidate is Extract<typeof candidate, { type: "event" }> => candidate.type === "event" && candidate.name === event);
  if (!abiEvent) throw new Error(`CHAIN97_EVENT_NOT_IN_ARTIFACT:${item.artifactId}:${event}`);
  const input = abiEvent.inputs.find((candidate) => candidate.name === argument);
  if (!input) throw new Error(`CHAIN97_EVENT_ARGUMENT_MISSING:${item.artifactId}:${event}:${argument}`);
  return input;
};

const isTypedAddress = (value: unknown) => Boolean(value && typeof value === "object" && (("ref" in value && typeof value.ref === "string") || ("localAddress" in value && (value.localAddress === "ZERO" || value.localAddress === "DEAD"))));

type RoleContext = { artifactId: string; provenance: Map<string, Provenance>; dependencyRoleUses: Set<string>; countDependencyUse: boolean };

const dependencyArtifacts: Record<string, ReadonlySet<string>> = {
  flapProtocol: new Set(["FlapAdapterV1"]),
  flapPoolAsset: new Set(["FlapAdapterV1", "FlapMintVault"]),
  bscUsdt: new Set(["FinanceVault", "RewardVault", "TimeWeightedRewardVault", "LpRewardVault", "HolderDeadRewardVault"]),
  canonicalLpToken: new Set(["LpRewardVault"]),
  externalBurnTarget: new Set<string>(),
  lpLockerAdapter: new Set(["PancakeV2Adapter", "BuybackLiquidityDeployer"]),
  pinkLocker: new Set(["PancakeV2Adapter", "BuybackLiquidityDeployer"]),
  targetCompatibilityRegistry: new Set(["BuybackVault", "BuybackTemplateBaseV1", "AutoBuybackTemplateV1", "TimedBuybackTemplateV1", "ExternalBurnTemplateV1"]),
  pancakeRouter: new Set(["PancakeV2Adapter", "BuybackLiquidityDeployer", "BuybackVault", "BuybackTemplateBaseV1", "AutoBuybackTemplateV1", "TimedBuybackTemplateV1", "ExternalBurnTemplateV1", "TaxRouter", "BuybackTaxProcessor"]),
  wbnb: new Set(["PancakeV2Adapter", "BuybackLiquidityDeployer", "BuybackVault", "BuybackTemplateBaseV1", "AutoBuybackTemplateV1", "TimedBuybackTemplateV1", "ExternalBurnTemplateV1", "TaxRouter", "BuybackTaxProcessor"]),
  pancakeFactory: new Set(["PancakeV2Adapter", "BuybackVault", "BuybackTemplateBaseV1", "AutoBuybackTemplateV1", "TimedBuybackTemplateV1", "ExternalBurnTemplateV1", "TaxRouter", "BuybackTaxProcessor"]),
};

function expectedDependencyRole(artifactId: string, parameterName: string, path: string): string | undefined {
  const normalized = parameterName.replace(/_$/, "").toLowerCase();
  const artifactName = artifactId.slice(artifactId.lastIndexOf("/") + 1);
  let role: string | undefined;
  if (artifactName === "FlapAdapterV1" && normalized === "protocol") role = "flapProtocol";
  else if ((artifactName === "FlapAdapterV1" && normalized === "allowedassets") || normalized === "poolasset") role = "flapPoolAsset";
  else if (normalized === "supportedtoken" || normalized === "rewardtoken") role = "bscUsdt";
  else if (normalized === "lptoken" || normalized === "expectedlptoken") role = "canonicalLpToken";
  else if (normalized === "targettoken") role = "externalBurnTarget";
  else if (normalized === "lpadapter") role = "lpLockerAdapter";
  else if (normalized === "locker") role = "pinkLocker";
  else if (normalized === "targetregistry") role = "targetCompatibilityRegistry";
  else if (normalized === "router" || /trusted\.router(?:\.|$)/i.test(path)) role = "pancakeRouter";
  else if (normalized === "wbnb" || /trusted\.wbnb(?:\.|$)/i.test(path)) role = "wbnb";
  else if (normalized === "pancakefactory" || /trusted\.factory(?:\.|$)/i.test(path)) role = "pancakeFactory";
  if (!role) return undefined;
  if (artifactId.startsWith("ProtocolForm.sol/")) return role;
  return dependencyArtifacts[role]?.has(artifactName) ? role : undefined;
}

function localAddressAllowed(parameterName: string, path: string, value: "ZERO" | "DEAD") {
  const normalized = parameterName.replace(/_$/, "").toLowerCase();
  if (value === "ZERO") return ["rewardtoken", "locker", "lpbeneficiary", "poolasset"].includes(normalized);
  return normalized === "recipient" || normalized === "to" || /\.transfer\./.test(path);
}

function assertFlapAdapterConstructor(artifactId: string, args: readonly unknown[]) {
  if (!artifactId.endsWith("/FlapAdapterV1")) return;
  if (!Array.isArray(args[1]) || args[1].length !== 0) throw new Error("CHAIN97_FLAP_ALLOWED_ASSETS_UNSUPPORTED");
}

function assertAddressRole(parameter: AbiParameter, value: unknown, path: string, context: RoleContext) {
  if (!value || typeof value !== "object") return;
  const name = parameter.name ?? path.slice(path.lastIndexOf(".") + 1);
  const expected = expectedDependencyRole(context.artifactId, name, path);
  if ("ref" in value && typeof value.ref === "string") {
    const source = context.provenance.get(value.ref);
    if (expected && source?.kind !== "dependency") throw new Error(`CHAIN97_DEPENDENCY_PROVENANCE_INVALID:${path}:${expected}:${source?.kind ?? "missing"}`);
    if (source?.kind !== "dependency") return;
    if (!expected) throw new Error(`CHAIN97_DEPENDENCY_ROLE_FORBIDDEN:${path}:${value.ref}`);
    if (value.ref !== expected) throw new Error(`CHAIN97_DEPENDENCY_ROLE_MISMATCH:${path}:${expected}:${value.ref}`);
    if (context.countDependencyUse) context.dependencyRoleUses.add(value.ref);
  } else if ("localAddress" in value && (value.localAddress === "ZERO" || value.localAddress === "DEAD")) {
    if (expected || !localAddressAllowed(name, path, value.localAddress)) throw new Error(`CHAIN97_LOCAL_ADDRESS_ROLE_FORBIDDEN:${path}`);
  }
}

function assertTypedAddressValue(parameter: AbiParameter, value: unknown, path: string, context: RoleContext): void {
  if (parameter.type === "address") {
    if (!isTypedAddress(value)) throw new Error(`CHAIN97_ADDRESS_ARGUMENT_REFERENCE_REQUIRED:${path}`);
    assertAddressRole(parameter, value, path, context);
    return;
  }
  if (parameter.type.endsWith("]")) {
    if (!Array.isArray(value)) return;
    const itemParameter = { ...parameter, type: parameter.type.replace(/\[[0-9]*\]$/, "") } as AbiParameter;
    value.forEach((item, index) => assertTypedAddressValue(itemParameter, item, `${path}.${index}`, context));
    return;
  }
  if (parameter.type === "tuple" && "components" in parameter && parameter.components) {
    parameter.components.forEach((component, index) => {
      const child = Array.isArray(value) ? value[index] : value && typeof value === "object" && component.name ? (value as Record<string, unknown>)[component.name] : undefined;
      assertTypedAddressValue(component, child, `${path}.${component.name || index}`, context);
    });
  }
}

function assertTypedAddressArguments(parameters: readonly AbiParameter[], values: readonly unknown[], path: string, context: RoleContext) {
  parameters.forEach((parameter, index) => assertTypedAddressValue(parameter, values[index], `${path}.${parameter.name || index}`, context));
}

function assertFormDependencyRoles(value: unknown, path: string, context: RoleContext): void {
  if (Array.isArray(value)) return value.forEach((item, index) => assertFormDependencyRoles(item, `${path}.${index}`, context));
  if (!value || typeof value !== "object") return;
  if ("ref" in value && typeof value.ref === "string") {
    const source = context.provenance.get(value.ref);
    const name = path.slice(path.lastIndexOf(".") + 1);
    const expected = expectedDependencyRole(context.artifactId, name, path);
    if (expected && source?.kind !== "dependency") throw new Error(`CHAIN97_DEPENDENCY_PROVENANCE_INVALID:${path}:${expected}:${source?.kind ?? "missing"}`);
    if (source?.kind !== "dependency") return;
    if (!expected) throw new Error(`CHAIN97_DEPENDENCY_ROLE_FORBIDDEN:${path}:${value.ref}`);
    if (expected !== value.ref) throw new Error(`CHAIN97_DEPENDENCY_ROLE_MISMATCH:${path}:${expected}:${value.ref}`);
    if (context.countDependencyUse) context.dependencyRoleUses.add(value.ref);
    return;
  }
  if ("localAddress" in value && (value.localAddress === "ZERO" || value.localAddress === "DEAD")) {
    const name = path.slice(path.lastIndexOf(".") + 1);
    const expected = expectedDependencyRole(context.artifactId, name, path);
    const optionalRewardToken = context.artifactId.startsWith("ProtocolForm.sol/") && name.toLowerCase() === "rewardtoken" && value.localAddress === "ZERO";
    if ((expected && !optionalRewardToken) || !localAddressAllowed(name, path, value.localAddress)) throw new Error(`CHAIN97_LOCAL_ADDRESS_ROLE_FORBIDDEN:${path}`);
    return;
  }
  for (const [key, item] of Object.entries(value)) assertFormDependencyRoles(item, `${path}.${key}`, context);
}

function assertReferenceAccess(
  value: unknown,
  path: string,
  consumerScope: ReferenceScope,
  consumerOrder: number,
  phase: "before" | "after",
  provenance: Map<string, Provenance>,
): void {
  if (Array.isArray(value)) return value.forEach((item, index) => assertReferenceAccess(item, `${path}.${index}`, consumerScope, consumerOrder, phase, provenance));
  if (!value || typeof value !== "object") return;
  if ("ref" in value && typeof value.ref === "string") {
    const source = provenance.get(value.ref);
    if (!source) throw new Error(`CHAIN97_PLAN_REFERENCE_MISSING:${value.ref}`);
    if (source.scope !== "global" && source.scope !== "bootstrap" && source.scope !== consumerScope) {
      throw new Error(`CHAIN97_REFERENCE_SCOPE_VIOLATION:${path}:${value.ref}`);
    }
    if (consumerScope === "bootstrap" && source.scope !== "global" && source.scope !== "bootstrap") {
      throw new Error(`CHAIN97_REFERENCE_SCOPE_VIOLATION:${path}:${value.ref}`);
    }
    if (source.availableAfterOrder !== undefined) {
      const inaccessible = phase === "before" ? source.availableAfterOrder >= consumerOrder : source.availableAfterOrder > consumerOrder;
      if (inaccessible) throw new Error(`CHAIN97_REFERENCE_ORDER_VIOLATION:${path}:${value.ref}`);
    }
    return;
  }
  for (const [key, item] of Object.entries(value)) assertReferenceAccess(item, `${path}.${key}`, consumerScope, consumerOrder, phase, provenance);
}

function assertVerificationConstructorAccess(
  value: unknown,
  path: string,
  consumerScope: ReferenceScope,
  creationOrder: number,
  creationExecutionKey: string,
  provenance: Map<string, Provenance>,
  sameTransactionRefs: Set<string>,
): void {
  if (Array.isArray(value)) {
    return value.forEach((item, index) => assertVerificationConstructorAccess(item, `${path}.${index}`, consumerScope, creationOrder, creationExecutionKey, provenance, sameTransactionRefs));
  }
  if (!value || typeof value !== "object") return;
  if ("ref" in value && typeof value.ref === "string") {
    const source = provenance.get(value.ref);
    if (!source) throw new Error(`CHAIN97_PLAN_REFERENCE_MISSING:${value.ref}`);
    if (source.scope !== "global" && source.scope !== "bootstrap" && source.scope !== consumerScope) {
      throw new Error(`CHAIN97_REFERENCE_SCOPE_VIOLATION:${path}:${value.ref}`);
    }
    if (consumerScope === "bootstrap" && source.scope !== "global" && source.scope !== "bootstrap") {
      throw new Error(`CHAIN97_REFERENCE_SCOPE_VIOLATION:${path}:${value.ref}`);
    }
    if (source.availableAfterOrder === undefined || source.availableAfterOrder < creationOrder) return;
    if (source.kind === "event" && source.creation && source.executionKey !== creationExecutionKey) {
      throw new Error(`CHAIN97_CREATION_GROUP_MISMATCH:${path}:${value.ref}`);
    }
    if (
      source.availableAfterOrder === creationOrder && source.executionKey === creationExecutionKey
      && source.kind === "event" && source.creation && source.event && source.argument
    ) {
      sameTransactionRefs.add(value.ref);
      return;
    }
    if (source.availableAfterOrder === creationOrder && source.executionKey === creationExecutionKey) {
      throw new Error(`CHAIN97_CREATION_GROUP_PROOF_INVALID:${path}:${value.ref}`);
    }
    throw new Error(`CHAIN97_REFERENCE_ORDER_VIOLATION:${path}:${value.ref}`);
  }
  for (const [key, item] of Object.entries(value)) {
    assertVerificationConstructorAccess(item, `${path}.${key}`, consumerScope, creationOrder, creationExecutionKey, provenance, sameTransactionRefs);
  }
}

function registerStepCaptures(
  step: Chain97StepInput,
  executionKey: string,
  scope: ReferenceScope,
  executionOrder: number,
  artifacts: Map<string, FoundryArtifact>,
  references: Map<string, Address>,
  provenance: Map<string, Provenance>,
  nextDummy: () => Address,
) {
  for (const capture of step.captures) {
    if (!step.requiredEvents.some(({ event }) => event === capture.event)) throw new Error(`CHAIN97_CAPTURE_EVENT_NOT_REQUIRED:${step.id}:${capture.event}`);
    const required = step.requiredEvents.find(({ event }) => event === capture.event)!;
    const input = eventInput(artifact(artifacts, required.artifact), capture.event, capture.argument);
    if (input.type !== "address") throw new Error(`CHAIN97_CAPTURE_NOT_ADDRESS:${step.id}:${capture.ref}`);
    if (references.has(capture.ref)) throw new Error(`CHAIN97_CAPTURE_DUPLICATE:${capture.ref}`);
    references.set(capture.ref, nextDummy());
    provenance.set(capture.ref, { kind: "event", scope, availableAfterOrder: executionOrder, executionKey, event: capture.event, argument: capture.argument, creation: capture.creation === true });
  }
}

function compileStep(
  step: Chain97StepInput,
  executionKey: string,
  scope: ReferenceScope,
  executionOrder: number,
  scenarioForm: DeploymentInput | undefined,
  artifacts: Map<string, FoundryArtifact>,
  references: Map<string, Address>,
  provenance: Map<string, Provenance>,
  dependencyRoleUses: Set<string>,
  nextDummy: () => Address,
) {
  const item = artifact(artifacts, step.artifact);
  const roleContext = { artifactId: item.artifactId, provenance, dependencyRoleUses, countDependencyUse: true };
  for (const required of step.requiredEvents) {
    const eventArtifact = artifact(artifacts, required.artifact);
    if (!eventArtifact.abi.some((candidate) => candidate.type === "event" && candidate.name === required.event)) {
      throw new Error(`CHAIN97_EVENT_NOT_IN_ARTIFACT:${required.artifact}:${required.event}`);
    }
    if (required.address) assertReferenceAccess(required.address, `${executionKey}.requiredEvent.${required.event}.address`, scope, executionOrder, "before", provenance);
  }
  try {
    if (step.kind === "deploy") {
      const constructor = item.abi.find((candidate): candidate is Extract<typeof candidate, { type: "constructor" }> => candidate.type === "constructor");
      assertReferenceAccess(step.constructorArgs, `${executionKey}.constructor`, scope, executionOrder, "before", provenance);
      assertTypedAddressArguments(constructor?.inputs ?? [], step.constructorArgs, `${executionKey}.constructor`, roleContext);
      assertFlapAdapterConstructor(item.artifactId, step.constructorArgs);
      encodeDeployData({ abi: item.abi, bytecode: item.bytecode, args: materialize(step.constructorArgs, references, 1_000_000n) as readonly unknown[] });
      if (references.has(step.captureAddress)) throw new Error(`CHAIN97_CAPTURE_DUPLICATE:${step.captureAddress}`);
      references.set(step.captureAddress, nextDummy());
      provenance.set(step.captureAddress, { kind: "deploy", scope, availableAfterOrder: executionOrder, executionKey, creation: true });
    } else if (step.kind === "factoryDeploy") {
      if (!scenarioForm) throw new Error(`CHAIN97_FACTORY_FORM_MISSING:${step.id}`);
      assertReferenceAccess(step.target, `${executionKey}.target`, scope, executionOrder, "before", provenance);
      const encoded = encodeDeployment(scenarioForm);
      encodeFunctionData({ abi: item.abi, functionName: "deploy", args: [templateOnchainIds[scenarioForm.templateId], scenarioForm.version, encoded.commonConfig, encoded.templateConfig] });
    } else {
      assertReferenceAccess(step.target, `${executionKey}.target`, scope, executionOrder, "before", provenance);
      const fn = item.abi.find((candidate): candidate is Extract<typeof candidate, { type: "function" }> => candidate.type === "function" && candidate.name === step.functionName);
      if (!fn) throw new Error(`CHAIN97_STEP_ABI_INVALID:${step.id}`);
      assertReferenceAccess(step.args, `${executionKey}.${step.functionName}`, scope, executionOrder, "before", provenance);
      assertTypedAddressArguments(fn.inputs, step.args, `${executionKey}.${step.functionName}`, roleContext);
      encodeFunctionData({ abi: item.abi, functionName: step.functionName, args: materialize(step.args, references, 1_000_000n) as readonly unknown[] });
    }
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("CHAIN97_")) throw error;
    throw new Error(`CHAIN97_STEP_ABI_INVALID:${step.id}`);
  }
  registerStepCaptures(step, executionKey, scope, executionOrder, artifacts, references, provenance, nextDummy);
  for (const read of step.reads) {
    try {
      assertReferenceAccess(read.target, `${executionKey}.read.${read.name}.target`, scope, executionOrder, "after", provenance);
      assertReferenceAccess(read.args, `${executionKey}.read.${read.name}`, scope, executionOrder, "after", provenance);
      const readArtifact = artifact(artifacts, read.artifact);
      const fn = readArtifact.abi.find((candidate): candidate is Extract<typeof candidate, { type: "function" }> => candidate.type === "function" && candidate.name === read.functionName);
      if (!fn) throw new Error("missing function");
      assertTypedAddressArguments(fn.inputs, read.args, `${executionKey}.read.${read.name}`, { artifactId: readArtifact.artifactId, provenance, dependencyRoleUses, countDependencyUse: false });
      encodeFunctionData({ abi: readArtifact.abi, functionName: read.functionName, args: materialize(read.args, references, 1_000_000n) as readonly unknown[] });
      if (read.captureRef) {
        if (fn.outputs.length !== 1 || fn.outputs[0]?.type !== "address") throw new Error("capture output");
        if (references.has(read.captureRef)) throw new Error(`CHAIN97_CAPTURE_DUPLICATE:${read.captureRef}`);
        references.set(read.captureRef, nextDummy());
        provenance.set(read.captureRef, { kind: "read", scope, availableAfterOrder: executionOrder, executionKey, creation: false });
      }
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("CHAIN97_")) throw error;
      throw new Error(`CHAIN97_READ_ABI_INVALID:${step.id}:${read.name}`);
    }
  }
  for (const probe of step.revertProbes ?? []) {
    assertReferenceAccess(probe.target, `${executionKey}.probe.${probe.name}.target`, scope, executionOrder, "after", provenance);
    assertReferenceAccess(probe.args, `${executionKey}.probe.${probe.name}`, scope, executionOrder, "after", provenance);
    const probeArtifact = artifact(artifacts, probe.artifact);
    const fn = probeArtifact.abi.find((candidate): candidate is Extract<typeof candidate, { type: "function" }> => candidate.type === "function" && candidate.name === probe.functionName);
    const errorArtifact = artifact(artifacts, probe.errorArtifact);
    if (!fn || !errorArtifact.abi.some((candidate) => candidate.type === "error" && candidate.name === probe.errorName)) throw new Error(`CHAIN97_REVERT_PROBE_ABI_INVALID:${executionKey}:${probe.name}`);
    assertTypedAddressArguments(fn.inputs, probe.args, `${executionKey}.probe.${probe.name}`, { artifactId: probeArtifact.artifactId, provenance, dependencyRoleUses, countDependencyUse: false });
    try { encodeFunctionData({ abi: probeArtifact.abi, functionName: probe.functionName, args: materialize(probe.args, references, 1_000_000n) as readonly unknown[] }); } catch { throw new Error(`CHAIN97_REVERT_PROBE_ABI_INVALID:${executionKey}:${probe.name}`); }
  }
}

function assertWhitelistProofBinding(scenario: Chain97Plan["scenarios"][number], walletB: Address) {
  if (scenario.id !== "whitelist-mint") return;
  const epoch = scenario.steps.find((step) => step.id === "WHITELIST_EPOCH");
  const mint = scenario.steps.find((step) => step.id === "WHITELIST_PROOF_MINT");
  if (!epoch || epoch.kind !== "call" || typeof epoch.args[0] !== "string" || !mint || mint.kind !== "call" || !Array.isArray(mint.args[2])) {
    throw new Error("CHAIN97_WHITELIST_PROOF_BINDING_INVALID");
  }
  let computed = keccak256(walletB);
  for (const sibling of mint.args[2]) {
    if (typeof sibling !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(sibling)) throw new Error("CHAIN97_WHITELIST_PROOF_BINDING_INVALID");
    const ordered = computed.toLowerCase() < sibling.toLowerCase() ? [computed, sibling as Hex] : [sibling as Hex, computed];
    computed = keccak256(concatHex(ordered));
  }
  if (computed.toLowerCase() !== epoch.args[0].toLowerCase()) throw new Error("CHAIN97_WHITELIST_PROOF_BINDING_INVALID");
}

export function compileChain97Plan(input: {
  plan: Chain97Plan;
  selectedScenarioIds: readonly string[];
  artifacts: Map<string, FoundryArtifact>;
  walletAddresses: Record<WalletSlot, Address>;
}): CompiledChain97Plan {
  const selected = new Set(input.selectedScenarioIds);
  const executionSteps = new Map<string, Chain97StepInput>();
  const executionOrder = new Map<string, number>();
  let order = 0;
  for (const step of input.plan.bootstrap) {
    executionSteps.set(`bootstrap:${step.id}`, step);
    executionOrder.set(`bootstrap:${step.id}`, order++);
  }
  for (const scenario of input.plan.scenarios.filter(({ id }) => selected.has(id))) {
    for (const step of scenario.steps) {
      executionSteps.set(`${scenario.id}:${step.id}`, step);
      executionOrder.set(`${scenario.id}:${step.id}`, order++);
    }
  }
  const references = new Map<string, Address>();
  const provenance = new Map<string, Provenance>();
  for (const dependency of input.plan.dependencies) {
    references.set(dependency.name, dependency.address as Address);
    provenance.set(dependency.name, { kind: "dependency", scope: "global", creation: false });
  }
  for (const slot of ["A", "B", "C"] as const) {
    references.set(`wallet${slot}`, input.walletAddresses[slot]);
    provenance.set(`wallet${slot}`, { kind: "wallet", scope: "global", creation: false });
  }
  let dummy = 1;
  const nextDummy = () => dummyAddress(dummy++);
  const dependencyRoleUses = new Set<string>();
  for (const step of input.plan.bootstrap) {
    const executionKey = `bootstrap:${step.id}`;
    compileStep(step, executionKey, "bootstrap", executionOrder.get(executionKey)!, undefined, input.artifacts, references, provenance, dependencyRoleUses, nextDummy);
  }

  const forms = new Map<string, DeploymentInput>();
  const factoryDeployments = new Map<string, { scenarioId: string; stepId: string; form: DeploymentInput }>();
  const primaryFactoryDeploymentKeys = new Map<string, string>();
  for (const scenario of input.plan.scenarios.filter(({ id }) => selected.has(id))) {
    assertWhitelistProofBinding(scenario, input.walletAddresses.B);
    let form: DeploymentInput;
    try {
      const firstStepOrder = executionOrder.get(`${scenario.id}:${scenario.steps[0]?.id}`);
      if (firstStepOrder === undefined) throw new Error(`CHAIN97_PRIMARY_FACTORY_DEPLOYMENT_MISSING:${scenario.id}`);
      assertReferenceAccess(scenario.form, `${scenario.id}.form`, scenario.id, firstStepOrder, "before", provenance);
      assertFormDependencyRoles(scenario.form, `${scenario.id}.form`, { artifactId: `ProtocolForm.sol/${scenario.form.templateId}`, provenance, dependencyRoleUses, countDependencyUse: true });
      form = materialize(scenario.form as unknown as PlanValue, references, 1_000_000n) as DeploymentInput;
      encodeDeployment(form);
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("CHAIN97_")) throw error;
      throw new Error(`CHAIN97_FORM_INVALID:${scenario.id}`);
    }
    forms.set(scenario.id, form);
    for (const step of scenario.steps) {
      const executionKey = `${scenario.id}:${step.id}`;
      compileStep(step, executionKey, scenario.id, executionOrder.get(executionKey)!, form, input.artifacts, references, provenance, dependencyRoleUses, nextDummy);
      if (step.kind === "factoryDeploy") factoryDeployments.set(executionKey, { scenarioId: scenario.id, stepId: step.id, form });
    }
    const primaryKey = `${scenario.id}:DEPLOY`;
    if (!factoryDeployments.has(primaryKey)) throw new Error(`CHAIN97_PRIMARY_FACTORY_DEPLOYMENT_MISSING:${scenario.id}`);
    primaryFactoryDeploymentKeys.set(scenario.id, primaryKey);
    const projectProvenance = provenance.get(scenario.indexProjectRef);
    if (projectProvenance?.kind !== "event" || projectProvenance.event !== "ProjectDeployed" || projectProvenance.executionKey !== primaryKey) {
      throw new Error(`CHAIN97_INDEX_PROJECT_PROVENANCE_INVALID:${scenario.id}`);
    }
  }

  const selectedTargets = [
    ...input.plan.verificationTargets.map((target) => ({ target, scope: "bootstrap" })),
    ...input.plan.scenarios.filter(({ id }) => selected.has(id)).flatMap(({ id, verificationTargets }) => verificationTargets.map((target) => ({ target, scope: id }))),
  ];
  const targetRefs = new Set<string>();
  const targetNames = new Set<string>();
  const verificationProofs = new Map<string, VerificationCreationProof>();
  for (const { target, scope } of selectedTargets) {
    if (targetNames.has(target.name)) throw new Error(`CHAIN97_VERIFICATION_NAME_DUPLICATE:${target.name}`);
    targetNames.add(target.name);
    if (targetRefs.has(target.address.ref)) throw new Error(`CHAIN97_VERIFICATION_TARGET_DUPLICATE:${target.address.ref}`);
    targetRefs.add(target.address.ref);
    const source = provenance.get(target.address.ref);
    if (!source?.creation || source.executionKey !== `${scope}:${target.creationTransaction}`) throw new Error(`CHAIN97_CREATION_PROVENANCE_MISMATCH:${target.name}`);
    try {
      const creationOrder = executionOrder.get(source.executionKey);
      if (creationOrder === undefined) throw new Error(`CHAIN97_CREATION_PROVENANCE_MISMATCH:${target.name}`);
      const sameTransactionConstructorRefs = new Set<string>();
      assertVerificationConstructorAccess(target.constructorArgs, `${scope}:${target.name}.verificationConstructor`, scope, creationOrder, source.executionKey, provenance, sameTransactionConstructorRefs);
      const creationStep = executionSteps.get(source.executionKey);
      if (source.kind === "deploy" && (
        creationStep?.kind !== "deploy" || creationStep.artifact !== target.artifact
        || canonical(creationStep.constructorArgs) !== canonical(target.constructorArgs)
      )) {
        throw new Error(`CHAIN97_DIRECT_CREATION_PLAN_MISMATCH:${target.name}`);
      }
      const targetArtifact = artifact(input.artifacts, target.artifact);
      const constructor = targetArtifact.abi.find((candidate): candidate is Extract<typeof candidate, { type: "constructor" }> => candidate.type === "constructor");
      assertTypedAddressArguments(constructor?.inputs ?? [], target.constructorArgs, `${scope}:${target.name}.verificationConstructor`, { artifactId: targetArtifact.artifactId, provenance, dependencyRoleUses, countDependencyUse: false });
      assertFlapAdapterConstructor(targetArtifact.artifactId, target.constructorArgs);
      encodeDeployData({ abi: targetArtifact.abi, bytecode: targetArtifact.bytecode, args: materialize(target.constructorArgs, references, 1_000_000n) as readonly unknown[] });
      verificationProofs.set(target.name, source.kind === "deploy"
        ? { executionKey: source.executionKey, creationKind: "receipt", sameTransactionConstructorRefs: [...sameTransactionConstructorRefs] }
        : { executionKey: source.executionKey, creationKind: "event", event: source.event!, argument: source.argument!, sameTransactionConstructorRefs: [...sameTransactionConstructorRefs] });
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("CHAIN97_")) throw error;
      throw new Error(`CHAIN97_VERIFICATION_CONSTRUCTOR_INVALID:${target.name}`);
    }
  }
  for (const [ref, source] of provenance) {
    if (source.creation && !targetRefs.has(ref)) throw new Error(`CHAIN97_DEPLOYMENT_VERIFICATION_TARGET_MISSING:${ref}`);
  }
  const assetKeys = new Set<string>();
  const coveredFundingKeys = new Set<string>();
  for (const requirement of input.plan.assetRequirements) {
    const activeFundingKeys = requirement.fundingExecutionKeys.filter((executionKey) => executionSteps.has(executionKey));
    if (activeFundingKeys.length === 0) continue;
    if (activeFundingKeys.length !== requirement.fundingExecutionKeys.length) throw new Error(`CHAIN97_ASSET_FUNDING_SCOPE_INVALID:${requirement.asset.ref}`);
    if (!provenance.has(requirement.asset.ref) || !provenance.has(requirement.spender.ref)) throw new Error(`CHAIN97_ASSET_REFERENCE_INVALID:${requirement.asset.ref}`);
    const assetKey = `${requirement.asset.ref}:${requirement.wallet}:${requirement.spender.ref}`;
    if (assetKeys.has(assetKey)) throw new Error(`CHAIN97_ASSET_REQUIREMENT_DUPLICATE:${assetKey}`);
    assetKeys.add(assetKey);
    const minimumBalance = BigInt(requirement.minimumBalance);
    const minimumAllowance = BigInt(requirement.minimumAllowance);
    if (minimumBalance < 1_000_000_000_000_000_000n || minimumAllowance !== minimumBalance) throw new Error(`CHAIN97_ASSET_CANONICAL_MINIMUM_INVALID:${assetKey}`);
    let actualFunding = 0n;
    let firstFundingOrder = Number.POSITIVE_INFINITY;
    for (const executionKey of activeFundingKeys) {
      coveredFundingKeys.add(executionKey);
      const step = executionSteps.get(executionKey);
      const stepOrder = executionOrder.get(executionKey);
      if (step?.kind === "call" && step.target.ref !== requirement.spender.ref) throw new Error(`CHAIN97_ASSET_SPENDER_MISMATCH:${executionKey}`);
      if (!step || step.kind !== "call" || step.wallet !== requirement.wallet || !["fundRewards", "fundToken", "openToken"].includes(step.functionName)) {
        throw new Error(`CHAIN97_ASSET_FUNDING_BINDING_INVALID:${executionKey}`);
      }
      const amount = step.args[0];
      if (!amount || typeof amount !== "object" || !("uint" in amount) || typeof amount.uint !== "string") throw new Error(`CHAIN97_ASSET_FUNDING_AMOUNT_INVALID:${executionKey}`);
      actualFunding += BigInt(amount.uint);
      firstFundingOrder = Math.min(firstFundingOrder, stepOrder!);
    }
    if (actualFunding !== minimumBalance) throw new Error(`CHAIN97_ASSET_FUNDING_AMOUNT_MISMATCH:${assetKey}`);
    const spenderSource = provenance.get(requirement.spender.ref)!;
    if (requirement.approvalExecutionKey) {
      const approval = executionSteps.get(requirement.approvalExecutionKey);
      const approvalOrder = executionOrder.get(requirement.approvalExecutionKey);
      if (
        !approval || approval.kind !== "call" || approval.wallet !== requirement.wallet || approval.target.ref !== requirement.asset.ref || approval.functionName !== "approve"
        || approval.args.length !== 2 || !approval.args[0] || typeof approval.args[0] !== "object" || !("ref" in approval.args[0]) || approval.args[0].ref !== requirement.spender.ref
        || !approval.args[1] || typeof approval.args[1] !== "object" || !("uint" in approval.args[1]) || approval.args[1].uint !== minimumAllowance.toString()
        || approvalOrder === undefined || approvalOrder >= firstFundingOrder
        || (spenderSource.executionKey && (executionOrder.get(spenderSource.executionKey) ?? Number.POSITIVE_INFINITY) >= approvalOrder)
      ) throw new Error(`CHAIN97_ASSET_APPROVAL_BINDING_INVALID:${requirement.approvalExecutionKey}`);
    } else if (spenderSource.creation) {
      throw new Error(`CHAIN97_ASSET_APPROVAL_REQUIRED:${requirement.spender.ref}`);
    }
  }
  for (const [executionKey, step] of executionSteps) {
    if (step.kind === "call" && ["fundRewards", "fundToken", "openToken"].includes(step.functionName) && !coveredFundingKeys.has(executionKey)) {
      throw new Error(`CHAIN97_ASSET_FUNDING_REQUIREMENT_MISSING:${executionKey}`);
    }
  }
  for (const dependency of input.plan.dependencies) {
    if (!dependencyRoleUses.has(dependency.name)) throw new Error(`CHAIN97_DEPENDENCY_ROLE_UNUSED:${dependency.name}`);
  }
  return { planHash: keccak256(stringToHex(canonical(input.plan))), forms, references, provenance, factoryDeployments, primaryFactoryDeploymentKeys, verificationProofs };
}

export function compileNoncePlan(
  plan: Chain97Plan,
  selectedScenarioIds: readonly string[],
  startingNonces: Record<WalletSlot, number>,
  completedExecutionKeys: ReadonlySet<string> = new Set(),
) {
  const selected = new Set(selectedScenarioIds);
  const output = new Map<string, number>();
  const next = { ...startingNonces };
  const add = (executionKey: string, step: Chain97StepInput) => {
    if (completedExecutionKeys.has(executionKey)) return;
    if (!Number.isSafeInteger(next[step.wallet]) || next[step.wallet] < 0) throw new Error(`CHAIN97_NONCE_INVALID:${step.wallet}`);
    output.set(executionKey, next[step.wallet]++);
  };
  plan.bootstrap.forEach((step) => add(`bootstrap:${step.id}`, step));
  plan.scenarios.filter(({ id }) => selected.has(id)).forEach((scenario) => scenario.steps.forEach((step) => add(`${scenario.id}:${step.id}`, step)));
  return output;
}
