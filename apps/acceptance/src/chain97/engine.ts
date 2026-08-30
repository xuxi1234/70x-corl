import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  decodeErrorResult,
  decodeFunctionResult,
  decodeFunctionData,
  encodeDeployData,
  encodeFunctionData,
  getContractAddress,
  http,
  keccak256,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  type TransactionReceipt,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { bscTestnet } from "viem/chains";
import { relative, resolve } from "node:path";
import { access, constants } from "node:fs/promises";
import { dirname } from "node:path";

import {
  decodeProjectConfig,
  encodeDeployment,
  templateOnchainIds,
  type DecodedProjectConfig,
  type DeploymentInput,
} from "@70x/protocol";
import { compareConfig } from "../rpc-compare";
import type { EvidenceBundle, EvidenceReceipt, EvidenceTransaction } from "../evidence";
import { preflightChain97, resolveChain97Rpcs, type Chain97Provider } from "../preflight";
import { loadFoundryArtifact, type FoundryArtifact } from "./artifacts";
import {
  authorizeChain97Broadcast,
  assertChain97Budgets,
  calculateChain97Budgets,
  type Chain97Plan,
  type Chain97Runtime,
  type Chain97StepInput,
  type Chain97VerificationTargetInput,
  type PlanValue,
  type WalletSlot,
} from "./executor";
import { compileChain97Plan, compileNoncePlan, type CompiledChain97Plan, type VerificationCreationProof } from "./compiler";
import { createCheckpoint, loadCheckpoint, saveCheckpoint, type Chain97Checkpoint, type Chain97CheckpointEntry } from "./checkpoint";
import { preflightVerificationServices, verifyDeployedContract } from "./verification";

type RunnerEnvironment = Record<string, string | undefined>;
type ReferenceMap = Map<string, unknown>;
type FactoryEncoding = ReturnType<typeof encodeFactoryDeployment>;
type RpcPair = { primary: PublicClient; secondary: PublicClient; primaryProvider: Chain97Provider; secondaryProvider: Chain97Provider };
type Accounts = Record<WalletSlot, PrivateKeyAccount>;
type Wallets = Record<WalletSlot, { account: PrivateKeyAccount; client: WalletClient }>;
type StepResult = { transaction: EvidenceTransaction; snapshot: EvidenceBundle["rpcSnapshots"][number]; nonce: number };
type HistoricalAssetObservation = Pick<StepResult, "transaction" | "snapshot">;

const privateKeyPattern = /^0x[0-9a-fA-F]{64}$/;
const publicAddress = /^0x[0-9a-fA-F]{40}$/;

export function assertAssetPreflight(
  actual: { balance: bigint; allowance: bigint },
  required: { minimumBalance: bigint; minimumAllowance: bigint },
  label: string,
) {
  if (actual.balance < required.minimumBalance) throw new Error(`CHAIN97_ASSET_BALANCE_INSUFFICIENT:${label}`);
  if (actual.allowance !== required.minimumAllowance) {
    throw new Error(`CHAIN97_ASSET_ALLOWANCE_MISMATCH:${label}:${required.minimumAllowance}:${actual.allowance}`);
  }
}

export function calculateRemainingAssetFunding(
  fundingExecutionKeys: readonly string[],
  completedExecutionKeys: ReadonlySet<string>,
  stepsByExecutionKey: ReadonlyMap<string, Chain97StepInput>,
): bigint {
  return fundingExecutionKeys.filter((executionKey) => !completedExecutionKeys.has(executionKey)).reduce((sum, executionKey) => {
    const step = stepsByExecutionKey.get(executionKey);
    const value = step?.kind === "call" ? step.args[0] : undefined;
    if (!value || typeof value !== "object" || Array.isArray(value) || !("uint" in value)) {
      throw new Error(`CHAIN97_ASSET_FUNDING_AMOUNT_INVALID:${executionKey}`);
    }
    return sum + BigInt(String(value.uint));
  }, 0n);
}

const checkpointAssetUint = (value: unknown, executionKey: string, field: string): bigint => {
  if (typeof value === "bigint" && value >= 0n) return value;
  if (typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value)) return BigInt(value);
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return BigInt(value);
  throw new Error(`CHAIN97_CHECKPOINT_ASSET_VALUE_INVALID:${executionKey}:${field}`);
};

function assertHistoricalAssetRequirement(input: {
  requirement: Chain97Plan["assetRequirements"][number];
  orderedFundingKeys: readonly string[];
  completedExecutionKeys: ReadonlySet<string>;
  stepsByExecutionKey: ReadonlyMap<string, Chain97StepInput>;
  historicalResults: ReadonlyMap<string, HistoricalAssetObservation>;
  asset: Address;
  spender: Address | undefined;
  owner: Address;
}) {
  const { requirement } = input;
  const approvalKey = requirement.approvalExecutionKey;
  const completedFundingKeys = input.orderedFundingKeys.filter((executionKey) => input.completedExecutionKeys.has(executionKey));
  if (completedFundingKeys.length > 0 && (!approvalKey || !input.completedExecutionKeys.has(approvalKey))) {
    throw new Error(`CHAIN97_CHECKPOINT_ASSET_APPROVAL_MISSING:${requirement.asset.ref}`);
  }
  if (approvalKey && input.completedExecutionKeys.has(approvalKey)) {
    const observation = input.historicalResults.get(approvalKey);
    if (!observation) throw new Error(`CHAIN97_CHECKPOINT_ASSET_OBSERVATION_MISSING:${approvalKey}`);
    if (canonical(observation.snapshot.primary) !== canonical(observation.snapshot.secondary)) {
      throw new Error(`CHAIN97_CHECKPOINT_ASSET_RPC_DIVERGENCE:${approvalKey}`);
    }
    const expected = BigInt(requirement.minimumAllowance);
    const observedAllowance = checkpointAssetUint(observation.snapshot.primary.allowance, approvalKey, "allowance");
    const approval = observation.transaction.decodedEvents.find((event) => event.name === "Approval" && event.address.toLowerCase() === input.asset.toLowerCase());
    const amount = approval?.args.amount;
    if (
      !approval || !input.spender
      || String(approval.args.owner ?? "").toLowerCase() !== input.owner.toLowerCase()
      || String(approval.args.spender ?? "").toLowerCase() !== input.spender.toLowerCase()
      || checkpointAssetUint(amount, approvalKey, "amount") !== expected
      || observedAllowance !== expected
    ) throw new Error(`CHAIN97_CHECKPOINT_ASSET_APPROVAL_INVALID:${approvalKey}`);
  }
  for (let index = 0; index < input.orderedFundingKeys.length; index += 1) {
    const executionKey = input.orderedFundingKeys[index]!;
    if (!input.completedExecutionKeys.has(executionKey)) continue;
    const observation = input.historicalResults.get(executionKey);
    if (!observation) throw new Error(`CHAIN97_CHECKPOINT_ASSET_OBSERVATION_MISSING:${executionKey}`);
    if (canonical(observation.snapshot.primary) !== canonical(observation.snapshot.secondary)) {
      throw new Error(`CHAIN97_CHECKPOINT_ASSET_RPC_DIVERGENCE:${executionKey}`);
    }
    const expected = calculateRemainingAssetFunding(input.orderedFundingKeys.slice(index + 1), new Set(), input.stepsByExecutionKey);
    const actual = checkpointAssetUint(observation.snapshot.primary.remainingAllowance, executionKey, "remainingAllowance");
    if (actual !== expected) throw new Error(`CHAIN97_CHECKPOINT_ASSET_ALLOWANCE_MISMATCH:${executionKey}:${expected}:${actual}`);
  }
}

export async function assertCanonicalBlock(
  client: Pick<PublicClient, "getBlock">,
  blockNumber: bigint,
  expectedHash: Hex,
  provider: string,
): Promise<void> {
  const block = await client.getBlock({ blockNumber });
  if (!block.hash || block.hash.toLowerCase() !== expectedHash.toLowerCase()) throw new Error(`CHAIN97_REORG_DETECTED:${provider}`);
}

const jsonSafe = (value: unknown): unknown => {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, jsonSafe(item)]));
  return value;
};

const canonical = (value: unknown): string => {
  if (typeof value === "bigint") return JSON.stringify(value.toString());
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
  return JSON.stringify(value);
};

