export type EvidenceReceipt = {
  status: 0 | 1;
  blockNumber: bigint;
  blockHash: string;
  transactionIndex: number;
  gasUsed: bigint;
  effectiveGasPrice: bigint;
  from: string;
  to: string | null;
  contractAddress: string | null;
};
export type EvidenceTransaction = {
  scope: "bootstrap" | "lifecycle";
  stage: string;
  assertion: string;
  resumed: boolean;
  hash: string;
  receipt: EvidenceReceipt;
  requiredEvents: string[];
  decodedEvents: Array<{ name: string; address: string; logIndex: number; args: Record<string, unknown> }>;
};
export type EvidenceBundle = {
  schemaVersion: 1;
  releaseCommit: string;
  scenario: string;
  chainId: 97;
  addresses: Record<string, string>;
  deployedContracts: Array<{
    name: string;
    address: string;
    artifact: string;
    transactionHash: string;
    creationKind: "receipt" | "event";
    creationLocator: string;
    creationTransactionInputHash: string;
    creationBytecodeHash: string;
    runtimeCodeHash: string;
    constructorArgumentsHash: string;
    sourceHash: string;
    compilerVersion: string;
  }>;
  transactions: EvidenceTransaction[];
  rpcSnapshots: Array<{ scope: "bootstrap" | "lifecycle"; stage: string; blockNumber: bigint; blockHash: string; primaryProvider: "publicnode" | "bnbchain"; secondaryProvider: "publicnode" | "bnbchain"; primary: Record<string, unknown>; secondary: Record<string, unknown> }>;
  verification: Array<{
    address: string;
    provider: "bscscan" | "sourcify";
    status: "Pending" | "Verified" | "Failed";
    url?: string;
    compilerVersion: string;
    sourceHash: string;
    constructorArgumentsHash: string;
    runtimeCodeHash: string;
  }>;
  config: { form: Record<string, unknown>; encoded: { commonConfig: string; templateConfig: string; deploymentTransaction: string }; chain: Record<string, unknown>; direct: Record<string, unknown>; index: Record<string, unknown> };
};

const txHash = /^0x[0-9a-fA-F]{64}$/;
const nonzeroHash = /^0x(?!0{64}$)[0-9a-fA-F]{64}$/;
const encodedBytes = /^0x[0-9a-fA-F]+$/;
const publicAddress = /^0x[0-9a-fA-F]{40}$/;
const commitHash = /^[0-9a-f]{40}$/i;
const canonical = (value: unknown): string => {
  if (typeof value === "bigint") return JSON.stringify(value.toString());
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
  return JSON.stringify(value);
};

const credentialParameter = /^(api[-_]?key|access[-_]?token|auth(orization)?|credential|password|secret|signature|token)$/i;
const containsCredentialUrl = (value: unknown): boolean => {
  if (typeof value === "string" && /^https?:\/\//i.test(value)) {
    try {
      const url = new URL(value);
      return Boolean(url.username || url.password || [...url.searchParams.keys()].some((key) => credentialParameter.test(key)));
    } catch { return false; }
  }
  if (Array.isArray(value)) return value.some(containsCredentialUrl);
  if (value && typeof value === "object") return Object.values(value).some(containsCredentialUrl);
  return false;
};

