import { describe, expect, it } from "vitest";

import { buildIndexerConfigUrl } from "./engine";

describe("Chain 97 indexer request", () => {
  it("pins the deployment block so a 24-hour checkpoint cannot age out", () => {
    expect(buildIndexerConfigUrl(
      "https://indexer.example",
      "0x1000000000000000000000000000000000000001",
      "0x2000000000000000000000000000000000000002",
      "46d309fcf2e894881b3d85cbd0091fd7ab4e0f93",
      128000000n,
    )).toBe(
      "https://indexer.example/v1/chains/97/projects/0x1000000000000000000000000000000000000001/config?factory=0x2000000000000000000000000000000000000002&releaseCommit=46d309fcf2e894881b3d85cbd0091fd7ab4e0f93&deploymentBlock=128000000",
    );
  });
});
