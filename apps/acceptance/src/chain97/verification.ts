import { encodeAbiParameters, keccak256, stringToHex, type AbiParameter, type Address, type Hex } from "viem";

import type { EvidenceBundle } from "../evidence";
import type { FoundryArtifact } from "./artifacts";

type FetchLike = typeof fetch;

const bscscanApiUrl = "https://api.etherscan.io/v2/api";
const sourcifyServerUrl = "https://sourcify.dev/server";
const canonical = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
  return JSON.stringify(value);
};

const parseResponse = async (response: Response) => {
  const body = await response.text();
  let parsed: { status?: string; result?: unknown } = {};
  try { parsed = JSON.parse(body) as typeof parsed; } catch { /* provider returned non-JSON */ }
  return { response, body, parsed };
};

const bscscanRequest = (apiKey: string, fields: Record<string, string>, fetcher: FetchLike) => fetcher(bscscanApiUrl, {
  method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ chainid: "97", module: "contract", apikey: apiKey, ...fields }),
});

const bscscanQuery = (apiKey: string, fields: Record<string, string>, fetcher: FetchLike) => {
  const query = new URLSearchParams({ chainid: "97", apikey: apiKey, ...fields });
  return fetcher(`${bscscanApiUrl}?${query}`);
};

function constructorParameters(artifact: FoundryArtifact): readonly AbiParameter[] {
  const constructor = artifact.abi.find((item) => item.type === "constructor");
  return constructor?.inputs ?? [];
}

export async function preflightVerificationServices(input: {
  bscscanApiKey: string;
  probeAddress: string;
  fetcher?: FetchLike;
}): Promise<void> {
  const fetcher = input.fetcher ?? fetch;
  const bscscan = await parseResponse(await bscscanQuery(input.bscscanApiKey, {
    module: "contract",
    action: "getsourcecode",
    address: input.probeAddress,
  }, fetcher));
  if (bscscan.response.status === 429) throw new Error("CHAIN97_BSCSCAN_RATE_LIMITED");
  if (!bscscan.response.ok || bscscan.parsed.status !== "1") {
    const result = String(bscscan.parsed.result ?? "");
    if (/free api access is not supported|upgrade.*plan|plan.*unsupported/i.test(result)) {
      throw new Error("CHAIN97_BSCSCAN_PLAN_UNSUPPORTED");
    }
    if (/invalid api key|missing.*api key|api key.*invalid/i.test(result)) {
      throw new Error("CHAIN97_BSCSCAN_API_KEY_INVALID");
    }
    throw new Error("CHAIN97_BSCSCAN_PREFLIGHT_FAILED");
  }
  const sourcify = await fetcher(`${sourcifyServerUrl}/chains`);
  if (!sourcify.ok) throw new Error("CHAIN97_SOURCIFY_PREFLIGHT_FAILED");
  const chains = await sourcify.json() as Array<{ chainId?: string | number; supported?: boolean }>;
  if (!Array.isArray(chains) || !chains.some(({ chainId, supported }) => Number(chainId) === 97 && supported === true)) {
    throw new Error("CHAIN97_SOURCIFY_CHAIN_UNSUPPORTED");
  }
}