export function resolvePlanValue(value: PlanValue, references: ReferenceMap, chainTimestamp: bigint): unknown {
  if (Array.isArray(value)) return value.map((item) => resolvePlanValue(item, references, chainTimestamp));
  if (value && typeof value === "object") {
    if ("ref" in value && typeof value.ref === "string") {
      if (!references.has(value.ref)) throw new Error(`CHAIN97_PLAN_REFERENCE_MISSING:${value.ref}`);
      return references.get(value.ref);
    }
    if ("uint" in value && typeof value.uint === "string") return BigInt(value.uint);
    if ("nowPlusSeconds" in value && typeof value.nowPlusSeconds === "number") return chainTimestamp + BigInt(value.nowPlusSeconds);
    if ("localAddress" in value) return value.localAddress === "ZERO"
      ? "0x0000000000000000000000000000000000000000"
      : "0x000000000000000000000000000000000000dEaD";
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, resolvePlanValue(item, references, chainTimestamp)]));
  }
  return value;
}

export function encodeFactoryDeployment(form: DeploymentInput, factoryAbi: Abi) {
  const encoded = encodeDeployment(form);
  const templateOnchainId = templateOnchainIds[form.templateId];
  const data = encodeFunctionData({
    abi: factoryAbi,
    functionName: "deploy",
    args: [templateOnchainId, form.version, encoded.commonConfig, encoded.templateConfig],
  });
  return {
    ...encoded,
    templateOnchainId,
    data,
    normalizedConfig: decodeProjectConfig(form.templateId, form.version, encoded.commonConfig, encoded.templateConfig),
  };
}

export function selectPrimaryFactoryDeployment<T>(
  compiled: Pick<CompiledChain97Plan, "primaryFactoryDeploymentKeys">,
  scenarioId: string,
  deployments: ReadonlyMap<string, T>,
): T {
  const executionKey = compiled.primaryFactoryDeploymentKeys.get(scenarioId);
  const deployment = executionKey ? deployments.get(executionKey) : undefined;
  if (!deployment) throw new Error(`CHAIN97_PRIMARY_FACTORY_DEPLOYMENT_MISSING:${scenarioId}`);
  return deployment;
}

export function resolveVerificationCreationProvenance(input: {
  targetName: string;
  address: string;
  proof: VerificationCreationProof;
  transaction: { receipt: Pick<EvidenceReceipt, "contractAddress">; decodedEvents: EvidenceTransaction["decodedEvents"] };
  transactionTo: string | null;
}): { creationKind: "receipt" | "event"; creationLocator: string } {
  if (input.proof.creationKind === "receipt") {
    if (input.transaction.receipt.contractAddress?.toLowerCase() !== input.address.toLowerCase() || input.transactionTo !== null) {
      throw new Error(`CHAIN97_DIRECT_CREATION_INPUT_MISMATCH:${input.targetName}`);
    }
    return { creationKind: "receipt", creationLocator: "receipt.contractAddress" };
  }
  const { event, argument } = input.proof;
  const binding = event && argument ? input.transaction.decodedEvents.find((item) => {
    const value = item.name === event ? item.args[argument] : undefined;
    return typeof value === "string" && value.toLowerCase() === input.address.toLowerCase();
  }) : undefined;
  if (!binding || input.transactionTo === null) throw new Error(`CHAIN97_FACTORY_CREATION_EVENT_MISMATCH:${input.targetName}`);
  return { creationKind: "event", creationLocator: `${event}.${argument}` };
}

