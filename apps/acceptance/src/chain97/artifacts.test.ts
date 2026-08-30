import { describe, expect, it } from "vitest";

import { loadFoundryArtifact } from "./artifacts";

describe("Foundry artifact loader", () => {
  it("loads the exact compiled ABI, creation bytecode, metadata, and source contents", async () => {
    const artifact = await loadFoundryArtifact("LaunchFactory.sol/LaunchFactory", process.cwd());

    expect(artifact.abi).toContainEqual(expect.objectContaining({ type: "function", name: "deploy" }));
    expect(artifact.bytecode).toMatch(/^0x[0-9a-f]+$/i);
    expect(artifact.contractName).toBe("LaunchFactory");
    expect(artifact.sourceName).toBe("src/core/LaunchFactory.sol");
    expect(artifact.standardJsonInput).toMatchObject({
      language: "Solidity",
      sources: { "src/core/LaunchFactory.sol": { content: expect.stringContaining("contract LaunchFactory") } },
    });
  });

  it("rejects traversal and missing artifacts without reading outside contracts/out", async () => {
    await expect(loadFoundryArtifact("../secret.sol/Secret", process.cwd())).rejects.toThrow("CHAIN97_ARTIFACT_INVALID");
    await expect(loadFoundryArtifact("Missing.sol/Missing", process.cwd())).rejects.toThrow("CHAIN97_ARTIFACT_MISSING");
  });
});