export function validateEvidence(input: unknown): asserts input is EvidenceBundle {
  if (!input || typeof input !== "object") throw new Error("EVIDENCE_REQUIRED");
  const evidence = input as EvidenceBundle;
  if (containsCredentialUrl(evidence)) throw new Error("CREDENTIAL_URL_FORBIDDEN");
  if (evidence.schemaVersion !== 1 || evidence.chainId !== 97 || !commitHash.test(evidence.releaseCommit)) throw new Error("INVALID_RELEASE_IDENTITY");
  if (!evidence.scenario || !evidence.transactions?.length) throw new Error("EMPTY_SCENARIO");
  const addresses = Object.values(evidence.addresses ?? {});
  if (!addresses.length || addresses.some((address) => !publicAddress.test(address))) throw new Error("INVALID_ADDRESSES");
  if (!evidence.deployedContracts?.length) throw new Error("DEPLOYMENT_PROVENANCE_REQUIRED");
  const deployedNames = new Set<string>();
  const deployedAddresses = new Set<string>();
  for (const deployment of evidence.deployedContracts) {
    const normalizedAddress = deployment.address.toLowerCase();
    if (!deployment.name || deployedNames.has(deployment.name)) throw new Error("DUPLICATE_DEPLOYMENT_NAME");
    if (!publicAddress.test(deployment.address) || deployedAddresses.has(normalizedAddress)) throw new Error("INVALID_DEPLOYMENT_ADDRESS");
    if (!/^[A-Za-z0-9_./-]+\.sol\/[A-Za-z_][A-Za-z0-9_]*$/.test(deployment.artifact)) throw new Error(`INVALID_DEPLOYMENT_ARTIFACT:${deployment.name}`);
    if (
      !txHash.test(deployment.transactionHash) || !nonzeroHash.test(deployment.creationTransactionInputHash) || !nonzeroHash.test(deployment.creationBytecodeHash)
      || !nonzeroHash.test(deployment.runtimeCodeHash) || !nonzeroHash.test(deployment.constructorArgumentsHash)
      || !nonzeroHash.test(deployment.sourceHash) || !/^0\.8\.28([+-].*)?$/.test(deployment.compilerVersion)
      || !deployment.creationLocator || !["receipt", "event"].includes(deployment.creationKind)
    ) {
      throw new Error(`INVALID_DEPLOYMENT_PROVENANCE:${deployment.name}`);
    }
    deployedNames.add(deployment.name);
    deployedAddresses.add(normalizedAddress);
  }
  const transactionStages = new Set(evidence.transactions.map((transaction) => `${transaction.scope}:${transaction.stage}`));
  if (transactionStages.size !== evidence.transactions.length) throw new Error("DUPLICATE_TRANSACTION_STAGE");
  const transactionHashes = new Set(evidence.transactions.map((transaction) => transaction.hash.toLowerCase()));
  if (transactionHashes.size !== evidence.transactions.length) throw new Error("DUPLICATE_TRANSACTION_HASH");
  for (const transaction of evidence.transactions) {
    if (!transaction.assertion || typeof transaction.resumed !== "boolean" || !["bootstrap", "lifecycle"].includes(transaction.scope)) throw new Error(`INVALID_TRANSACTION_SCOPE:${transaction.stage}`);
    if (!txHash.test(transaction.hash)) throw new Error(`MISSING_TRANSACTION_HASH:${transaction.stage}`);
    const receipt = transaction.receipt;
    if (
      receipt.status !== 1 || !txHash.test(receipt.blockHash) || typeof receipt.blockNumber !== "bigint" || receipt.blockNumber <= 0n
      || !Number.isSafeInteger(receipt.transactionIndex) || receipt.transactionIndex < 0
      || typeof receipt.gasUsed !== "bigint" || receipt.gasUsed <= 0n
      || typeof receipt.effectiveGasPrice !== "bigint" || receipt.effectiveGasPrice <= 0n
      || !publicAddress.test(receipt.from)
      || (receipt.to !== null && !publicAddress.test(receipt.to))
      || (receipt.contractAddress !== null && !publicAddress.test(receipt.contractAddress))
      || (receipt.to === null && receipt.contractAddress === null)
    ) throw new Error(`FAILED_RECEIPT:${transaction.stage}`);
    const names = new Set(transaction.decodedEvents.map((event) => event.name));
    for (const event of transaction.decodedEvents) {
      if (!event.name || !publicAddress.test(event.address) || !Number.isSafeInteger(event.logIndex) || event.logIndex < 0) {
        throw new Error(`INVALID_EVENT_PROVENANCE:${transaction.stage}`);
      }
    }
    for (const required of transaction.requiredEvents) if (!names.has(required)) throw new Error(`MISSING_EVENT:${transaction.stage}:${required}`);
  }
  const manifest = canonicalScenarioById.get(evidence.scenario);
  if (!manifest) throw new Error("INVALID_SCENARIO");
  const lifecycle = evidence.transactions.filter(({ scope }) => scope === "lifecycle");
  if (lifecycle.length !== manifest.stages.length) throw new Error("LIFECYCLE_STAGE_COVERAGE_INVALID");
  for (let index = 0; index < manifest.stages.length; index += 1) {
    const expected = manifest.stages[index]!;
    const actual = lifecycle[index]!;
    if (actual.stage !== expected.name || actual.assertion !== expected.assertion || canonical(actual.requiredEvents) !== canonical(expected.requiredEvents)) {
      throw new Error(`LIFECYCLE_STAGE_INVALID:${expected.name}`);
    }
    const policy = canonicalStagePolicy(evidence.scenario, expected.name);
    for (const eventPolicy of policy.events) {
      const expectedEmitter = evidence.addresses[canonicalReference(evidence.scenario, manifest.templateId, eventPolicy.emitter)];
      if (!expectedEmitter || !actual.decodedEvents.some((event) => event.name === eventPolicy.name && event.address.toLowerCase() === expectedEmitter.toLowerCase())) {
        throw new Error(`LIFECYCLE_EVENT_EMITTER_INVALID:${expected.name}:${eventPolicy.name}`);
      }
    }
  }
  const snapshotStages = new Set((evidence.rpcSnapshots ?? []).map((snapshot) => `${snapshot.scope}:${snapshot.stage}`));
  if (snapshotStages.size !== transactionStages.size || [...transactionStages].some((stage) => !snapshotStages.has(stage))) throw new Error("RPC_STAGE_MISSING");
  const transactionsByStage = new Map(evidence.transactions.map((transaction) => [`${transaction.scope}:${transaction.stage}`, transaction]));
  for (const snapshot of evidence.rpcSnapshots ?? []) {
    const receipt = transactionsByStage.get(`${snapshot.scope}:${snapshot.stage}`)?.receipt;
    if (
      snapshot.primaryProvider === snapshot.secondaryProvider
      || new Set([snapshot.primaryProvider, snapshot.secondaryProvider]).size !== 2
      || snapshot.blockNumber !== receipt?.blockNumber
      || snapshot.blockHash.toLowerCase() !== receipt?.blockHash.toLowerCase()
    ) throw new Error(`RPC_IDENTITY_INVALID:${snapshot.stage}`);
    if (!Object.keys(snapshot.primary ?? {}).length || canonical(snapshot.primary) !== canonical(snapshot.secondary)) throw new Error(`RPC_DIVERGENCE:${snapshot.stage}`);
  }
  validateEconomicEvents(evidence, lifecycle);
  validateCanonicalStatePredicates(evidence, manifest);
  const verificationKeys = new Set<string>();
  for (const attempt of evidence.verification ?? []) {
    const key = `${attempt.address.toLowerCase()}:${attempt.provider}`;
    const deployment = evidence.deployedContracts.find(({ address }) => address.toLowerCase() === attempt.address.toLowerCase());
    if (
      verificationKeys.has(key) || !publicAddress.test(attempt.address) || attempt.status !== "Verified" || !validVerificationUrl(attempt)
      || !deployment || attempt.compilerVersion !== deployment.compilerVersion || attempt.sourceHash.toLowerCase() !== deployment.sourceHash.toLowerCase()
      || attempt.constructorArgumentsHash.toLowerCase() !== deployment.constructorArgumentsHash.toLowerCase()
      || attempt.runtimeCodeHash.toLowerCase() !== deployment.runtimeCodeHash.toLowerCase()
    ) {
      throw new Error("SOURCE_UNVERIFIED");
    }
    verificationKeys.add(key);
  }
  for (const address of deployedAddresses) {
    if (!verificationKeys.has(`${address}:bscscan`) || !verificationKeys.has(`${address}:sourcify`)) throw new Error("SOURCE_UNVERIFIED");
  }
  const transactionByHash = new Map(evidence.transactions.map((transaction) => [transaction.hash.toLowerCase(), transaction]));
  for (const deployment of evidence.deployedContracts) {
    const transaction = transactionByHash.get(deployment.transactionHash.toLowerCase());
    if (!transaction) throw new Error(`DEPLOYMENT_TRANSACTION_MISSING:${deployment.name}`);
    if (deployment.creationKind === "receipt") {
      if (transaction.receipt.contractAddress?.toLowerCase() !== deployment.address.toLowerCase() || deployment.creationLocator !== "receipt.contractAddress") throw new Error(`DEPLOYMENT_RECEIPT_BINDING_INVALID:${deployment.name}`);
    } else {
      const [eventName, argument] = deployment.creationLocator.split(".");
      const found = transaction.decodedEvents.some((event) => event.name === eventName && typeof event.args[argument!] === "string" && String(event.args[argument!]).toLowerCase() === deployment.address.toLowerCase());
      if (!found) throw new Error(`DEPLOYMENT_EVENT_BINDING_INVALID:${deployment.name}`);
    }
  }
  if (!Object.keys(evidence.config?.form ?? {}).length) throw new Error("EMPTY_CONFIG");
  const encoded = evidence.config?.encoded;
  if (!encodedBytes.test(encoded?.commonConfig ?? "") || !encodedBytes.test(encoded?.templateConfig ?? "") || !txHash.test(encoded?.deploymentTransaction ?? "")) throw new Error("INVALID_ENCODED_CONFIG");
  if (!evidence.transactions.some(({ hash }) => hash.toLowerCase() === encoded.deploymentTransaction.toLowerCase())) throw new Error("CONFIG_TRANSACTION_MISSING");
  if (
    canonical(evidence.config.form) !== canonical(evidence.config.chain)
    || canonical(evidence.config.form) !== canonical(evidence.config.direct)
    || canonical(evidence.config.form) !== canonical(evidence.config.index)
  ) throw new Error("CONFIG_MISMATCH");
}