const requiredPrivateKey = (env: RunnerEnvironment, slot: WalletSlot) => {
  const name = `CHAIN97_PRIVATE_KEY_${slot}`;
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name}_MISSING`);
  if (!privateKeyPattern.test(value)) throw new Error(`${name}_INVALID`);
  return value as Hex;
};

const createAccounts = (env: RunnerEnvironment): Accounts => Object.fromEntries(
  (["A", "B", "C"] as const).map((slot) => {
    const account = privateKeyToAccount(requiredPrivateKey(env, slot));
    return [slot, account];
  }),
) as unknown as Accounts;

const createWallets = (accounts: Accounts, rpcEndpoint: string): Wallets => Object.fromEntries(
  (["A", "B", "C"] as const).map((slot) => [slot, {
    account: accounts[slot],
    client: createWalletClient({ account: accounts[slot], chain: bscTestnet, transport: http(rpcEndpoint) }),
  }]),
) as unknown as Wallets;

const createRpcPair = (env: RunnerEnvironment): RpcPair => {
  const endpoints = resolveChain97Rpcs(env);
  return {
    primary: createPublicClient({ chain: bscTestnet, transport: http(endpoints.primary.endpoint) }),
    secondary: createPublicClient({ chain: bscTestnet, transport: http(endpoints.secondary.endpoint) }),
    primaryProvider: endpoints.primary.provider,
    secondaryProvider: endpoints.secondary.provider,
  };
};

const allSteps = (plan: Chain97Plan, selected: ReadonlySet<string>) => [
  ...plan.bootstrap,
  ...plan.scenarios.filter(({ id }) => selected.has(id)).flatMap(({ steps }) => steps),
];

async function loadRequiredArtifacts(plan: Chain97Plan, selected: ReadonlySet<string>, repositoryRoot: string) {
  const ids = new Set<string>();
  const selectedScenarios = plan.scenarios.filter(({ id }) => selected.has(id));
  for (const step of allSteps(plan, selected)) {
    ids.add(step.artifact);
    step.requiredEvents.forEach(({ artifact }) => ids.add(artifact));
    step.reads.forEach(({ artifact }) => ids.add(artifact));
    step.revertProbes?.forEach(({ artifact, errorArtifact }) => { ids.add(artifact); ids.add(errorArtifact); });
  }
  [...plan.verificationTargets, ...selectedScenarios.flatMap(({ verificationTargets }) => verificationTargets)].forEach(({ artifact }) => ids.add(artifact));
  const entries = await Promise.all([...ids].map(async (id) => [id, await loadFoundryArtifact(id, repositoryRoot)] as const));
  return new Map(entries);
}

async function canonicalRpcRequest(client: PublicClient, method: "eth_getCode" | "eth_call", first: unknown, blockHash: Hex): Promise<Hex> {
  try {
    return await client.request({ method, params: [first, { blockHash, requireCanonical: true }] } as never) as Hex;
  } catch { throw new Error(`CHAIN97_EIP1898_UNSUPPORTED:${method}`); }
}

async function preflightDependencies(plan: Chain97Plan, rpc: RpcPair) {
  const [primaryHeight, secondaryHeight] = await Promise.all([rpc.primary.getBlockNumber(), rpc.secondary.getBlockNumber()]);
  const minimumHeight = primaryHeight < secondaryHeight ? primaryHeight : secondaryHeight;
  const blockNumber = minimumHeight - BigInt(plan.confirmations - 1);
  if (blockNumber <= 0n) throw new Error("CHAIN97_FINALIZED_BLOCK_UNAVAILABLE");
  const [primaryBlock, secondaryBlock] = await Promise.all([
    rpc.primary.getBlock({ blockNumber }),
    rpc.secondary.getBlock({ blockNumber }),
  ]);
  if (primaryBlock.hash.toLowerCase() !== secondaryBlock.hash.toLowerCase()) throw new Error("CHAIN97_FINALIZED_BLOCK_DIVERGENCE");
  if (primaryBlock.gasLimit !== secondaryBlock.gasLimit) throw new Error("CHAIN97_FINALIZED_GAS_LIMIT_DIVERGENCE");
  for (const dependency of plan.dependencies) {
    const address = dependency.address as Address;
    const [primaryCode, secondaryCode] = await Promise.all([
      canonicalRpcRequest(rpc.primary, "eth_getCode", address, primaryBlock.hash),
      canonicalRpcRequest(rpc.secondary, "eth_getCode", address, secondaryBlock.hash),
    ]);
    if (!primaryCode || !secondaryCode || primaryCode.toLowerCase() !== secondaryCode.toLowerCase() || keccak256(primaryCode).toLowerCase() !== dependency.codeHash.toLowerCase()) {
      throw new Error(`CHAIN97_DEPENDENCY_CODE_MISMATCH:${dependency.name}`);
    }
  }
  await Promise.all([
    assertCanonicalBlock(rpc.primary, blockNumber, primaryBlock.hash, "primary"),
    assertCanonicalBlock(rpc.secondary, blockNumber, secondaryBlock.hash, "secondary"),
  ]);
  return { blockNumber, blockHash: primaryBlock.hash, gasLimit: primaryBlock.gasLimit };
}

async function preflightIndexer(runtime: Chain97Runtime, releaseCommit: string, fetcher: typeof fetch) {
  const response = await fetcher(`${runtime.indexerBaseUrl}/health`, runtime.indexerAuthToken
    ? { headers: { authorization: `Bearer ${runtime.indexerAuthToken}` } }
    : {});
  if (!response.ok) throw new Error("CHAIN97_INDEXER_PREFLIGHT_FAILED");
  const body = await response.json() as { chainId?: unknown; releaseCommit?: unknown };
  if (body.chainId !== 97 || body.releaseCommit !== releaseCommit) throw new Error("CHAIN97_INDEXER_RELEASE_MISMATCH");
}

async function preflightNonces(rpc: RpcPair, accounts: Accounts) {
  const nonces = {} as Record<WalletSlot, number>;
  for (const slot of ["A", "B", "C"] as const) {
    const address = accounts[slot].address;
    const [primary, secondary] = await Promise.all([
      rpc.primary.getTransactionCount({ address, blockTag: "pending" }),
      rpc.secondary.getTransactionCount({ address, blockTag: "pending" }),
    ]);
    if (primary !== secondary) throw new Error(`CHAIN97_NONCE_DIVERGENCE:${slot}`);
    nonces[slot] = primary;
  }
  return nonces;
}

const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "balance", type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], outputs: [{ name: "remaining", type: "uint256" }] },
] as const;

async function readAssetAtBlock(client: PublicClient, asset: Address, owner: Address, spender: Address | undefined, blockHash: Hex) {
  const call = async (functionName: "balanceOf" | "allowance", args: readonly Address[]) => {
    const data = encodeFunctionData({ abi: erc20Abi, functionName, args: args as never });
    const raw = await canonicalRpcRequest(client, "eth_call", { to: asset, data }, blockHash);
    return decodeFunctionResult({ abi: erc20Abi, functionName, data: raw }) as bigint;
  };
  return { balance: await call("balanceOf", [owner]), allowance: spender ? await call("allowance", [owner, spender]) : 0n };
}

export async function preflightAssets(
  plan: Chain97Plan,
  selectedScenarioIds: readonly string[],
  references: ReferenceMap,
  completedExecutionKeys: ReadonlySet<string>,
  accounts: Accounts,
  rpc: RpcPair,
  canonicalBlock: { blockNumber: bigint; blockHash: Hex },
  historicalResults: ReadonlyMap<string, HistoricalAssetObservation>,
) {
  const sequence = executionSequence(plan, new Set(selectedScenarioIds));
  const stepsByExecutionKey = new Map(sequence.map(({ executionKey, step }) => [executionKey, step]));
  const executionOrder = new Map(sequence.map(({ executionKey }, index) => [executionKey, index]));
  for (const requirement of plan.assetRequirements) {
    const activeFunding = requirement.fundingExecutionKeys.filter((executionKey) => stepsByExecutionKey.has(executionKey));
    if (activeFunding.length === 0) continue;
    const orderedFunding = [...activeFunding].sort((left, right) => executionOrder.get(left)! - executionOrder.get(right)!);
    const remainingAmount = calculateRemainingAssetFunding(activeFunding, completedExecutionKeys, stepsByExecutionKey);
    const asset = references.get(requirement.asset.ref);
    const spender = references.get(requirement.spender.ref);
    const approvalPending = Boolean(requirement.approvalExecutionKey && !completedExecutionKeys.has(requirement.approvalExecutionKey));
    if (typeof asset !== "string" || !publicAddress.test(asset) || (!approvalPending && (typeof spender !== "string" || !publicAddress.test(spender)))) {
      throw new Error(`CHAIN97_ASSET_REFERENCE_INVALID:${requirement.asset.ref}`);
    }
    const owner = accounts[requirement.wallet].address;
    assertHistoricalAssetRequirement({
      requirement, orderedFundingKeys: orderedFunding, completedExecutionKeys, stepsByExecutionKey, historicalResults,
      asset: asset as Address, spender: typeof spender === "string" && publicAddress.test(spender) ? spender as Address : undefined, owner,
    });
    const [primary, secondary] = await Promise.all([
      readAssetAtBlock(rpc.primary, asset as Address, owner, approvalPending ? undefined : spender as Address, canonicalBlock.blockHash),
      readAssetAtBlock(rpc.secondary, asset as Address, owner, approvalPending ? undefined : spender as Address, canonicalBlock.blockHash),
    ]);
    if (canonical(primary) !== canonical(secondary)) throw new Error(`CHAIN97_ASSET_RPC_DIVERGENCE:${requirement.asset.ref}:${requirement.wallet}`);
    assertAssetPreflight(primary, { minimumBalance: remainingAmount, minimumAllowance: approvalPending ? 0n : remainingAmount }, `${requirement.asset.ref}:${requirement.wallet}`);
  }
  await Promise.all([
    assertCanonicalBlock(rpc.primary, canonicalBlock.blockNumber, canonicalBlock.blockHash, "primary"),
    assertCanonicalBlock(rpc.secondary, canonicalBlock.blockNumber, canonicalBlock.blockHash, "secondary"),
  ]);
}

async function waitForSecondaryFinality(rpc: RpcPair, hash: Hex, primaryReceipt: TransactionReceipt, confirmations: number) {
  const finalBlock = primaryReceipt.blockNumber + BigInt(confirmations - 1);
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const [height, receipt] = await Promise.all([
        rpc.secondary.getBlockNumber(),
        rpc.secondary.getTransactionReceipt({ hash }),
      ]);
      if (height >= finalBlock) return receipt;
    } catch { /* the independent RPC has not indexed the receipt yet */ }
    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }
  throw new Error(`CHAIN97_SECONDARY_FINALITY_TIMEOUT:${hash}`);
}

function exactReceipt(receipt: TransactionReceipt): EvidenceReceipt {
  return {
    status: receipt.status === "success" ? 1 : 0,
    blockNumber: receipt.blockNumber,
    blockHash: receipt.blockHash,
    transactionIndex: receipt.transactionIndex,
    gasUsed: receipt.gasUsed,
    effectiveGasPrice: receipt.effectiveGasPrice,
    from: receipt.from,
    to: receipt.to ?? null,
    contractAddress: receipt.contractAddress ?? null,
  };
}

function assertReceiptsAgree(primary: TransactionReceipt, secondary: TransactionReceipt, stage: string) {
  const fields = ["status", "blockNumber", "blockHash", "transactionIndex", "gasUsed", "effectiveGasPrice", "from", "to", "contractAddress"] as const;
  for (const field of fields) if (canonical(primary[field]) !== canonical(secondary[field])) throw new Error(`CHAIN97_RECEIPT_DIVERGENCE:${stage}:${field}`);
  if (primary.status !== "success") throw new Error(`CHAIN97_TRANSACTION_REVERTED:${stage}`);
}

function captureEventReferences(step: Chain97StepInput, decodedEvents: EvidenceTransaction["decodedEvents"], references: ReferenceMap) {
  for (const capture of step.captures) {
    const event = decodedEvents.find((item) => item.name === capture.event);
    const value = event?.args[capture.argument];
    if (typeof value !== "string" || !publicAddress.test(value)) throw new Error(`CHAIN97_CAPTURE_VALUE_INVALID:${step.id}:${capture.ref}`);
    references.set(capture.ref, value);
  }
}

function decodeRequiredEvents(
  step: Chain97StepInput,
  receipt: TransactionReceipt,
  references: ReferenceMap,
  artifacts: Map<string, FoundryArtifact>,
): EvidenceTransaction["decodedEvents"] {
  const decoded: EvidenceTransaction["decodedEvents"] = [];
  for (const required of step.requiredEvents) {
    const artifact = artifacts.get(required.artifact);
    if (!artifact) throw new Error(`CHAIN97_ARTIFACT_NOT_LOADED:${required.artifact}`);
    const expectedAddress = required.address ? resolveTarget(required.address, references).toLowerCase() : undefined;
    let found = false;
    for (const log of receipt.logs) {
      if (expectedAddress && log.address.toLowerCase() !== expectedAddress) continue;
      try {
        const item = decodeEventLog({ abi: artifact.abi, data: log.data, topics: log.topics, strict: true });
        if (item.eventName !== required.event) continue;
        decoded.push({
          name: item.eventName,
          address: log.address,
          logIndex: log.logIndex,
          args: jsonSafe(item.args) as Record<string, unknown>,
        });
        found = true;
      } catch { /* the log belongs to another ABI */ }
    }
    if (!found) throw new Error(`MISSING_EVENT:${step.id}:${required.event}`);
  }
  return decoded;
}

function resolveTarget(target: { ref: string }, references: ReferenceMap): Address {
  const value = references.get(target.ref);
  if (typeof value !== "string" || !publicAddress.test(value)) {
    throw new Error(`CHAIN97_PLAN_REFERENCE_NOT_ADDRESS:${target.ref}`);
  }
  return value as Address;
}

async function readSnapshots(step: Chain97StepInput, blockNumber: bigint, blockHash: Hex, rpc: RpcPair, references: ReferenceMap, artifacts: Map<string, FoundryArtifact>) {
  const read = async (client: PublicClient) => {
    const block = await client.getBlock({ blockHash });
    if (!block.hash || block.hash.toLowerCase() !== blockHash.toLowerCase()) throw new Error(`CHAIN97_REORG_DETECTED:${step.id}`);
    const values: Record<string, unknown> = { blockTimestamp: block.timestamp.toString() };
    for (const item of step.reads) {
      const artifact = artifacts.get(item.artifact);
      if (!artifact) throw new Error(`CHAIN97_ARTIFACT_NOT_LOADED:${item.artifact}`);
      const args = resolvePlanValue(item.args, references, 0n) as readonly unknown[];
      const data = encodeFunctionData({ abi: artifact.abi, functionName: item.functionName, args });
      const raw = await canonicalRpcRequest(client, "eth_call", { to: resolveTarget(item.target, references), data }, blockHash);
      values[item.name] = jsonSafe(decodeFunctionResult({ abi: artifact.abi, functionName: item.functionName, data: raw }));
    }
    for (const probe of step.revertProbes ?? []) {
      const probeArtifact = artifacts.get(probe.artifact);
      const errorArtifact = artifacts.get(probe.errorArtifact);
      if (!probeArtifact || !errorArtifact) throw new Error(`CHAIN97_ARTIFACT_NOT_LOADED:${probe.artifact}`);
      const data = encodeFunctionData({ abi: probeArtifact.abi, functionName: probe.functionName, args: resolvePlanValue(probe.args, references, 0n) as readonly unknown[] });
      let revertData: Hex | undefined;
      try {
        await client.request({ method: "eth_call", params: [{ from: resolveTarget({ ref: `wallet${probe.wallet}` }, references), to: resolveTarget(probe.target, references), data, value: `0x${BigInt(probe.valueWei).toString(16)}` }, { blockHash, requireCanonical: true }] } as never);
      } catch (error) {
        revertData = findRevertData(error);
      }
      if (!revertData) throw new Error(`CHAIN97_EXPECTED_REVERT_MISSING:${step.id}:${probe.name}`);
      let decoded: { errorName: string };
      try { decoded = decodeErrorResult({ abi: errorArtifact.abi, data: revertData }); } catch { throw new Error(`CHAIN97_EXPECTED_REVERT_UNDECODABLE:${step.id}:${probe.name}`); }
      if (decoded.errorName !== probe.errorName) throw new Error(`CHAIN97_EXPECTED_REVERT_MISMATCH:${step.id}:${probe.name}`);
      values[`revert:${probe.name}`] = { errorName: decoded.errorName, dataHash: keccak256(revertData) };
    }
    return values;
  };
  const [primary, secondary] = await Promise.all([read(rpc.primary), read(rpc.secondary)]);
  if (canonical(primary) !== canonical(secondary)) throw new Error(`RPC_DIVERGENCE:${step.id}`);
  for (const item of step.reads) {
    if (!item.captureRef) continue;
    const value = primary[item.name];
    if (typeof value !== "string" || !publicAddress.test(value)) throw new Error(`CHAIN97_READ_CAPTURE_INVALID:${step.id}:${item.name}`);
    const existing = references.get(item.captureRef);
    if (existing !== undefined && (typeof existing !== "string" || existing.toLowerCase() !== value.toLowerCase())) throw new Error(`CHAIN97_READ_CAPTURE_MISMATCH:${step.id}:${item.name}`);
    references.set(item.captureRef, value);
  }
  await Promise.all([
    assertCanonicalBlock(rpc.primary, blockNumber, blockHash, "primary"),
    assertCanonicalBlock(rpc.secondary, blockNumber, blockHash, "secondary"),
  ]);
  return { stage: step.id, blockNumber, blockHash, primaryProvider: rpc.primaryProvider, secondaryProvider: rpc.secondaryProvider, primary, secondary };
}

function findRevertData(error: unknown, seen = new Set<unknown>()): Hex | undefined {
  if (typeof error === "string" && /^0x[0-9a-fA-F]{8,}$/.test(error) && error.length % 2 === 0) return error as Hex;
  if (!error || typeof error !== "object" || seen.has(error)) return undefined;
  seen.add(error);
  for (const key of ["data", "cause", "error", "details"] as const) {
    const found = findRevertData((error as Record<string, unknown>)[key], seen);
    if (found) return found;
  }
  return undefined;
}

async function executeStep(input: {
  step: Chain97StepInput;
  scope: "bootstrap" | "lifecycle";
  scenarioForm?: DeploymentInput;
  plan: Chain97Plan;
  wallet: Wallets[WalletSlot];
  nonce: number;
  gasPrice: bigint;
  rpc: RpcPair;
  references: ReferenceMap;
  artifacts: Map<string, FoundryArtifact>;
}): Promise<StepResult & { encoding?: FactoryEncoding }> {
  const { step, wallet, references, artifacts } = input;
  const artifact = artifacts.get(step.artifact);
  if (!artifact) throw new Error(`CHAIN97_ARTIFACT_NOT_LOADED:${step.artifact}`);
  const block = await input.rpc.primary.getBlock({ blockTag: "latest" });
  const value = BigInt(step.valueWei);
  const gas = BigInt(step.gasLimit);
  let hash: Hex;
  let encoding: FactoryEncoding | undefined;
  let predictedAddress: Address | undefined;
  if (step.kind === "deploy") {
    predictedAddress = getContractAddress({ from: wallet.account.address, nonce: BigInt(input.nonce) });
    references.set(step.captureAddress, predictedAddress);
    hash = await wallet.client.deployContract({
      abi: artifact.abi,
      bytecode: artifact.bytecode,
      args: resolvePlanValue(step.constructorArgs, references, block.timestamp) as readonly unknown[],
      account: wallet.account,
      chain: bscTestnet,
      value,
      gas,
      gasPrice: input.gasPrice,
      nonce: input.nonce,
    } as never);
  } else {
    const target = resolveTarget(step.target, references);
    let data: Hex;
    if (step.kind === "factoryDeploy") {
      if (!input.scenarioForm) throw new Error(`CHAIN97_FACTORY_FORM_MISSING:${step.id}`);
      encoding = encodeFactoryDeployment(input.scenarioForm, artifact.abi);
      data = encoding.data;
    } else {
      data = encodeFunctionData({
        abi: artifact.abi,
        functionName: step.functionName,
        args: resolvePlanValue(step.args, references, block.timestamp) as readonly unknown[],
      });
    }
    hash = await wallet.client.sendTransaction({ account: wallet.account, chain: bscTestnet, to: target, data, value, gas, gasPrice: input.gasPrice, nonce: input.nonce });
  }

  const primaryReceipt = await input.rpc.primary.waitForTransactionReceipt({ hash, confirmations: input.plan.confirmations, timeout: 10 * 60_000 });
  const secondaryReceipt = await waitForSecondaryFinality(input.rpc, hash, primaryReceipt, input.plan.confirmations);
  assertReceiptsAgree(primaryReceipt, secondaryReceipt, step.id);
  if (predictedAddress && primaryReceipt.contractAddress?.toLowerCase() !== predictedAddress.toLowerCase()) throw new Error(`CHAIN97_DEPLOYMENT_ADDRESS_MISMATCH:${step.id}`);
  const decodedEvents = decodeRequiredEvents(step, primaryReceipt, references, artifacts);
  captureEventReferences(step, decodedEvents, references);
  const transaction: EvidenceTransaction = {
    scope: input.scope,
    stage: step.id,
    assertion: step.assertion,
    resumed: false,
    hash,
    receipt: exactReceipt(primaryReceipt),
    requiredEvents: step.requiredEvents.map(({ event }) => event),
    decodedEvents,
  };
  const snapshot = await readSnapshots(step, primaryReceipt.blockNumber, primaryReceipt.blockHash, input.rpc, references, artifacts);
  return { transaction, snapshot: { ...snapshot, scope: input.scope }, nonce: input.nonce, ...(encoding ? { encoding } : {}) };
}

async function observeCheckpointStep(input: {
  step: Chain97StepInput;
  scope: "bootstrap" | "lifecycle";
  entry: Chain97CheckpointEntry;
  plan: Chain97Plan;
  rpc: RpcPair;
  references: ReferenceMap;
  artifacts: Map<string, FoundryArtifact>;
  scenarioForm?: DeploymentInput;
}): Promise<StepResult> {
  const hash = input.entry.transactionHash as Hex;
  const [primaryReceipt, secondaryReceipt, primaryHeight, secondaryHeight, primaryTransaction, secondaryTransaction] = await Promise.all([
    input.rpc.primary.getTransactionReceipt({ hash }),
    input.rpc.secondary.getTransactionReceipt({ hash }),
    input.rpc.primary.getBlockNumber(),
    input.rpc.secondary.getBlockNumber(),
    input.rpc.primary.getTransaction({ hash }),
    input.rpc.secondary.getTransaction({ hash }),
  ]);
  assertReceiptsAgree(primaryReceipt, secondaryReceipt, input.step.id);
  if (
    primaryReceipt.blockNumber.toString() !== input.entry.blockNumber
    || primaryReceipt.blockHash.toLowerCase() !== input.entry.blockHash.toLowerCase()
    || primaryHeight < primaryReceipt.blockNumber + BigInt(input.plan.confirmations - 1)
    || secondaryHeight < secondaryReceipt.blockNumber + BigInt(input.plan.confirmations - 1)
  ) throw new Error(`CHAIN97_CHECKPOINT_RECEIPT_MISMATCH:${input.entry.executionKey}`);
  if (
    primaryTransaction.input.toLowerCase() !== secondaryTransaction.input.toLowerCase()
    || primaryTransaction.nonce !== secondaryTransaction.nonce
    || primaryTransaction.from.toLowerCase() !== secondaryTransaction.from.toLowerCase()
    || (primaryTransaction.to ?? "").toLowerCase() !== (secondaryTransaction.to ?? "").toLowerCase()
    || primaryTransaction.value !== secondaryTransaction.value
    || primaryTransaction.from.toLowerCase() !== resolveTarget({ ref: `wallet${input.step.wallet}` }, input.references).toLowerCase()
    || primaryTransaction.value !== BigInt(input.step.valueWei)
  ) throw new Error(`CHAIN97_CHECKPOINT_TRANSACTION_MISMATCH:${input.entry.executionKey}`);
  const block = await input.rpc.primary.getBlock({ blockNumber: primaryReceipt.blockNumber });
  const stepArtifact = input.artifacts.get(input.step.artifact);
  if (!stepArtifact) throw new Error(`CHAIN97_ARTIFACT_NOT_LOADED:${input.step.artifact}`);
  let expectedInput: Hex;
  if (input.step.kind === "deploy") {
    expectedInput = encodeDeployData({ abi: stepArtifact.abi, bytecode: stepArtifact.bytecode, args: resolvePlanValue(input.step.constructorArgs, input.references, block.timestamp) as readonly unknown[] });
    if (primaryTransaction.to !== null) throw new Error(`CHAIN97_CHECKPOINT_TRANSACTION_MISMATCH:${input.entry.executionKey}`);
  } else if (input.step.kind === "factoryDeploy") {
    if (!input.scenarioForm) throw new Error(`CHAIN97_FACTORY_FORM_MISSING:${input.step.id}`);
    expectedInput = encodeFactoryDeployment(input.scenarioForm, stepArtifact.abi).data;
    if (primaryTransaction.to?.toLowerCase() !== resolveTarget(input.step.target, input.references).toLowerCase()) throw new Error(`CHAIN97_CHECKPOINT_TRANSACTION_MISMATCH:${input.entry.executionKey}`);
  } else {
    expectedInput = encodeFunctionData({ abi: stepArtifact.abi, functionName: input.step.functionName, args: resolvePlanValue(input.step.args, input.references, block.timestamp) as readonly unknown[] });
    if (primaryTransaction.to?.toLowerCase() !== resolveTarget(input.step.target, input.references).toLowerCase()) throw new Error(`CHAIN97_CHECKPOINT_TRANSACTION_MISMATCH:${input.entry.executionKey}`);
  }
  if (primaryTransaction.input.toLowerCase() !== expectedInput.toLowerCase()) throw new Error(`CHAIN97_CHECKPOINT_TRANSACTION_MISMATCH:${input.entry.executionKey}`);
  if (input.step.kind === "deploy") {
    if (!primaryReceipt.contractAddress) throw new Error(`CHAIN97_CHECKPOINT_DEPLOYMENT_ADDRESS_MISSING:${input.entry.executionKey}`);
    input.references.set(input.step.captureAddress, primaryReceipt.contractAddress);
  }
  const decodedEvents = decodeRequiredEvents(input.step, primaryReceipt, input.references, input.artifacts);
  captureEventReferences(input.step, decodedEvents, input.references);
  await Promise.all([
    assertCanonicalBlock(input.rpc.primary, primaryReceipt.blockNumber, primaryReceipt.blockHash, "primary"),
    assertCanonicalBlock(input.rpc.secondary, primaryReceipt.blockNumber, primaryReceipt.blockHash, "secondary"),
  ]);
  const transaction: EvidenceTransaction = {
    scope: input.scope,
    stage: input.step.id,
    assertion: input.step.assertion,
    resumed: true,
    hash,
    receipt: exactReceipt(primaryReceipt),
    requiredEvents: input.step.requiredEvents.map(({ event }) => event),
    decodedEvents,
  };
  const snapshot = await readSnapshots(input.step, primaryReceipt.blockNumber, primaryReceipt.blockHash, input.rpc, input.references, input.artifacts);
  return { transaction, snapshot: { ...snapshot, scope: input.scope }, nonce: primaryTransaction.nonce };
}

const executionSequence = (plan: Chain97Plan, selected: ReadonlySet<string>) => [
  ...plan.bootstrap.map((step) => ({ executionKey: `bootstrap:${step.id}`, scope: "bootstrap" as const, step })),
  ...plan.scenarios.filter(({ id }) => selected.has(id)).flatMap((scenario) => scenario.steps.map((step) => ({ executionKey: `${scenario.id}:${step.id}`, scope: "lifecycle" as const, step }))),
];

function assertCheckpointPrefix(checkpoint: Chain97Checkpoint, sequence: ReturnType<typeof executionSequence>) {
  if (checkpoint.completed.length > sequence.length) throw new Error("CHAIN97_CHECKPOINT_SEQUENCE_INVALID");
  for (let index = 0; index < checkpoint.completed.length; index += 1) {
    if (checkpoint.completed[index]!.executionKey !== sequence[index]!.executionKey) throw new Error("CHAIN97_CHECKPOINT_SEQUENCE_INVALID");
  }
}

function assertHistoricalNonceContinuity(
  checkpoint: Chain97Checkpoint,
  sequence: ReturnType<typeof executionSequence>,
  results: ReadonlyMap<string, StepResult>,
  pendingNonces: Record<WalletSlot, number>,
) {
  const last = new Map<WalletSlot, number>();
  for (let index = 0; index < checkpoint.completed.length; index += 1) {
    const planned = sequence[index]!;
    const result = results.get(planned.executionKey);
    if (!result) throw new Error(`CHAIN97_CHECKPOINT_NONCE_MISSING:${planned.executionKey}`);
    const previous = last.get(planned.step.wallet);
    if (previous !== undefined && result.nonce !== previous + 1) throw new Error(`CHAIN97_CHECKPOINT_NONCE_SEQUENCE_INVALID:${planned.step.wallet}`);
    last.set(planned.step.wallet, result.nonce);
  }
  for (const [wallet, nonce] of last) if (pendingNonces[wallet] !== nonce + 1) throw new Error(`CHAIN97_CHECKPOINT_PENDING_NONCE_INVALID:${wallet}`);
}

const planUint = (value: unknown, label: string): bigint => {
  const raw = value && typeof value === "object" && !Array.isArray(value) && "uint" in value ? (value as { uint: unknown }).uint : value;
  if (!((typeof raw === "string" && /^\d+$/.test(raw)) || (typeof raw === "number" && Number.isSafeInteger(raw) && raw >= 0) || typeof raw === "bigint" && raw >= 0n)) {
    throw new Error(`CHAIN97_STAGE_TIMELOCK_CONFIG_INVALID:${label}`);
  }
  return BigInt(raw);
};

async function assertStageTemporalPrerequisite(
  scenario: Chain97Plan["scenarios"][number],
  step: Chain97StepInput,
  snapshots: EvidenceBundle["rpcSnapshots"],
  rpc: RpcPair,
) {
  const snapshot = (stage: string) => snapshots.find((item) => item.stage === stage)?.primary;
  let availableAt: bigint | undefined;
  if (step.id === "REFUND_ENABLE") {
    const deployment = snapshot("REFUND_DEPLOY");
    const mint = snapshot("REFUND_MINT");
    const filledAt = planUint(mint?.filledAt ?? 0, `${scenario.id}:${step.id}:filledAt`);
    const createdAt = planUint(deployment?.createdAt ?? 0, `${scenario.id}:${step.id}:createdAt`);
    availableAt = (filledAt > 0n ? filledAt : createdAt) + 86_400n;
  } else if (step.id === "TRANCHE_RETURN") {
    const splitAt = planUint(snapshot("TRANCHE_SPLIT")?.blockTimestamp ?? 0, `${scenario.id}:${step.id}:splitAt`);
    const template = scenario.form.templateConfig as Record<string, unknown>;
    const rewards = template.rewards as Record<string, unknown> | undefined;
    availableAt = splitAt + planUint(rewards?.growthDuration ?? 0, `${scenario.id}:${step.id}:growthDuration`);
  } else if (step.id === "WHITELIST_PUBLIC_MINT") {
    const template = scenario.form.templateConfig as Record<string, unknown>;
    availableAt = planUint(template.whitelistDeadline ?? 0, `${scenario.id}:${step.id}:whitelistDeadline`);
  } else if (step.id === "LIMIT_EXPIRED_TRANSFER") {
    const template = scenario.form.templateConfig as Record<string, unknown>;
    const durations = template.durationsMinutes;
    if (!Array.isArray(durations)) throw new Error(`CHAIN97_STAGE_TIMELOCK_CONFIG_INVALID:${scenario.id}:${step.id}`);
    availableAt = planUint(snapshot("LIMIT_ACTIVE_TRANSFER")?.activatedAt ?? 0, `${scenario.id}:${step.id}:activatedAt`) + durations.reduce((sum, item, index) => sum + planUint(item, `${scenario.id}:${step.id}:duration.${index}`) * 60n, 0n);
  }
  if (availableAt === undefined) return;
  if (availableAt <= 0n) throw new Error(`CHAIN97_STAGE_TIMELOCK_CONFIG_INVALID:${scenario.id}:${step.id}`);
  const [primaryHeight, secondaryHeight] = await Promise.all([rpc.primary.getBlockNumber(), rpc.secondary.getBlockNumber()]);
  const blockNumber = primaryHeight < secondaryHeight ? primaryHeight : secondaryHeight;
  const [primary, secondary] = await Promise.all([rpc.primary.getBlock({ blockNumber }), rpc.secondary.getBlock({ blockNumber })]);
  if (!primary.hash || !secondary.hash || primary.hash.toLowerCase() !== secondary.hash.toLowerCase()) throw new Error(`CHAIN97_STAGE_TIMELOCK_RPC_DIVERGENCE:${scenario.id}:${step.id}`);
  if (primary.timestamp !== secondary.timestamp || primary.timestamp < availableAt) throw new Error(`CHAIN97_STAGE_TIMELOCK_PENDING:${scenario.id}:${step.id}:${availableAt}`);
  await Promise.all([assertCanonicalBlock(rpc.primary, blockNumber, primary.hash, "primary"), assertCanonicalBlock(rpc.secondary, blockNumber, secondary.hash, "secondary")]);
}

async function readChainConfig(transactionHash: Hex, factory: FoundryArtifact, rpc: RpcPair) {
  const [primary, secondary] = await Promise.all([
    rpc.primary.getTransaction({ hash: transactionHash }),
    rpc.secondary.getTransaction({ hash: transactionHash }),
  ]);
  if (primary.input.toLowerCase() !== secondary.input.toLowerCase()) throw new Error("CHAIN97_DEPLOYMENT_INPUT_DIVERGENCE");
  const decoded = decodeFunctionData({ abi: factory.abi, data: primary.input });
  if (decoded.functionName !== "deploy" || !decoded.args || decoded.args.length !== 4) throw new Error("CHAIN97_DEPLOYMENT_INPUT_INVALID");
  return { onchainId: decoded.args[0] as Hex, version: Number(decoded.args[1]), commonConfig: decoded.args[2] as Hex, templateConfig: decoded.args[3] as Hex };
}

async function readDirectProjectConfig(factoryAddress: Address, project: Address, factory: FoundryArtifact, blockNumber: bigint, blockHash: Hex, rpc: RpcPair) {
  const read = async (client: PublicClient) => {
    const data = encodeFunctionData({ abi: factory.abi, functionName: "projectConfig", args: [project] });
    const raw = await canonicalRpcRequest(client, "eth_call", { to: factoryAddress, data }, blockHash);
    return decodeFunctionResult({ abi: factory.abi, functionName: "projectConfig", data: raw }) as readonly [Hex, number, Hex, Hex];
  };
  const [primary, secondary] = await Promise.all([read(rpc.primary), read(rpc.secondary)]);
  if (canonical(primary) !== canonical(secondary)) throw new Error("CHAIN97_DIRECT_CONFIG_RPC_DIVERGENCE");
  if (!primary[0] || /^0x0{64}$/i.test(primary[0]) || !primary[2] || !primary[3]) throw new Error("CHAIN97_DIRECT_CONFIG_MISSING");
  await Promise.all([
    assertCanonicalBlock(rpc.primary, blockNumber, blockHash, "primary"),
    assertCanonicalBlock(rpc.secondary, blockNumber, blockHash, "secondary"),
  ]);
  return { onchainId: primary[0], version: Number(primary[1]), commonConfig: primary[2], templateConfig: primary[3] };
}

async function readIndexedConfig(runtime: Chain97Runtime, releaseCommit: string, project: Address, deploymentTransaction: Hex, deploymentBlockHash: Hex, fetcher: typeof fetch) {
  const response = await fetcher(`${runtime.indexerBaseUrl}/v1/chains/97/projects/${project}/config?releaseCommit=${releaseCommit}`, runtime.indexerAuthToken
    ? { headers: { authorization: `Bearer ${runtime.indexerAuthToken}` } }
    : {});
  if (!response.ok) throw new Error(`CHAIN97_INDEX_CONFIG_UNAVAILABLE:${project}`);
  const body = await response.json() as { chainId?: unknown; releaseCommit?: unknown; project?: unknown; deploymentTransaction?: unknown; deploymentBlockHash?: unknown; config?: unknown };
  if (
    body.chainId !== 97 || body.releaseCommit !== releaseCommit || typeof body.project !== "string" || body.project.toLowerCase() !== project.toLowerCase()
    || typeof body.deploymentTransaction !== "string" || body.deploymentTransaction.toLowerCase() !== deploymentTransaction.toLowerCase()
    || typeof body.deploymentBlockHash !== "string" || body.deploymentBlockHash.toLowerCase() !== deploymentBlockHash.toLowerCase()
    || !body.config || typeof body.config !== "object"
  ) throw new Error(`CHAIN97_INDEX_CONFIG_INVALID:${project}`);
  return body.config as Record<string, unknown>;
}

async function verifyTargets(input: {
  targets: Array<{ target: Chain97VerificationTargetInput; transactionKey: string }>;
  references: ReferenceMap;
  transactions: Map<string, EvidenceTransaction>;
  artifacts: Map<string, FoundryArtifact>;
  runtime: Chain97Runtime;
  rpc: RpcPair;
  chainTimestamp: bigint;
  cache: Map<string, { deployment: EvidenceBundle["deployedContracts"][number]; verification: EvidenceBundle["verification"] }>;
  verificationProofs: ReadonlyMap<string, VerificationCreationProof>;
}) {
  const deployedContracts: EvidenceBundle["deployedContracts"] = [];
  const verification: EvidenceBundle["verification"] = [];
  for (const plannedTarget of input.targets) {
    const { target } = plannedTarget;
    const address = resolveTarget(target.address, input.references);
    const key = address.toLowerCase();
    let cached = input.cache.get(key);
    if (!cached) {
      const artifact = input.artifacts.get(target.artifact);
      const transaction = input.transactions.get(plannedTarget.transactionKey);
      const proof = input.verificationProofs.get(target.name);
      if (!artifact) throw new Error(`CHAIN97_ARTIFACT_NOT_LOADED:${target.artifact}`);
      if (!transaction) throw new Error(`CHAIN97_CREATION_TRANSACTION_MISSING:${target.name}`);
      if (!proof || proof.executionKey !== plannedTarget.transactionKey) throw new Error(`CHAIN97_CREATION_PROOF_MISSING:${target.name}`);
      const constructorArgs = resolvePlanValue(target.constructorArgs, input.references, input.chainTimestamp) as unknown[];
      const blockHash = transaction.receipt.blockHash as Hex;
      const [primaryTransaction, secondaryTransaction, primaryCode, secondaryCode] = await Promise.all([
        input.rpc.primary.getTransaction({ hash: transaction.hash as Hex }),
        input.rpc.secondary.getTransaction({ hash: transaction.hash as Hex }),
        canonicalRpcRequest(input.rpc.primary, "eth_getCode", address, blockHash),
        canonicalRpcRequest(input.rpc.secondary, "eth_getCode", address, blockHash),
      ]);
      if (
        primaryTransaction.hash.toLowerCase() !== transaction.hash.toLowerCase()
        || secondaryTransaction.hash.toLowerCase() !== transaction.hash.toLowerCase()
        || primaryTransaction.input.toLowerCase() !== secondaryTransaction.input.toLowerCase()
      ) throw new Error(`CHAIN97_CREATION_TRANSACTION_RPC_MISMATCH:${target.name}`);
      if (primaryCode === "0x" || primaryCode.toLowerCase() !== secondaryCode.toLowerCase()) throw new Error(`CHAIN97_RUNTIME_CODE_MISMATCH:${target.name}`);
      const runtimeCodeHash = keccak256(primaryCode);
      const { creationKind, creationLocator } = resolveVerificationCreationProvenance({
        targetName: target.name, address, proof, transaction, transactionTo: primaryTransaction.to,
      });
      if (creationKind === "receipt") {
        const expectedInput = encodeDeployData({ abi: artifact.abi, bytecode: artifact.bytecode, args: constructorArgs });
        if (primaryTransaction.to !== null || primaryTransaction.input.toLowerCase() !== expectedInput.toLowerCase()) throw new Error(`CHAIN97_DIRECT_CREATION_INPUT_MISMATCH:${target.name}`);
      }
      await Promise.all([
        assertCanonicalBlock(input.rpc.primary, transaction.receipt.blockNumber, blockHash, "primary"),
        assertCanonicalBlock(input.rpc.secondary, transaction.receipt.blockNumber, blockHash, "secondary"),
      ]);
      const verified = await verifyDeployedContract({ address, artifact, constructorArgs, runtimeCodeHash, bscscanApiKey: input.runtime.bscscanApiKey });
      cached = {
        deployment: {
          name: target.name,
          address,
          artifact: target.artifact,
          transactionHash: transaction.hash,
          creationKind,
          creationLocator,
          creationTransactionInputHash: keccak256(primaryTransaction.input),
          creationBytecodeHash: verified.creationBytecodeHash,
          runtimeCodeHash: verified.runtimeCodeHash,
          constructorArgumentsHash: verified.constructorArgumentsHash,
          sourceHash: verified.sourceHash,
          compilerVersion: verified.compilerVersion,
        },
        verification: verified.verification,
      };
      input.cache.set(key, cached);
    }
    deployedContracts.push({ ...cached.deployment, name: target.name });
    verification.push(...cached.verification);
  }
  return { deployedContracts, verification };
}

export async function executeChain97Plan(input: {
  plan: Chain97Plan;
  selectedScenarioIds: readonly string[];
  releaseCommit: string;
  runtime: Chain97Runtime;
  env: RunnerEnvironment;
  repositoryRoot: string;
  fetcher?: typeof fetch;
}): Promise<EvidenceBundle[]> {
  const selected = new Set(input.selectedScenarioIds);
  const rpc = createRpcPair(input.env);
  const artifacts = await loadRequiredArtifacts(input.plan, selected, input.repositoryRoot);
  const accounts = createAccounts(input.env);
  const references: ReferenceMap = new Map(input.plan.dependencies.map(({ name, address }) => [name, address]));
  for (const slot of ["A", "B", "C"] as const) references.set(`wallet${slot}`, accounts[slot].address);
  const sequence = executionSequence(input.plan, selected);
  const checkpointPath = resolve(input.repositoryRoot, input.runtime.checkpointPath);
  const checkpointRelationship = relative(input.repositoryRoot, checkpointPath);
  if (!checkpointRelationship || checkpointRelationship.startsWith("..")) throw new Error("CHAIN97_CHECKPOINT_PATH_OUTSIDE_REPOSITORY");
  let nonces: Record<WalletSlot, number> | undefined;
  let gasPrice: bigint | undefined;
  let noncePlan: Map<string, number> | undefined;
  let checkpoint: Chain97Checkpoint | undefined;
  const historicalResults = new Map<string, StepResult>();
  const { compiled, senders: wallets } = await authorizeChain97Broadcast({
    compile: () => compileChain97Plan({
      plan: input.plan,
      selectedScenarioIds: input.selectedScenarioIds,
      artifacts,
      walletAddresses: Object.fromEntries((["A", "B", "C"] as const).map((slot) => [slot, accounts[slot].address])) as Record<WalletSlot, Address>,
    }),
    preflight: async (staticPlan) => {
      try { await access(dirname(checkpointPath), constants.W_OK); } catch { throw new Error("CHAIN97_CHECKPOINT_DIRECTORY_NOT_WRITABLE"); }
      checkpoint = await loadCheckpoint(checkpointPath, input.releaseCommit, staticPlan.planHash);
      assertCheckpointPrefix(checkpoint, sequence);
      await preflightIndexer(input.runtime, input.releaseCommit, input.fetcher ?? fetch);
      const canonicalBlock = await preflightDependencies(input.plan, rpc);
      for (let index = 0; index < checkpoint.completed.length; index += 1) {
        const entry = checkpoint.completed[index]!;
        const planned = sequence[index]!;
        const scenarioId = entry.executionKey.startsWith("bootstrap:") ? undefined : entry.executionKey.slice(0, entry.executionKey.indexOf(":"));
        const plannedScenario = scenarioId ? input.plan.scenarios.find(({ id }) => id === scenarioId) : undefined;
        const scenarioForm = plannedScenario ? resolvePlanValue(plannedScenario.form as unknown as PlanValue, references, 0n) as DeploymentInput : undefined;
        historicalResults.set(entry.executionKey, await observeCheckpointStep({ ...planned, entry, plan: input.plan, rpc, references, artifacts, ...(scenarioForm ? { scenarioForm } : {}) }));
      }
      const preflight = await preflightChain97({ env: input.env });
      const balances = Object.fromEntries(preflight.wallets.map(({ slot, balanceWei }) => [slot, balanceWei])) as Record<WalletSlot, bigint>;
      const completedKeys = new Set(checkpoint.completed.map(({ executionKey }) => executionKey));
      for (const planned of sequence.filter(({ executionKey }) => !completedKeys.has(executionKey))) {
        if (BigInt(planned.step.gasLimit) > canonicalBlock.gasLimit) throw new Error(`CHAIN97_STEP_GAS_LIMIT_EXCEEDS_BLOCK:${planned.executionKey}`);
      }
      assertChain97Budgets(calculateChain97Budgets(input.plan, input.selectedScenarioIds, completedKeys), balances);
      await preflightAssets(input.plan, input.selectedScenarioIds, references, completedKeys, accounts, rpc, canonicalBlock, historicalResults);
      await preflightVerificationServices({
        bscscanApiKey: input.runtime.bscscanApiKey,
        probeAddress: preflight.wallets[0]!.address,
        fetcher: input.fetcher ?? fetch,
      });
      nonces = await preflightNonces(rpc, accounts);
      assertHistoricalNonceContinuity(checkpoint, sequence, historicalResults, nonces);
      const [primaryGasPrice, secondaryGasPrice] = await Promise.all([rpc.primary.getGasPrice(), rpc.secondary.getGasPrice()]);
      gasPrice = primaryGasPrice > secondaryGasPrice ? primaryGasPrice : secondaryGasPrice;
      if (gasPrice > BigInt(input.plan.maxGasPriceWei)) throw new Error("CHAIN97_GAS_PRICE_EXCEEDS_PLAN");
      noncePlan = compileNoncePlan(input.plan, input.selectedScenarioIds, nonces, completedKeys);
      await Promise.all([
        assertCanonicalBlock(rpc.primary, canonicalBlock.blockNumber, canonicalBlock.blockHash, "primary"),
        assertCanonicalBlock(rpc.secondary, canonicalBlock.blockNumber, canonicalBlock.blockHash, "secondary"),
      ]);
    },
    createSenders: () => createWallets(accounts, resolveChain97Rpcs(input.env).primary.endpoint),
  });
  if (!nonces || gasPrice === undefined || !noncePlan || !checkpoint) throw new Error("CHAIN97_PREFLIGHT_INCOMPLETE");

  const transactions = new Map<string, EvidenceTransaction>();
  const bootstrapTransactions: EvidenceTransaction[] = [];
  const bootstrapSnapshots: EvidenceBundle["rpcSnapshots"] = [];
  for (const step of input.plan.bootstrap) {
    const executionKey = `bootstrap:${step.id}`;
    let result = historicalResults.get(executionKey);
    if (!result) {
      const nonce = noncePlan.get(executionKey);
      if (nonce === undefined) throw new Error(`CHAIN97_NONCE_PLAN_MISSING:${executionKey}`);
      result = await executeStep({ step, scope: "bootstrap", plan: input.plan, wallet: wallets[step.wallet], nonce, gasPrice, rpc, references, artifacts });
      checkpoint = createCheckpoint({ releaseCommit: checkpoint.releaseCommit, planHash: checkpoint.planHash, completed: [...checkpoint.completed, {
        executionKey, transactionHash: result.transaction.hash, blockNumber: result.transaction.receipt.blockNumber.toString(), blockHash: result.transaction.receipt.blockHash,
      }] });
      await saveCheckpoint(checkpointPath, checkpoint);
    }
    transactions.set(`bootstrap:${step.id}`, result.transaction);
    bootstrapTransactions.push(result.transaction);
    bootstrapSnapshots.push(result.snapshot);
  }

  const bundles: EvidenceBundle[] = [];
  const verificationCache = new Map<string, { deployment: EvidenceBundle["deployedContracts"][number]; verification: EvidenceBundle["verification"] }>();
  for (const scenario of input.plan.scenarios.filter(({ id }) => selected.has(id))) {
    const scenarioTransactions: EvidenceTransaction[] = [];
    const scenarioSnapshots: EvidenceBundle["rpcSnapshots"] = [];
    const factoryDeploymentResults = new Map<string, { encoding: FactoryEncoding; transaction: EvidenceTransaction }>();
    for (const step of scenario.steps) {
      const executionKey = `${scenario.id}:${step.id}`;
      if (!compiled.forms.has(scenario.id)) throw new Error(`CHAIN97_COMPILED_FORM_MISSING:${scenario.id}`);
      const scenarioForm = resolvePlanValue(scenario.form as unknown as PlanValue, references, 0n) as DeploymentInput;
      let result = historicalResults.get(executionKey) as (StepResult & { encoding?: FactoryEncoding }) | undefined;
      if (!result) {
        await assertStageTemporalPrerequisite(scenario, step, scenarioSnapshots, rpc);
        const nonce = noncePlan.get(executionKey);
        if (nonce === undefined) throw new Error(`CHAIN97_NONCE_PLAN_MISSING:${executionKey}`);
        result = await executeStep({ step, scope: "lifecycle", scenarioForm, plan: input.plan, wallet: wallets[step.wallet], nonce, gasPrice, rpc, references, artifacts });
        checkpoint = createCheckpoint({ releaseCommit: checkpoint.releaseCommit, planHash: checkpoint.planHash, completed: [...checkpoint.completed, {
          executionKey, transactionHash: result.transaction.hash, blockNumber: result.transaction.receipt.blockNumber.toString(), blockHash: result.transaction.receipt.blockHash,
        }] });
        await saveCheckpoint(checkpointPath, checkpoint);
      } else if (step.kind === "factoryDeploy") {
        result = { ...result, encoding: encodeFactoryDeployment(scenarioForm, artifacts.get(step.artifact)!.abi) };
      }
      transactions.set(`${scenario.id}:${step.id}`, result.transaction);
      scenarioTransactions.push(result.transaction);
      scenarioSnapshots.push(result.snapshot);
      if (result.encoding) factoryDeploymentResults.set(executionKey, { encoding: result.encoding, transaction: result.transaction });
    }
    const { encoding: factoryEncoding, transaction: factoryTransaction } = selectPrimaryFactoryDeployment(compiled, scenario.id, factoryDeploymentResults);
    const factoryStep = scenario.steps.find((step) => step.id === "DEPLOY" && step.kind === "factoryDeploy");
    if (!factoryStep || factoryStep.kind !== "factoryDeploy") throw new Error(`CHAIN97_PRIMARY_FACTORY_DEPLOYMENT_MISSING:${scenario.id}`);
    const factory = artifacts.get(factoryStep.artifact)!;
    const chainInput = await readChainConfig(factoryTransaction.hash as Hex, factory, rpc);
    if (chainInput.onchainId.toLowerCase() !== factoryEncoding.templateOnchainId.toLowerCase() || chainInput.version !== scenario.form.version) throw new Error(`CHAIN97_CHAIN_TEMPLATE_MISMATCH:${scenario.id}`);
    const chainConfig = decodeProjectConfig(scenario.form.templateId, scenario.form.version, chainInput.commonConfig, chainInput.templateConfig);
    const formConfig = jsonSafe(factoryEncoding.normalizedConfig) as Record<string, unknown>;
    const normalizedChainConfig = jsonSafe(chainConfig) as Record<string, unknown>;
    const indexProject = resolveTarget({ ref: scenario.indexProjectRef }, references);
    const projectEvent = factoryTransaction.decodedEvents.find(({ name, args }) => name === "ProjectDeployed"
      && Object.values(args).some((value) => typeof value === "string" && value.toLowerCase() === indexProject.toLowerCase()));
    if (!projectEvent) throw new Error(`CHAIN97_INDEX_PROJECT_EVENT_BINDING_INVALID:${scenario.id}`);
    const factoryAddress = resolveTarget(factoryStep.target, references);
    const directInput = await readDirectProjectConfig(factoryAddress, indexProject, factory, factoryTransaction.receipt.blockNumber, factoryTransaction.receipt.blockHash as Hex, rpc);
    if (
      directInput.onchainId.toLowerCase() !== chainInput.onchainId.toLowerCase()
      || directInput.version !== chainInput.version
      || directInput.commonConfig.toLowerCase() !== chainInput.commonConfig.toLowerCase()
      || directInput.templateConfig.toLowerCase() !== chainInput.templateConfig.toLowerCase()
    ) throw new Error(`CHAIN97_DIRECT_CONFIG_CALLDATA_MISMATCH:${scenario.id}`);
    const directConfig = jsonSafe(decodeProjectConfig(scenario.form.templateId, scenario.form.version, directInput.commonConfig, directInput.templateConfig)) as Record<string, unknown>;
    const indexConfig = await readIndexedConfig(input.runtime, input.releaseCommit, indexProject, factoryTransaction.hash as Hex, factoryTransaction.receipt.blockHash as Hex, input.fetcher ?? fetch);
    compareConfig(formConfig, normalizedChainConfig, directConfig);
    compareConfig(formConfig, directConfig, indexConfig);
    const block = await rpc.primary.getBlock({ blockNumber: factoryTransaction.receipt.blockNumber });
    const provenance = await verifyTargets({
      targets: [
        ...input.plan.verificationTargets.map((target) => ({ target, transactionKey: `bootstrap:${target.creationTransaction}` })),
        ...scenario.verificationTargets.map((target) => ({ target, transactionKey: `${scenario.id}:${target.creationTransaction}` })),
      ],
      references, transactions, artifacts, runtime: input.runtime, rpc, chainTimestamp: block.timestamp, cache: verificationCache,
      verificationProofs: compiled.verificationProofs,
    });
    const addressEntries = provenance.deployedContracts.map(({ name, address }) => [name, address] as const);
    const evidence: EvidenceBundle = {
      schemaVersion: 1,
      releaseCommit: input.releaseCommit,
      scenario: scenario.id,
      chainId: 97,
      addresses: Object.fromEntries([
        ...[...references.entries()].filter((entry): entry is [string, string] => typeof entry[1] === "string" && publicAddress.test(entry[1])),
        ...addressEntries,
        ...(["A", "B", "C"] as const).map((slot) => [`wallet${slot}`, accounts[slot].address] as const),
      ]),
      deployedContracts: provenance.deployedContracts,
      transactions: [...bootstrapTransactions, ...scenarioTransactions],
      rpcSnapshots: [...bootstrapSnapshots, ...scenarioSnapshots],
      verification: provenance.verification,
      config: {
        form: formConfig,
        encoded: { commonConfig: factoryEncoding.commonConfig, templateConfig: factoryEncoding.templateConfig, deploymentTransaction: factoryTransaction.hash },
        chain: normalizedChainConfig,
        direct: directConfig,
        index: indexConfig,
      },
    };
    bundles.push(evidence);
  }
  return bundles;
}
