import { readFile } from "node:fs/promises";

import { describe, expect, it } from "vitest";

import { loadFoundryArtifact } from "./artifacts";
import { compileChain97Plan } from "./compiler";
import { calculateChain97Budgets, validateChain97Plan, type Chain97PlanInput } from "./executor";

const releaseCommit = "abcdef1234567890abcdef1234567890abcdef12";

describe("audited Chain 97 release plan", () => {
  it("validates and compiles the deterministic Flap lifecycle before broadcast", async () => {
    const source = await readFile(new URL("../../config/chain97-flap.json", import.meta.url), "utf8");
    const plan = validateChain97Plan(JSON.parse(source) as Chain97PlanInput, releaseCommit, ["flap-joint-launch"]);
    const scenario = plan.scenarios[0]!;
    const artifactIds = new Set<string>();
    for (const step of [...plan.bootstrap, ...scenario.steps]) {
      artifactIds.add(step.artifact);
      step.requiredEvents.forEach(({ artifact }) => artifactIds.add(artifact));
      step.reads.forEach(({ artifact }) => artifactIds.add(artifact));
    }
    [...plan.verificationTargets, ...scenario.verificationTargets].forEach(({ artifact }) => artifactIds.add(artifact));
    const artifacts = new Map(await Promise.all([...artifactIds].map(async (id) => [id, await loadFoundryArtifact(id, process.cwd())] as const)));

    const compiled = compileChain97Plan({
      plan,
      selectedScenarioIds: ["flap-joint-launch"],
      artifacts,
      walletAddresses: {
        A: "0x90105455f8e918e6680A1158F4473a919C4e1740",
        B: "0x574985bc56FdEF65Dc1A87c2D6c1cAa23Adf01A9",
        C: "0xC5A03910C90a787fAd4a77AFa9b7aB8Bb19b6FA4",
      },
    });

    expect(plan.releaseCommit).toBe(releaseCommit);
    expect(plan.checkpointMigrations).toEqual([expect.objectContaining({
      releaseCommit: "a2d28dfc7423943fa74a141911e2ccaa18f26dd8",
      planHash: "0x3d615ab0fd4f68566d783f0339bcc78d7b0dfb8bf1bbff094c0319ed498e0086",
      completedExecutionKeys: ["bootstrap:DEPLOY_REGISTRY", "bootstrap:DEPLOY_PLATFORM_CONFIG", "bootstrap:DEPLOY_FACTORY", "bootstrap:DEPLOY_FLAP_ADAPTER"],
      failedAttempt: expect.objectContaining({ executionKey: "bootstrap:DEPLOY_FLAP_TEMPLATE", gasLimit: "1200000" }),
    })]);
    expect(compiled.factoryDeployments.size).toBe(2);
    expect(compiled.verificationProofs.size).toBe(7);
    expect(calculateChain97Budgets(plan, ["flap-joint-launch"])).toEqual({
      A: 47_950_000_000_000_000n,
      B: 2_002_100_000_000_000_000n,
      C: 1_016_200_000_000_000_000n,
    });
  });
});
