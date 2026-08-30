import { describe, expect, it, vi } from "vitest";

import type { EvidenceBundle } from "./evidence";
import { runConfiguredAcceptance } from "./run";
import { validTestEvidence } from "./test-evidence";

const hash = (character: string) => `0x${character.repeat(64)}`;
const releaseCommit = "abcdef1234567890abcdef1234567890abcdef12";

function evidence(scenario: string): EvidenceBundle {
  return validTestEvidence(scenario);
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

  it("rejects a release override that differs from the manual Actions checkout SHA", async () => {
    await expect(runConfiguredAcceptance({
      argv: ["standard-mint"],
      env: { CHAIN97_EXECUTOR_MODULE: "./chain97-executor.ts", RELEASE_COMMIT: releaseCommit, GITHUB_SHA: "0123456789012345678901234567890123456789" },
      loadModule: async () => ({ runAcceptance: async () => [] }),
      persist: async () => undefined,
    })).rejects.toThrow("RELEASE_COMMIT_GITHUB_SHA_MISMATCH");
  });
});
