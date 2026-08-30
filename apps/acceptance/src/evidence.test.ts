import { describe, expect, it } from "vitest";

import { validateEvidence, writeEvidence, type EvidenceBundle } from "./evidence";

const hash = (character: string) => `0x${character.repeat(64)}`;
const address = "0x1000000000000000000000000000000000000001";
const valid: EvidenceBundle = {
  schemaVersion: 1,
  releaseCommit: "abcdef1234567890abcdef1234567890abcdef12",
  scenario: "standard-mint",
  chainId: 97,
  addresses: { project: address },
  transactions: [{ stage: "DEPLOY", hash: hash("1"), receipt: { status: 1, blockNumber: 100n, blockHash: hash("2") }, requiredEvents: ["ProjectDeployed"], decodedEvents: [{ name: "ProjectDeployed", args: { project: address } }] }],
  rpcSnapshots: [{ stage: "DEPLOY", primary: { configHash: hash("3") }, secondary: { configHash: hash("3") } }],
  verification: [{ provider: "bscscan", status: "Verified", url: "https://testnet.bscscan.com/address/example" }, { provider: "sourcify", status: "Verified", url: "https://repo.sourcify.dev/contracts/full_match/97/example/" }],
  config: { form: { goal: "2" }, chain: { goal: "2" }, index: { goal: "2" } },
};

describe("release evidence", () => {
  it.each([
    ["missing transaction hash", { ...valid, transactions: [{ ...valid.transactions[0]!, hash: "" }] }],
    ["failed receipt", { ...valid, transactions: [{ ...valid.transactions[0]!, receipt: { ...valid.transactions[0]!.receipt, status: 0 as const } }] }],
    ["divergent finalized RPC values", { ...valid, rpcSnapshots: [{ ...valid.rpcSnapshots[0]!, secondary: { configHash: hash("4") } }] }],
    ["absent required event", { ...valid, transactions: [{ ...valid.transactions[0]!, decodedEvents: [] }] }],
    ["unverified source", { ...valid, verification: [{ provider: "bscscan", status: "Failed" as const }] }],
    ["form chain index mismatch", { ...valid, config: { ...valid.config, index: { goal: "3" } } }],
  ])("rejects %s", (_name, evidence) => {
    expect(() => validateEvidence(evidence)).toThrow();
  });

  it("serializes bigint evidence without leaking RPC credentials or private keys", () => {
    const output = writeEvidence(valid);
    expect(JSON.parse(output).transactions[0].receipt.blockNumber).toBe("100");
    expect(output).not.toMatch(/private.?key|api[_-]?key|https:\/\/[^\s\"]+@/i);
  });
});
