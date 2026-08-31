import { describe, expect, it } from "vitest";

import { preflightVerificationServices, verifyDeployedContract } from "./verification";
import type { FoundryArtifact } from "./artifacts";

const deployedAddress = "0x1000000000000000000000000000000000000001";
const creationTransactionHash = `0x${"a".repeat(64)}` as const;
const artifact: FoundryArtifact = {
  artifactId: "Example.sol/Example",
  contractName: "Example",
  sourceName: "src/Example.sol",
  abi: [{ type: "constructor", stateMutability: "nonpayable", inputs: [{ name: "owner", type: "address" }] }],
  bytecode: "0x6000",
  deployedBytecode: "0x6001",
  compilerVersion: "0.8.28+commit.7893614a",
  metadata: { compiler: { version: "0.8.28+commit.7893614a" }, language: "Solidity", settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "cancun", compilationTarget: { "src/Example.sol": "Example" } }, sources: { "src/Example.sol": {} } },
  metadataJson: JSON.stringify({ compiler: { version: "0.8.28+commit.7893614a" } }),
  standardJsonInput: { language: "Solidity", sources: { "src/Example.sol": { content: "contract Example {}" } }, settings: { optimizer: { enabled: true, runs: 200 } } },
};

describe("Chain 97 source verification", () => {
  it("validates the BscScan credential and Sourcify Chain 97 support before broadcast", async () => {
    const requests: Array<{ url: string; body?: string }> = [];
    const fetcher: typeof fetch = async (input, init) => {
      requests.push({ url: String(input), ...(init?.body ? { body: String(init.body) } : {}) });
      if (String(input).includes("api.etherscan.io")) return new Response(JSON.stringify({ status: "1", result: [{}] }), { status: 200 });
      return new Response(JSON.stringify([{ chainId: 1, supported: true }, { chainId: 97, supported: true }]), { status: 200 });
    };

    await expect(preflightVerificationServices({ bscscanApiKey: "secret-key", probeAddress: deployedAddress, fetcher })).resolves.toBeUndefined();
    expect(requests[0]!.url).toContain("apikey=secret-key");
    expect(requests[0]!.url).toContain("module=contract");
    expect(requests[0]!.url).toContain("action=getsourcecode");
    expect(requests[0]!.url).not.toContain("action=balance");
    expect(requests[0]!.body).toBeUndefined();
  });

  it("rejects Chain 97 when Sourcify lists it but marks verification unsupported", async () => {
    const fetcher: typeof fetch = async (input) => String(input).includes("api.etherscan.io")
      ? new Response(JSON.stringify({ status: "1", result: [{}] }), { status: 200 })
      : new Response(JSON.stringify([{ chainId: 97, supported: false }]), { status: 200 });

    await expect(preflightVerificationServices({
      bscscanApiKey: "configured",
      probeAddress: deployedAddress,
      fetcher,
    })).rejects.toThrow("CHAIN97_SOURCIFY_CHAIN_UNSUPPORTED");
  });

  it.each([
    ["Free API access is not supported for this chain", "CHAIN97_BSCSCAN_PLAN_UNSUPPORTED"],
    ["Invalid API Key", "CHAIN97_BSCSCAN_API_KEY_INVALID"],
  ])("classifies a safe Etherscan V2 rejection without echoing its response (%s)", async (result, expected) => {
    const fetcher: typeof fetch = async () => new Response(JSON.stringify({ status: "0", result }), { status: 200 });

    await expect(preflightVerificationServices({
      bscscanApiKey: "never-print-this-secret",
      probeAddress: deployedAddress,
      fetcher,
    })).rejects.toThrow(expected);
  });

  it("classifies Etherscan rate limiting without exposing response data", async () => {
    const fetcher: typeof fetch = async () => new Response("gateway detail that must stay private", { status: 429 });

    await expect(preflightVerificationServices({
      bscscanApiKey: "never-print-this-secret",
      probeAddress: deployedAddress,
      fetcher,
    })).rejects.toThrow("CHAIN97_BSCSCAN_RATE_LIMITED");
  });

  it("returns public BscScan and Sourcify evidence only after both providers confirm", async () => {
    const requested: Array<{ url: string; body?: string }> = [];
    const fetcher: typeof fetch = async (input, init) => {
      const url = String(input);
      requested.push({ url, ...(init?.body ? { body: String(init.body) } : {}) });
      if (url.includes("api.etherscan.io") && init?.body && String(init.body).includes("verifysourcecode")) {
        return new Response(JSON.stringify({ status: "1", result: "verification-guid" }), { status: 200 });
      }
      if (url.includes("api.etherscan.io") && init?.body && String(init.body).includes("getsourcecode")) {
        return new Response(JSON.stringify({ status: "1", result: [{
          CompilerVersion: `v${artifact.compilerVersion}`,
          ConstructorArguments: deployedAddress.slice(2).padStart(64, "0"),
          SourceCode: JSON.stringify(artifact.standardJsonInput),
        }] }), { status: 200 });
      }
      if (url.includes("api.etherscan.io")) return new Response(JSON.stringify({ status: "1", result: "Pass - Verified" }), { status: 200 });
      if (url.endsWith(`/v2/verify/97/${deployedAddress}`)) {
        return new Response(JSON.stringify({ verificationId: "72d12273-0723-448e-a9f6-f7957128efa5" }), { status: 202 });
      }
      if (url.endsWith("/v2/verify/72d12273-0723-448e-a9f6-f7957128efa5")) {
        return new Response(JSON.stringify({
          isJobCompleted: true,
          verificationId: "72d12273-0723-448e-a9f6-f7957128efa5",
          contract: { match: "exact_match", creationMatch: "exact_match", runtimeMatch: "match", chainId: "97", address: deployedAddress },
        }), { status: 200 });
      }
      if (url.includes(`/v2/contract/97/${deployedAddress}?fields=all`)) {
        return new Response(JSON.stringify({
          match: "exact_match",
          creationMatch: "exact_match",
          runtimeMatch: "match",
          chainId: "97",
          address: deployedAddress,
          deployment: { transactionHash: creationTransactionHash },
          compilation: { compilerVersion: artifact.compilerVersion, fullyQualifiedName: `${artifact.sourceName}:${artifact.contractName}` },
          sources: Object.fromEntries(Object.entries(artifact.standardJsonInput.sources).map(([name, source]) => [name, { content: source.content }])),
          metadata: JSON.parse(artifact.metadataJson),
          stdJsonInput: artifact.standardJsonInput,
        }), { status: 200 });
      }
      return new Response("not found", { status: 404 });
    };

    const result = await verifyDeployedContract({
      address: deployedAddress,
      artifact,
      constructorArgs: [deployedAddress],
      runtimeCodeHash: `0x${"7".repeat(64)}`,
      creationTransactionHash,
      bscscanApiKey: "never-persist-this-key",
      fetcher,
      wait: async () => undefined,
      maxAttempts: 2,
    });

    expect(result.verification).toEqual([
      expect.objectContaining({ address: deployedAddress, provider: "bscscan", status: "Verified", url: `https://testnet.bscscan.com/address/${deployedAddress}#code` }),
      expect.objectContaining({ address: deployedAddress, provider: "sourcify", status: "Verified", url: `https://repo.sourcify.dev/97/${deployedAddress}` }),
    ]);
    expect(JSON.stringify(result)).not.toContain("never-persist-this-key");
    expect(requested.every(({ url }) => !url.includes("never-persist-this-key"))).toBe(true);
    const sourcifySubmission = requested.find(({ url }) => url.endsWith(`/v2/verify/97/${deployedAddress}`));
    expect(JSON.parse(sourcifySubmission!.body!)).toEqual({
      stdJsonInput: artifact.standardJsonInput,
      compilerVersion: artifact.compilerVersion,
      contractIdentifier: `${artifact.sourceName}:${artifact.contractName}`,
      creationTransactionHash,
    });
  });

  it("fails closed when either provider never confirms", async () => {
    const fetcher: typeof fetch = async (input, init) => {
      const url = String(input);
      if (url.includes("api.etherscan.io") && init?.body && String(init.body).includes("verifysourcecode")) {
        return new Response(JSON.stringify({ status: "1", result: "guid" }), { status: 200 });
      }
      if (url.includes("api.etherscan.io")) return new Response(JSON.stringify({ status: "0", result: "Pending in queue" }), { status: 200 });
      if (url.endsWith(`/v2/verify/97/${deployedAddress}`)) return new Response(JSON.stringify({ verificationId: "72d12273-0723-448e-a9f6-f7957128efa5" }), { status: 202 });
      if (url.endsWith("/v2/verify/72d12273-0723-448e-a9f6-f7957128efa5")) {
        return new Response(JSON.stringify({ isJobCompleted: false, verificationId: "72d12273-0723-448e-a9f6-f7957128efa5" }), { status: 200 });
      }
      return new Response("", { status: 404 });
    };

    await expect(verifyDeployedContract({
      address: deployedAddress,
      artifact,
      constructorArgs: [deployedAddress],
      runtimeCodeHash: `0x${"7".repeat(64)}`,
      creationTransactionHash,
      bscscanApiKey: "configured",
      fetcher,
      wait: async () => undefined,
      maxAttempts: 2,
    })).rejects.toThrow("CHAIN97_SOURCE_VERIFICATION_INCOMPLETE");
  });

  it("rejects an explorer's already-verified claim when compiler/source/constructor metadata is not exact", async () => {
    const fetcher: typeof fetch = async (input, init) => {
      const url = String(input);
      const body = String(init?.body ?? "");
      if (url.includes("api.etherscan.io") && body.includes("verifysourcecode")) return new Response(JSON.stringify({ status: "0", result: "Contract source code already verified" }), { status: 200 });
      if (url.includes("api.etherscan.io") && body.includes("getsourcecode")) return new Response(JSON.stringify({ status: "1", result: [{ CompilerVersion: "v0.8.27", ConstructorArguments: "", SourceCode: "{}" }] }), { status: 200 });
      if (url.endsWith(`/v2/verify/97/${deployedAddress}`)) return new Response(JSON.stringify({ customCode: "already_verified" }), { status: 409 });
      if (url.includes(`/v2/contract/97/${deployedAddress}?fields=all`)) {
        return new Response(JSON.stringify({
          match: "exact_match", chainId: "97", address: deployedAddress,
          deployment: { transactionHash: creationTransactionHash },
          compilation: { compilerVersion: artifact.compilerVersion, fullyQualifiedName: `${artifact.sourceName}:${artifact.contractName}` },
          sources: Object.fromEntries(Object.entries(artifact.standardJsonInput.sources).map(([name, source]) => [name, { content: source.content }])),
          metadata: JSON.parse(artifact.metadataJson), stdJsonInput: artifact.standardJsonInput,
        }), { status: 200 });
      }
      return new Response("", { status: 404 });
    };
    await expect(verifyDeployedContract({
      address: deployedAddress, artifact, constructorArgs: [deployedAddress], runtimeCodeHash: `0x${"7".repeat(64)}`,
      creationTransactionHash, bscscanApiKey: "configured", fetcher, wait: async () => undefined, maxAttempts: 1,
    })).rejects.toThrow("CHAIN97_BSCSCAN_METADATA_MISMATCH");
  });
});