function validateEconomicEvents(evidence: EvidenceBundle, transactions: EvidenceTransaction[]) {
  const event = (stage: string, name: string) => transactions.find((transaction) => transaction.stage === stage)?.decodedEvents.find((item) => item.name === name);
  const uint = (value: unknown, label: string) => {
    try {
      const parsed = typeof value === "bigint" ? value : typeof value === "number" && Number.isSafeInteger(value) ? BigInt(value) : typeof value === "string" && /^\d+$/.test(value) ? BigInt(value) : -1n;
      if (parsed < 0n) throw new Error();
      return parsed;
    } catch { throw new Error(`ECONOMIC_EVENT_VALUE_INVALID:${label}`); }
  };
  const positive = (stage: string, name: string, argument: string) => {
    const found = event(stage, name);
    if (found && uint(found.args[argument], `${stage}:${name}:${argument}`) <= 0n) throw new Error(`ECONOMIC_EVENT_VALUE_INVALID:${stage}:${name}:${argument}`);
  };
  const findConfig = (name: string): unknown => {
    const visit = (value: unknown): unknown => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
      if (name in value) return (value as Record<string, unknown>)[name];
      for (const child of Object.values(value)) {
        const found = visit(child);
        if (found !== undefined) return found;
      }
      return undefined;
    };
    return visit(evidence.config.form);
  };
  const address = (value: unknown, label: string) => {
    if (typeof value !== "string" || !publicAddress.test(value)) throw new Error(`ECONOMIC_EVENT_VALUE_INVALID:${label}`);
    return value.toLowerCase();
  };
  const expectedReceiver = evidence.addresses.walletA ?? findConfig("receiver");
  for (const stage of ["DEPLOY", "REFUND_DEPLOY"] as const) {
    const deployed = event(stage, "ProjectDeployed");
    if (!deployed) continue;
    if (uint(deployed.args.fee, `${stage}:ProjectDeployed:fee`) !== 5_000_000_000_000_000n) throw new Error(`ECONOMIC_DEPLOYMENT_FEE_INVALID:${stage}`);
    if (expectedReceiver !== undefined && address(deployed.args.recipient, `${stage}:ProjectDeployed:recipient`) !== address(expectedReceiver, "config:receiver")) {
      throw new Error(`ECONOMIC_DEPLOYMENT_RECIPIENT_INVALID:${stage}`);
    }
  }
  for (const transaction of transactions) {
    if (transaction.requiredEvents.includes("MintPurchased")) {
      positive(transaction.stage, "MintPurchased", "shares");
      positive(transaction.stage, "MintPurchased", "paid");
    }
  }
  const flapFailure = event("FLAP_FAIL", "ExecutionAttempt");
  if (flapFailure && flapFailure.args.success !== false) throw new Error("ECONOMIC_FLAP_FAILURE_INVALID");
  const flapRetry = event("FLAP_RETRY", "ExecutionAttempt");
  if (flapRetry && flapRetry.args.success !== true) throw new Error("ECONOMIC_FLAP_RETRY_INVALID");
  if (evidence.scenario === "flap-joint-launch") {
    const mint = event("MINT", "MintPurchased");
    const launched = event("FLAP_RETRY", "Launched");
    const claimed = event("CLAIM", "Claimed");
    const goal = uint(findConfig("goal"), "config:goal");
    const totalShares = uint(findConfig("totalShares"), "config:totalShares");
    if (!mint || uint(mint.args.paid, "MINT:MintPurchased:paid") !== goal || uint(mint.args.shares, "MINT:MintPurchased:shares") !== totalShares) {
      throw new Error("ECONOMIC_FLAP_EXACT_FILL_INVALID");
    }
    if (!launched || !claimed) throw new Error("ECONOMIC_FLAP_LAUNCH_CLAIM_MISSING");
    const purchased = uint(launched.args.purchasedAmount, "FLAP_RETRY:Launched:purchasedAmount");
    const claimedAmount = uint(claimed.args.tokenAmount, "CLAIM:Claimed:tokenAmount");
    const claimedShares = uint(mint.args.shares, "MINT:MintPurchased:shares");
    if (claimedAmount * totalShares !== purchased * claimedShares) throw new Error("ECONOMIC_FLAP_CLAIM_PROPORTION_INVALID");
  }
  for (const [stage, name, argument] of [
    ["REWARD_FUND", "RewardFunded", "amount"], ["REWARD_CLAIM", "RewardClaimed", "amount"],
    ["BUYBACK_FUND", "BuybackFunded", "amount"], ["BUYBACK_EXECUTE", "BuybackExecuted", "nativeSpent"],
    ["BUYBACK_EXECUTE", "BuybackExecuted", "tokenBurned"], ["BUYBACK_EXECUTE", "Burned", "amount"],
    ["POSITION_OPEN_NATIVE", "PositionOpened", "principal"], ["POSITION_OPEN_TOKEN", "PositionOpened", "principal"],
    ["POSITION_FUND_NATIVE", "Funded", "amount"], ["POSITION_FUND_TOKEN", "Funded", "amount"],
    ["POSITION_CLAIM_NATIVE", "PositionClaimed", "amount"], ["POSITION_CLAIM_TOKEN", "PositionClaimed", "amount"],
    ["LIMIT_ACTIVE_TRANSFER", "Transfer", "amount"], ["LIMIT_EXEMPT_TRANSFER", "Transfer", "amount"], ["LIMIT_EXPIRED_TRANSFER", "Transfer", "amount"],
  ] as const) positive(stage, name, argument);
  const epoch = event("WHITELIST_EPOCH", "EpochAppended");
  if (epoch && (typeof epoch.args.root !== "string" || !nonzeroHash.test(epoch.args.root))) throw new Error("ECONOMIC_WHITELIST_ROOT_INVALID");
  const refundMint = event("REFUND_MINT", "MintPurchased");
  const refund = event("REFUND", "Refunded");
  if (refundMint && refund) {
    const refunded = refund.args.nativeAmount ?? refund.args.amount;
    if (uint(refundMint.args.paid, "REFUND_MINT:paid") !== uint(refunded, "REFUND:amount")) throw new Error("ECONOMIC_REFUND_AMOUNT_MISMATCH");
  }
}

