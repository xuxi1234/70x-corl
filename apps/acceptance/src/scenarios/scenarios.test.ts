import { describe, expect, it } from "vitest";

import { validateEvidence } from "../evidence";
import { runLifecycleScenario, scenarios, type TransactionExecutor } from ".";

const txHash = `0x${"1".repeat(64)}`;
const blockHash = `0x${"2".repeat(64)}`;

describe("Chain 97 lifecycle scenarios", () => {
  it("defines exactly the eleven approved modes", () => {
    expect(scenarios.map((item) => item.id)).toHaveLength(11);
    expect(new Set(scenarios.map((item) => item.templateId)).size).toBe(11);
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
      verification: [{ provider: "bscscan", status: "Verified" }, { provider: "sourcify", status: "Verified" }],
      config: { form: { goal: "2" }, chain: { goal: "2" }, index: { goal: "2" } },
    });
    expect(() => validateEvidence(evidence)).not.toThrow();
    expect(evidence.transactions.map((item) => item.stage)).toEqual(["DEPLOY", "MINT", "FLAP_EXECUTE", "CLAIM"]);
  });
});