export async function verifyDeployedContract(input: {
  address: string;
  artifact: FoundryArtifact;
  constructorArgs: readonly unknown[];
  bscscanApiKey: string;
  fetcher?: FetchLike;
  wait?: (milliseconds: number) => Promise<void>;
  maxAttempts?: number;
  runtimeCodeHash: Hex;
  creationTransactionHash: Hex;
}): Promise<{
  creationBytecodeHash: Hex;
  runtimeCodeHash: Hex;
  sourceHash: Hex;
  compilerVersion: string;
  constructorArguments: Hex;
  constructorArgumentsHash: Hex;
  verification: EvidenceBundle["verification"];
}> {
  const fetcher = input.fetcher ?? fetch;
  const wait = input.wait ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
  const maxAttempts = input.maxAttempts ?? 30;
  const parameters = constructorParameters(input.artifact);
  if (parameters.length !== input.constructorArgs.length) throw new Error(`CHAIN97_CONSTRUCTOR_ARGUMENT_MISMATCH:${input.artifact.artifactId}`);
  const constructorArguments = encodeAbiParameters(parameters, input.constructorArgs as never);
  const settings = input.artifact.standardJsonInput.settings as {
    optimizer?: { enabled?: boolean; runs?: number };
    evmVersion?: string;
  };

  const submission = await parseResponse(await bscscanRequest(input.bscscanApiKey, {
    action: "verifysourcecode",
    contractaddress: input.address,
    sourceCode: JSON.stringify(input.artifact.standardJsonInput),
    codeformat: "solidity-standard-json-input",
    contractname: `${input.artifact.sourceName}:${input.artifact.contractName}`,
    compilerversion: `v${input.artifact.compilerVersion}`,
    optimizationUsed: settings.optimizer?.enabled ? "1" : "0",
    runs: String(settings.optimizer?.runs ?? 0),
    evmversion: settings.evmVersion ?? "default",
    constructorArguements: constructorArguments.slice(2),
  }, fetcher));
  if (!submission.response.ok) throw new Error("CHAIN97_BSCSCAN_SUBMISSION_FAILED");
  const alreadyVerified = /already verified|pass - verified/i.test(String(submission.parsed.result));
  const guid = submission.parsed.status === "1" && typeof submission.parsed.result === "string"
    ? submission.parsed.result
    : undefined;
  if (!alreadyVerified && !guid) throw new Error("CHAIN97_BSCSCAN_SUBMISSION_FAILED");

  const sourcifySubmission = await parseResponse(await fetcher(`${sourcifyServerUrl}/v2/verify/97/${input.address}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      stdJsonInput: input.artifact.standardJsonInput,
      compilerVersion: input.artifact.compilerVersion,
      contractIdentifier: `${input.artifact.sourceName}:${input.artifact.contractName}`,
      creationTransactionHash: input.creationTransactionHash,
    }),
  }));
  const sourcifyAlreadyVerified = sourcifySubmission.response.status === 409
    && /already_verified/i.test(String((sourcifySubmission.parsed as { customCode?: unknown }).customCode));
  const verificationId = sourcifySubmission.response.status === 202
    && typeof (sourcifySubmission.parsed as { verificationId?: unknown }).verificationId === "string"
    ? (sourcifySubmission.parsed as { verificationId: string }).verificationId
    : undefined;
  if (!sourcifyAlreadyVerified && (!verificationId || !/^[0-9a-f-]{36}$/i.test(verificationId))) {
    throw new Error("CHAIN97_SOURCIFY_SUBMISSION_FAILED");
  }

  let bscscanVerified = alreadyVerified;
  let sourcifyVerified = sourcifyAlreadyVerified;
  for (let attempt = 0; attempt < maxAttempts && (!bscscanVerified || !sourcifyVerified); attempt += 1) {
    if (!bscscanVerified && guid) {
      const status = await parseResponse(await bscscanRequest(input.bscscanApiKey, { action: "checkverifystatus", guid }, fetcher));
      bscscanVerified = status.response.ok && (status.parsed.status === "1" || /already verified|pass - verified/i.test(String(status.parsed.result)));
    }
    if (!sourcifyVerified && verificationId) {
      const status = await parseResponse(await fetcher(`${sourcifyServerUrl}/v2/verify/${verificationId}`));
      const contract = (status.parsed as { contract?: Record<string, unknown> }).contract;
      sourcifyVerified = status.response.ok
        && (status.parsed as { isJobCompleted?: unknown }).isJobCompleted === true
        && contract?.match === "exact_match"
        && contract.chainId === "97"
        && String(contract.address).toLowerCase() === input.address.toLowerCase();
    }
    if (!bscscanVerified || !sourcifyVerified) await wait(10_000);
  }
  if (!bscscanVerified || !sourcifyVerified) throw new Error(`CHAIN97_SOURCE_VERIFICATION_INCOMPLETE:${input.address}`);

  const sourceStatus = await parseResponse(await bscscanRequest(input.bscscanApiKey, {
    action: "getsourcecode",
    address: input.address,
  }, fetcher));
  const sourceRecord = Array.isArray(sourceStatus.parsed.result) ? sourceStatus.parsed.result[0] as Record<string, unknown> | undefined : undefined;
  const expectedCompiler = `v${input.artifact.compilerVersion}`;
  const sourceText = typeof sourceRecord?.SourceCode === "string" ? sourceRecord.SourceCode.trim() : "";
  const normalizedSourceText = sourceText.startsWith("{{") && sourceText.endsWith("}}") ? sourceText.slice(1, -1) : sourceText;
  let explorerInput: unknown;
  try { explorerInput = JSON.parse(normalizedSourceText); } catch { throw new Error(`CHAIN97_BSCSCAN_METADATA_MISMATCH:${input.address}`); }
  if (
    !sourceStatus.response.ok || !sourceRecord || sourceRecord.CompilerVersion !== expectedCompiler
    || String(sourceRecord.ConstructorArguments ?? "").toLowerCase().replace(/^0x/, "") !== constructorArguments.slice(2).toLowerCase()
    || canonical(explorerInput) !== canonical(input.artifact.standardJsonInput)
  ) throw new Error(`CHAIN97_BSCSCAN_METADATA_MISMATCH:${input.address}`);

  const sourcifyContractResponse = await fetcher(`${sourcifyServerUrl}/v2/contract/97/${input.address}?fields=all`);
  let sourcifyContract: Record<string, unknown>;
  try { sourcifyContract = await sourcifyContractResponse.json() as Record<string, unknown>; } catch { throw new Error(`CHAIN97_SOURCIFY_METADATA_MISMATCH:${input.address}`); }
  let expectedMetadata: unknown;
  try { expectedMetadata = JSON.parse(input.artifact.metadataJson); } catch { throw new Error(`CHAIN97_ARTIFACT_METADATA_INVALID:${input.artifact.artifactId}`); }
  const sourcifyCompilation = sourcifyContract.compilation as Record<string, unknown> | undefined;
  const sourcifyDeployment = sourcifyContract.deployment as Record<string, unknown> | undefined;
  if (
    !sourcifyContractResponse.ok
    || sourcifyContract.match !== "exact_match"
    || sourcifyContract.chainId !== "97"
    || String(sourcifyContract.address).toLowerCase() !== input.address.toLowerCase()
    || String(sourcifyCompilation?.compilerVersion ?? "").replace(/^v/, "") !== input.artifact.compilerVersion
    || sourcifyCompilation?.fullyQualifiedName !== `${input.artifact.sourceName}:${input.artifact.contractName}`
    || sourcifyDeployment?.transactionHash !== input.creationTransactionHash
    || canonical(sourcifyContract.stdJsonInput) !== canonical(input.artifact.standardJsonInput)
    || canonical(sourcifyContract.metadata) !== canonical(expectedMetadata)
  ) throw new Error(`CHAIN97_SOURCIFY_METADATA_MISMATCH:${input.address}`);
  const sourcifySources = sourcifyContract.sources as Record<string, { content?: unknown }> | undefined;
  for (const [name, source] of Object.entries(input.artifact.standardJsonInput.sources)) {
    if (sourcifySources?.[name]?.content !== source.content) throw new Error(`CHAIN97_SOURCIFY_SOURCE_MISMATCH:${input.address}:${name}`);
  }

  const address = input.address as Address;
  const sourceHash = keccak256(stringToHex(canonical(input.artifact.standardJsonInput)));
  return {
    creationBytecodeHash: keccak256(input.artifact.bytecode),
    runtimeCodeHash: input.runtimeCodeHash,
    sourceHash,
    compilerVersion: input.artifact.compilerVersion,
    constructorArguments,
    constructorArgumentsHash: keccak256(constructorArguments),
    verification: [
      { address, provider: "bscscan", status: "Verified", url: `https://testnet.bscscan.com/address/${address}#code`, compilerVersion: input.artifact.compilerVersion, sourceHash, constructorArgumentsHash: keccak256(constructorArguments), runtimeCodeHash: input.runtimeCodeHash },
      { address, provider: "sourcify", status: "Verified", url: `https://repo.sourcify.dev/97/${address}`, compilerVersion: input.artifact.compilerVersion, sourceHash, constructorArgumentsHash: keccak256(constructorArguments), runtimeCodeHash: input.runtimeCodeHash },
    ],
  };
}