function validateCanonicalStatePredicates(evidence: EvidenceBundle, manifest: NonNullable<ReturnType<typeof canonicalScenarioById.get>>) {
  const lifecycle = evidence.transactions.filter(({ scope }) => scope === "lifecycle");
  const transaction = (stage: string) => lifecycle.find((item) => item.stage === stage);
  const event = (stage: string, name: string) => transaction(stage)?.decodedEvents.find((item) => item.name === name);
  const snapshot = (stage: string) => evidence.rpcSnapshots.find((item) => item.scope === "lifecycle" && item.stage === stage)?.primary;
  const uint = (value: unknown, label: string) => {
    if ((typeof value === "string" && /^\d+$/.test(value)) || (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) || typeof value === "bigint") return BigInt(value);
    throw new Error(`ECONOMIC_STATE_VALUE_INVALID:${label}`);
  };
  const config = (name: string): unknown => {
    const visit = (value: unknown): unknown => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
      if (name in value) return (value as Record<string, unknown>)[name];
      for (const child of Object.values(value)) { const found = visit(child); if (found !== undefined) return found; }
      return undefined;
    };
    return visit(evidence.config.form);
  };
  for (const stage of manifest.stages) {
    const values = snapshot(stage.name);
    if (!values) throw new Error(`ECONOMIC_STATE_SNAPSHOT_MISSING:${stage.name}`);
    const policy = canonicalStagePolicy(evidence.scenario, stage.name);
    for (const read of policy.reads) if (!(read.name in values)) throw new Error(`ECONOMIC_STATE_READ_MISSING:${stage.name}:${read.name}`);
    for (const probe of policy.revertProbes) {
      const result = values[`revert:${probe.name}`];
      if (!result || typeof result !== "object" || (result as Record<string, unknown>).errorName !== probe.errorName || !nonzeroHash.test(String((result as Record<string, unknown>).dataHash ?? ""))) {
        throw new Error(`ECONOMIC_REVERT_PROBE_MISSING:${stage.name}:${probe.name}`);
      }
    }
  }
  for (const [stage, fundingStage, owner, spenderRole] of [
    ["REWARD_APPROVE", "REWARD_FUND", "walletA", "rewardVault"],
    ["POSITION_OPEN_TOKEN_APPROVE", "POSITION_OPEN_TOKEN", "walletB", "financeVault"],
    ["POSITION_FUND_TOKEN_APPROVE", "POSITION_FUND_TOKEN", "walletA", "financeVault"],
  ] as const) {
    if (!manifest.stages.some(({ name }) => name === stage)) continue;
    const approval = event(stage, "Approval");
    const spender = evidence.addresses[canonicalReference(evidence.scenario, manifest.templateId, spenderRole)];
    if (
      !approval || !spender || String(approval.args.owner).toLowerCase() !== String(evidence.addresses[owner]).toLowerCase()
      || String(approval.args.spender).toLowerCase() !== spender.toLowerCase() || uint(approval.args.value, `${stage}:value`) !== 1_000_000_000_000_000_000n
      || uint(snapshot(stage)!.allowance, `${stage}:allowance`) !== 1_000_000_000_000_000_000n
    ) throw new Error(`ECONOMIC_ASSET_APPROVAL_INVALID:${stage}`);
    if (uint(snapshot(fundingStage)!.remainingAllowance, `${fundingStage}:remainingAllowance`) !== 0n) {
      throw new Error(`ECONOMIC_ASSET_ALLOWANCE_REMAINS:${fundingStage}`);
    }
  }
  for (const predicate of manifest.economicPredicates) {
    if (predicate === "deployment-fee-recipient") continue; // checked against exact decoded ProjectDeployed values above
    if (predicate === "exact-fill") {
      const stages = evidence.scenario === "flap-joint-launch" ? ["MINT"] : evidence.scenario === "whitelist-mint" ? ["WHITELIST_PROOF_MINT", "WHITELIST_PUBLIC_MINT"] : ["MINT", "FILL"];
      const purchases = stages.map((stage) => event(stage, "MintPurchased"));
      if (purchases.some((item) => !item)) throw new Error("ECONOMIC_EXACT_FILL_EVENT_MISSING");
      const paid = purchases.reduce((sum, item, index) => sum + uint(item!.args.paid, `${stages[index]}:paid`), 0n);
      const shares = purchases.reduce((sum, item, index) => sum + uint(item!.args.shares, `${stages[index]}:shares`), 0n);
      const totalShares = uint(config("totalShares"), "config:totalShares");
      const goal = evidence.scenario === "flap-joint-launch" ? uint(config("goal"), "config:goal") : totalShares * uint(config("pricePerShare"), "config:pricePerShare");
      if (paid !== goal || shares !== totalShares) throw new Error("ECONOMIC_EXACT_FILL_INVALID");
      const filled = stages.map((stage) => event(stage, "Filled")).find(Boolean);
      if (filled && uint(filled.args.totalPaid, "Filled:totalPaid") !== goal) throw new Error("ECONOMIC_FILLED_TOTAL_INVALID");
      const finalValues = snapshot(stages[stages.length - 1]!)!;
      if (uint(finalValues.totalPaid, "fill:totalPaid") !== goal || uint(finalValues.totalSharesSold, "fill:totalSharesSold") !== totalShares || uint(finalValues.state, "fill:state") !== 1n) {
        throw new Error("ECONOMIC_EXACT_FILL_STATE_INVALID");
      }
      continue;
    }
    if (predicate === "proportional-claim") {
      const claim = event("CLAIM", "Claimed");
      if (!claim) throw new Error("ECONOMIC_PROPORTIONAL_CLAIM_MISSING");
      if (evidence.scenario === "flap-joint-launch") continue; // exact Flap ratio checked above
      const shares = uint(claim.args.shares, "CLAIM:shares");
      const amount = uint(claim.args.tokenAmount, "CLAIM:tokenAmount");
      const values = snapshot("CLAIM")!;
      if (amount * uint(values.totalShares, "CLAIM:totalShares") !== uint(values.claimTokenAllocation, "CLAIM:claimTokenAllocation") * shares) throw new Error("ECONOMIC_CLAIM_PROPORTION_INVALID");
      continue;
    }
    if (predicate === "failed-execution-preserves-principal") {
      const failed = event(evidence.scenario === "flap-joint-launch" ? "FLAP_FAIL" : "EXECUTE_FAIL", "ExecutionAttempt");
      const values = snapshot(evidence.scenario === "flap-joint-launch" ? "FLAP_FAIL" : "EXECUTE_FAIL")!;
      const totalShares = uint(config("totalShares"), "config:totalShares");
      const expectedPrincipal = evidence.scenario === "flap-joint-launch" ? uint(config("goal"), "config:goal") : totalShares * uint(config("pricePerShare"), "config:pricePerShare");
      if (
        !failed || failed.args.success !== false || uint(values.state, "failure:state") !== 1n || uint(values.totalPaid, "failure:totalPaid") !== expectedPrincipal
        || uint(values.lastFailureAt, "failure:lastFailureAt") === 0n || !nonzeroHash.test(String(values.lastFailureHash ?? ""))
      ) throw new Error("ECONOMIC_FAILED_EXECUTION_PRINCIPAL_INVALID");
      continue;
    }
    if (predicate === "refund-delay-and-proportion") {
      const enabled = event("REFUND_ENABLE", "RefundsEnabled");
      const values = snapshot("REFUND_ENABLE")!;
      const anchor = uint(values.filledAt, "REFUND_ENABLE:filledAt") || uint(values.createdAt, "REFUND_ENABLE:createdAt");
      if (!enabled || uint(enabled.args.enabledAt, "RefundsEnabled:enabledAt") < anchor + 86_400n || uint(values.state, "REFUND_ENABLE:state") !== 4n) throw new Error("ECONOMIC_REFUND_DELAY_INVALID");
      const minted = event("REFUND_MINT", "MintPurchased");
      const refunded = event("REFUND", "Refunded");
      const refundValues = snapshot("REFUND")!;
      const nativeAmount = refunded?.args.nativeAmount ?? refunded?.args.amount;
      if (
        !minted || !refunded || uint(nativeAmount, "REFUND:nativeAmount") !== uint(minted.args.paid, "REFUND_MINT:paid")
        || uint(refundValues.totalRefundedShares, "REFUND:totalRefundedShares") !== uint(minted.args.shares, "REFUND_MINT:shares")
        || (refunded.args.shares !== undefined && uint(refunded.args.shares, "REFUND:shares") !== uint(minted.args.shares, "REFUND_MINT:shares"))
      ) throw new Error("ECONOMIC_REFUND_PROPORTION_INVALID");
      continue;
    }
    if (predicate === "flap-retry-and-protection") {
      const launched = event("FLAP_RETRY", "Launched");
      const values = snapshot("FLAP_RETRY")!;
      const duration = uint(config("protectionDuration"), "config:protectionDuration");
      if (
        !launched || String(values.token).toLowerCase() !== String(launched.args.token).toLowerCase() || String(values.pair).toLowerCase() !== String(launched.args.pair).toLowerCase()
        || uint(values.purchasedAmount, "FLAP_RETRY:purchasedAmount") !== uint(launched.args.purchasedAmount, "FLAP_RETRY:Launched:purchasedAmount")
        || uint(values.protectionDuration, "FLAP_RETRY:protectionDuration") !== duration
      ) {
        throw new Error("ECONOMIC_FLAP_PROTECTION_INVALID");
      }
      continue;
    }
    if (predicate === "reward-funding-and-claim" || predicate === "lp-weight-and-reward") {
      const funded = event("REWARD_FUND", "RewardFunded") ?? event("REWARD_FUND", "HolderDeadFunded");
      const claimed = event("REWARD_CLAIM", "RewardClaimed");
      if (!funded || !claimed || uint(funded.args.amount, "REWARD_FUND:amount") !== 1_000_000_000_000_000_000n || uint(claimed.args.amount, "REWARD_CLAIM:amount") === 0n || uint(claimed.args.amount, "REWARD_CLAIM:amount") > uint(funded.args.amount, "REWARD_FUND:amount")) throw new Error("ECONOMIC_REWARD_FLOW_INVALID");
      if (uint(snapshot("REWARD_FUND")!.totalFunded, "REWARD_FUND:totalFunded") !== uint(funded.args.amount, "REWARD_FUND:amount") || uint(snapshot("REWARD_CLAIM")!.totalClaimed, "REWARD_CLAIM:totalClaimed") !== uint(claimed.args.amount, "REWARD_CLAIM:amount")) throw new Error("ECONOMIC_REWARD_STATE_INVALID");
      if (predicate === "lp-weight-and-reward") {
        const synced = event("LP_SYNC", "LpWeightSynced");
        if (!synced || String(config("lpToken")).toLowerCase() !== String(evidence.addresses.canonicalLpToken).toLowerCase() || String(synced.args.account).toLowerCase() !== String(evidence.addresses.walletB).toLowerCase() || uint(synced.args.lpBalance, "LP_SYNC:lpBalance") < uint(config("minimumEligibleBalance"), "config:minimumEligibleBalance") || uint(synced.args.newWeight, "LP_SYNC:newWeight") !== uint(synced.args.lpBalance, "LP_SYNC:lpBalance") || uint(snapshot("LP_SYNC")!.totalWeight, "LP_SYNC:totalWeight") < uint(synced.args.newWeight, "LP_SYNC:newWeight")) throw new Error("ECONOMIC_LP_WEIGHT_INVALID");
      }
      continue;
    }
    if (predicate === "tranche-aging-newest-first-cap") {
      const split = snapshot("TRANCHE_SPLIT")!;
      const returned = snapshot("TRANCHE_RETURN")!;
      const consumed = snapshot("TRANCHE_CONSUME")!;
      const growthDuration = uint(config("growthDuration"), "config:growthDuration");
      if (
        uint(returned.blockTimestamp, "TRANCHE_RETURN:blockTimestamp") < uint(split.blockTimestamp, "TRANCHE_SPLIT:blockTimestamp") + growthDuration
        || uint(returned.trancheCount, "TRANCHE_RETURN:trancheCount") !== uint(split.trancheCount, "TRANCHE_SPLIT:trancheCount") + 1n
        || uint(consumed.trancheCount, "TRANCHE_CONSUME:trancheCount") !== uint(split.trancheCount, "TRANCHE_SPLIT:trancheCount")
        || canonical(returned.tranche0) !== canonical(split.tranche0)
        || canonical(consumed.tranche0) !== canonical(split.tranche0)
        || uint(returned.trackedBalance, "TRANCHE_RETURN:trackedBalance") !== uint(split.trackedBalance, "TRANCHE_SPLIT:trackedBalance") + 1n
        || uint(consumed.trackedBalance, "TRANCHE_CONSUME:trackedBalance") !== uint(split.trackedBalance, "TRANCHE_SPLIT:trackedBalance")
        || uint(consumed.weightedBalance, "TRANCHE_CONSUME:weightedBalance") > uint(consumed.trackedBalance, "TRANCHE_CONSUME:trackedBalance") * uint(config("maxMultiplierBps"), "config:maxMultiplierBps") / 10_000n
      ) throw new Error("ECONOMIC_TRANCHE_INVARIANT_INVALID");
      const transfers = [["TRANCHE_SPLIT", "walletB", "walletC"], ["TRANCHE_RETURN", "walletC", "walletB"], ["TRANCHE_CONSUME", "walletB", "walletC"]] as const;
      for (const [stage, from, to] of transfers) {
        const transfer = event(stage, "Transfer");
        if (!transfer || String(transfer.args.from).toLowerCase() !== String(evidence.addresses[from]).toLowerCase() || String(transfer.args.to).toLowerCase() !== String(evidence.addresses[to]).toLowerCase() || uint(transfer.args.amount, `${stage}:amount`) !== 1n) throw new Error("ECONOMIC_TRANCHE_TRANSFER_INVALID");
      }
      continue;
    }
    if (predicate === "buyback-threshold-max-spend-slippage" || predicate === "scheduled-buyback-early-rejection") {
      const executed = event("BUYBACK_EXECUTE", "BuybackExecuted");
      const values = snapshot("BUYBACK_EXECUTE")!;
      const burned = event("BUYBACK_EXECUTE", "Burned");
      const funded = event("BUYBACK_FUND", "BuybackFunded");
      const floor = event("BUYBACK_FLOOR", "ExecutionFloorCommitted");
      const floorState = snapshot("BUYBACK_FLOOR")!;
      const threshold = uint(config("threshold"), "config:threshold");
      const maxSpend = uint(config("maxSpend"), "config:maxSpend");
      const spend = threshold < maxSpend ? threshold : maxSpend;
      if (
        !executed || !burned || !funded || !floor || uint(values.threshold, "BUYBACK_EXECUTE:threshold") !== threshold
        || uint(values.maxSpend, "BUYBACK_EXECUTE:maxSpend") !== maxSpend || uint(values.maxSlippageBps, "BUYBACK_EXECUTE:maxSlippageBps") !== uint(config("maxSlippageBps"), "config:maxSlippageBps")
        || uint(funded.args.amount, "BUYBACK_FUND:amount") !== threshold || uint(funded.args.vaultBalance, "BUYBACK_FUND:vaultBalance") !== threshold || uint(snapshot("BUYBACK_FUND")!.accountedFunds, "BUYBACK_FUND:accountedFunds") !== threshold
        || uint(executed.args.nativeSpent, "BUYBACK_EXECUTE:nativeSpent") !== spend || uint(values.accountedFunds, "BUYBACK_EXECUTE:accountedFunds") !== threshold - spend
        || uint(executed.args.tokenBurned, "BUYBACK_EXECUTE:tokenBurned") !== uint(burned.args.amount, "Burned:amount")
        || uint(executed.args.tokenBurned, "BUYBACK_EXECUTE:tokenBurned") < uint(values.floorMinimumOutput, "BUYBACK_EXECUTE:floorMinimumOutput")
        || uint(floor.args.inputAmount, "BUYBACK_FLOOR:inputAmount") !== spend || uint(floor.args.inputAmount, "BUYBACK_FLOOR:inputAmount") !== uint(floorState.floorInputAmount, "BUYBACK_FLOOR:floorInputAmount")
        || uint(floor.args.minimumOutput, "BUYBACK_FLOOR:minimumOutput") !== uint(floorState.floorMinimumOutput, "BUYBACK_FLOOR:floorMinimumOutput")
        || uint(floor.args.expiry, "BUYBACK_FLOOR:expiry") !== uint(floorState.floorExpiry, "BUYBACK_FLOOR:floorExpiry")
        || uint(floorState.floorExpiry, "BUYBACK_FLOOR:floorExpiry") <= uint(floorState.blockTimestamp, "BUYBACK_FLOOR:blockTimestamp")
      ) throw new Error("ECONOMIC_BUYBACK_BOUNDS_INVALID");
      if (predicate === "scheduled-buyback-early-rejection" && (uint(values.interval, "BUYBACK_EXECUTE:interval") !== uint(config("interval"), "config:interval") || uint(values.nextExecutionAt, "BUYBACK_EXECUTE:nextExecutionAt") <= uint(values.blockTimestamp, "BUYBACK_EXECUTE:blockTimestamp"))) throw new Error("ECONOMIC_BUYBACK_INTERVAL_INVALID");
      continue;
    }
    if (predicate === "finance-lifetime-cap") {
      for (const [stage, id, principal, asset] of [["POSITION_CLAIM_NATIVE", 0n, 10_000_000_000_000_000n, "0x0000000000000000000000000000000000000000"], ["POSITION_CLAIM_TOKEN", 1n, 1_000_000_000_000_000_000n, evidence.addresses.bscUsdt]] as const) {
        const openStage = id === 0n ? "POSITION_OPEN_NATIVE" : "POSITION_OPEN_TOKEN";
        const fundStage = id === 0n ? "POSITION_FUND_NATIVE" : "POSITION_FUND_TOKEN";
        const opened = event(openStage, "PositionOpened");
        const funded = event(fundStage, "Funded");
        const claimed = event(stage, "PositionClaimed");
        const position = snapshot(stage)!.position;
        if (
          !opened || !funded || !claimed || !Array.isArray(position) || position.length < 6 || uint(opened.args.positionId, `${stage}:openId`) !== id
          || String(opened.args.owner).toLowerCase() !== String(evidence.addresses.walletB).toLowerCase() || String(opened.args.asset).toLowerCase() !== String(asset).toLowerCase()
          || uint(opened.args.principal, `${stage}:openPrincipal`) !== principal || uint(opened.args.exitMultipleBps, `${stage}:openMultiple`) !== 20_000n
          || String(funded.args.asset).toLowerCase() !== String(asset).toLowerCase() || String(funded.args.funder).toLowerCase() !== String(evidence.addresses.walletA).toLowerCase() || uint(funded.args.amount, `${fundStage}:amount`) !== principal || uint(snapshot(fundStage)!.remainingPayout, `${fundStage}:remainingPayout`) !== principal * 2n
          || String(position[0]).toLowerCase() !== String(evidence.addresses.walletB).toLowerCase() || String(position[1]).toLowerCase() !== String(asset).toLowerCase()
          || uint(position[2], `${stage}:principal`) !== principal || uint(position[3], `${stage}:claimed`) !== principal * 2n || uint(position[4], `${stage}:exitMultipleBps`) !== 20_000n || position[5] !== true
          || uint(claimed.args.positionId, `${stage}:claimId`) !== id || uint(claimed.args.amount, `${stage}:amount`) !== principal * 2n || uint(claimed.args.lifetimeClaimed, `${stage}:lifetimeClaimed`) !== principal * 2n || claimed.args.closed !== true
        ) throw new Error("ECONOMIC_FINANCE_CAP_INVALID");
      }
      continue;
    }
    if (predicate === "wallet-limit-rejection-exemption-expiry") {
      const active = event("LIMIT_ACTIVE_TRANSFER", "Transfer");
      const exempt = event("LIMIT_EXEMPT_TRANSFER", "Transfer");
      const after = event("LIMIT_EXPIRED_TRANSFER", "Transfer");
      const activeValues = snapshot("LIMIT_ACTIVE_TRANSFER")!;
      const expired = snapshot("LIMIT_EXPIRED_TRANSFER")!;
      const durations = config("durationsMinutes");
      const duration = Array.isArray(durations) ? durations.reduce((sum, item, index) => sum + uint(item, `config:durationsMinutes.${index}`), 0n) * 60n : 0n;
      const limits = config("maximumWalletBps");
      if (
        !active || !exempt || !after || String(active.args.from).toLowerCase() !== String(evidence.addresses.walletB).toLowerCase() || String(active.args.to).toLowerCase() !== String(evidence.addresses.walletC).toLowerCase() || uint(active.args.amount, "LIMIT_ACTIVE_TRANSFER:amount") !== 1n
        || String(exempt.args.to).toLowerCase() !== "0x000000000000000000000000000000000000dead" || uint(exempt.args.amount, "LIMIT_EXEMPT_TRANSFER:amount") !== 1n
        || String(after.args.to).toLowerCase() !== String(evidence.addresses.walletC).toLowerCase() || uint(after.args.amount, "LIMIT_EXPIRED_TRANSFER:amount") !== 1n
        || !Array.isArray(durations) || !Array.isArray(limits) || !Array.isArray(activeValues.activeWindow) || uint(activeValues.activeWindow[0], "LIMIT_ACTIVE_TRANSFER:duration") !== uint(durations[0], "config:durationsMinutes.0") || uint(activeValues.activeWindow[1], "LIMIT_ACTIVE_TRANSFER:limit") !== uint(limits[0], "config:maximumWalletBps.0")
        || duration === 0n || uint(expired.blockTimestamp, "LIMIT_EXPIRED_TRANSFER:blockTimestamp") < uint(expired.activatedAt, "LIMIT_EXPIRED_TRANSFER:activatedAt") + duration
      ) throw new Error("ECONOMIC_WALLET_LIMIT_INVARIANT_INVALID");
      continue;
    }
    if (predicate === "whitelist-epoch-proof-public-transition") {
      const appended = event("WHITELIST_EPOCH", "EpochAppended");
      const proofMint = event("WHITELIST_PROOF_MINT", "MintPurchased");
      const publicMint = event("WHITELIST_PUBLIC_MINT", "MintPurchased");
      if (
        !appended || !proofMint || !publicMint || uint(appended.args.epoch, "WHITELIST_EPOCH:epoch") !== 1n || String(appended.args.root).toLowerCase() === String(config("initialRoot")).toLowerCase()
        || String(snapshot("WHITELIST_EPOCH")!.epochRoot).toLowerCase() !== String(appended.args.root).toLowerCase()
        || String(proofMint.args.buyer).toLowerCase() !== String(evidence.addresses.walletB).toLowerCase() || uint(proofMint.args.shares, "WHITELIST_PROOF_MINT:shares") !== 1n
        || String(publicMint.args.buyer).toLowerCase() !== String(evidence.addresses.walletC).toLowerCase() || snapshot("WHITELIST_PROOF_MINT")!.isPublic !== false || snapshot("WHITELIST_PUBLIC_MINT")!.isPublic !== true
      ) throw new Error("ECONOMIC_WHITELIST_TRANSITION_INVALID");
      continue;
    }
    if (predicate === "holder-dead-split") {
      const funded = event("REWARD_FUND", "HolderDeadFunded");
      const amount = uint(funded?.args.amount, "HolderDeadFunded:amount");
      if (!funded || amount !== 1_000_000_000_000_000_000n || uint(funded.args.holderAmount, "HolderDeadFunded:holderAmount") !== amount * uint(config("holderBps"), "config:holderBps") / 10_000n || uint(funded.args.deadAmount, "HolderDeadFunded:deadAmount") !== amount * uint(config("deadBps"), "config:deadBps") / 10_000n) throw new Error("ECONOMIC_HOLDER_DEAD_SPLIT_INVALID");
    }
  }
}

