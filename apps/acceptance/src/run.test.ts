import { describe, expect, it, vi } from "vitest";

import type { EvidenceBundle } from "./evidence";
import { runConfiguredAcceptance } from "./run";

const hash = (character: string) => `0x${character.repeat(64)}`;
const releaseCommit = "abcdef1234567890abcdef1234567890abcdef12";

function evidence(scenario: string): EvidenceBundle {
  return {
    schemaVersion: 1,
    releaseCommit,
    scenario,
    chainId: 97,
    addresses: { project: "0x1000000000000000000000000000000000000001" },
    transactions: [{
      stage: "DEPLOY",
      hash: hash("1"),
      receipt: { status: 1, blockNumber: 100n, blockHash: hash("2") },
      requiredEvents: ["ProjectDeployed"],
      decodedEvents: [{ name: "ProjectDeployed", args: {} }],
    }],
    rpcSnapshots: [{ stage: "DEPLOY", primary: { configHash: hash("3") }, secondary: { configHash: hash("3") } }],
    verification: [{ provider: "bscscan", status: "Verified" }, { provider: "sourcify", status: "Verified" }],
    config: { form: { goal: "2" }, chain: { goal: "2" }, index: { goal: "2" } },
  };
}

describe("configured Chain 97 runner", () => {
  it("loads the live executor, validates its bundle, and persists release-bound evidence", async () => {
    const persist = vi.fn(async () => undefined);
    const loadModule = vi.fn(async () => ({
      runAcceptance: async ({ scenarioIds, releaseCommit: received }: { scenarioIds: string[]; releaseCommit: string }) => {
        expect(scenarioIds).toEqual(["standard-mint"]);
        expect(received).toBe(releaseCommit);
        return [evidence("standard-mint")];
      },
    }));

    await runConfiguredAcceptance({
      argv: ["standard-mint"],
      env: { CHAIN97_EXECUTOR_MODULE: "./chain97-executor.ts", RELEASE_COMMIT: releaseCommit },
      loadModule,
      persist,
    });

    expect(loadModule).toHaveBeenCalledWith("./chain97-executor.ts");
    expect(persist).toHaveBeenCalledWith(
      `docs/acceptance/evidence/${releaseCommit}/standard-mint.json`,
      expect.stringContaining('"scenario": "standard-mint"'),
    );
  });

  it("fails closed when the executor omits a selected scenario", async () => {
    await expect(runConfiguredAcceptance({
      argv: ["standard-mint"],
      env: { CHAIN97_EXECUTOR_MODULE: "./chain97-executor.ts", RELEASE_COMMIT: releaseCommit },
      loadModule: async () => ({ runAcceptance: async () => [] }),
      persist: async () => undefined,
    })).rejects.toThrow("MISSING_SCENARIO_EVIDENCE:standard-mint");
  });
});
