import { describe, expect, it } from "vitest";

import { validateEvidence } from "../evidence";
import { runLifecycleScenario, scenarios, type TransactionExecutor } from ".";
import { templateIds } from "@70x/protocol";

const txHash = `0x${"1".repeat(64)}`;
const blockHash = `0x${"2".repeat(64)}`;

describe("Chain 97 lifecycle scenarios", () => {
  it("defines exactly the eleven approved modes", () => {
    expect(scenarios.map((item) => item.id)).toHaveLength(11);
    expect(new Set(scenarios.map((item) => item.templateId)).size).toBe(11);
    expect(new Set(scenarios.map((item) => item.templateId))).toEqual(new Set(templateIds));
  });

  it("runs stages through status-1 receipts, required events, dual RPC reads, and evidence validation", async () => {
    let activeEvents: string[] = [];
    const executor: TransactionExecutor = {
      async send(stage) { activeEvents = stage.requiredEvents; return txHash; },
      async waitReceipt() { return { status: 1, blockNumber: 100n, blockHash, logs: activeEvents.map((name) => ({ name, args: {} })) }; },
    };
    const evidence = await runLifecycleScenario({
      scenario: scenarios[10]!, executor, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12",
      addresses: { project: "0x1000000000000000000000000000000000000001" },
      readPrimary: async () => ({ configHash: "0xabc" }), readSecondary: async () => ({ configHash: "0xabc" }),
      verification: [{ provider: "bscscan", status: "Verified", url: "https://testnet.bscscan.com/address/example" }, { provider: "sourcify", status: "Verified", url: "https://repo.sourcify.dev/contracts/full_match/97/example" }],
      config: { form: { goal: "2" }, chain: { goal: "2" }, index: { goal: "2" } },
    });
    expect(() => validateEvidence(evidence)).not.toThrow();
    expect(evidence.transactions.map((item) => item.stage)).toEqual([
      "DEPLOY", "MINT", "FLAP_FAIL", "FLAP_RETRY", "CLAIM", "REFUND_DEPLOY", "REFUND_MINT", "REFUND",
    ]);
  });

  it("executes specialized economic stages instead of documentation-only assertions", () => {
    const stages = Object.fromEntries(scenarios.map((item) => [item.templateId, item.stages.map((stage) => stage.name)]));
    expect(stages.TIME_WEIGHTED).toEqual(expect.arrayContaining(["REWARD_FUND", "REWARD_CLAIM"]));
    expect(stages.AUTO_BUYBACK).toEqual(expect.arrayContaining(["BUYBACK_FUND", "BUYBACK_EXECUTE"]));
    expect(stages.FINANCE_EXIT).toEqual(expect.arrayContaining(["POSITION_OPEN", "POSITION_CLAIM"]));
    expect(stages.LAUNCH_LIMIT).toContain("LIMIT_TRANSFER");
    expect(stages.WHITELIST).toContain("WHITELIST_EPOCH");
  });
});