function validVerificationUrl(attempt: EvidenceBundle["verification"][number]): boolean {
  if (!attempt.url) return false;
  try {
    const url = new URL(attempt.url);
    if (url.protocol !== "https:" || url.username || url.password || url.search) return false;
    const normalizedAddress = attempt.address.toLowerCase();
    if (attempt.provider === "bscscan") {
      return url.hostname === "testnet.bscscan.com" && url.pathname.toLowerCase() === `/address/${normalizedAddress}` && url.hash === "#code";
    }
    return url.hostname === "repo.sourcify.dev" && url.pathname.toLowerCase() === `/97/${normalizedAddress}` && !url.hash;
  } catch {
    return false;
  }
}

const secretKey = /private.?key|mnemonic|api[_-]?key|rpc[_-]?(url|credential)/i;
const redact = (value: unknown, key = ""): unknown => {
  if (secretKey.test(key)) return "[REDACTED]";
  if (typeof value === "string") return value.replace(/https:\/\/[^/@\s]+@/g, "https://[REDACTED]@");
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([childKey, item]) => [childKey, redact(item, childKey)]));
  return value;
};

export function writeEvidence(input: EvidenceBundle): string {
  validateEvidence(input);
  return `${JSON.stringify(redact(input), null, 2)}\n`;
}
import { canonicalReference, canonicalScenarioById, canonicalStagePolicy } from "./scenario-manifest";
