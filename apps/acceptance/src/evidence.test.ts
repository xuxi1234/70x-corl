import { describe, expect, it } from "vitest";

import { validateEvidence, writeEvidence, type EvidenceBundle } from "./evidence";
import { evidenceHash as hash, validTestEvidence } from "./test-evidence";

const valid: EvidenceBundle = validTestEvidence();

describe("release evidence", () => {
  it.each([
    ["missing transaction hash", { ...valid, transactions: [{ ...valid.transactions[0]!, hash: "" }] }],
    ["failed receipt", { ...valid, transactions: [{ ...valid.transactions[0]!, receipt: { ...valid.transactions[0]!.receipt, status: 0 as const } }] }],
    ["divergent finalized RPC values", { ...valid, rpcSnapshots: [{ ...valid.rpcSnapshots[0]!, secondary: { configHash: hash("4") } }] }],
    ["absent required event", { ...valid, transactions: [{ ...valid.transactions[0]!, decodedEvents: [] }] }],
    ["unverified source", { ...valid, verification: [{ provider: "bscscan", status: "Failed" as const }] }],
    ["form chain index mismatch", { ...valid, config: { ...valid.config, index: { goal: "3" } } }],
    ["missing public address", { ...valid, addresses: {} }],
    ["missing RPC stage", { ...valid, rpcSnapshots: [] }],
    ["missing verification provider", { ...valid, verification: [valid.verification[0]!] }],
    ["empty configuration", { ...valid, config: { ...valid.config, form: {}, chain: {}, direct: {}, index: {} } }],
    ["synthetic receipt missing gas provenance", { ...valid, transactions: [{ ...valid.transactions[0]!, receipt: { status: 1, blockNumber: 100n, blockHash: hash("2") } }] }],
    ["snapshot without approved independent provider identities", { ...valid, rpcSnapshots: [{ ...valid.rpcSnapshots[0]!, secondaryProvider: "publicnode" }] }],
    ["unverified deployed contract", { ...valid, verification: [valid.verification[0]!] }],
    ["deployment without bytecode provenance", { ...valid, deployedContracts: [{ ...valid.deployedContracts[0]!, creationBytecodeHash: hash("0") }] }],
    ["encoded config without its deployment transaction", { ...valid, config: { ...valid.config, encoded: { ...valid.config.encoded, deploymentTransaction: hash("f") } } }],
    ["Flap failure event claiming success", { ...valid, transactions: valid.transactions.map((transaction) => transaction.stage === "FLAP_FAIL" ? { ...transaction, decodedEvents: transaction.decodedEvents.map((event) => event.name === "ExecutionAttempt" ? { ...event, args: { ...event.args, success: true } } : event) } : transaction) }],
    ["refund amount differing from funded principal", { ...valid, transactions: valid.transactions.map((transaction) => transaction.stage === "REFUND" ? { ...transaction, decodedEvents: transaction.decodedEvents.map((event) => event.name === "Refunded" ? { ...event, args: { amount: "99" } } : event) } : transaction) }],
    ["one transaction hash reused across two lifecycle stages", { ...valid, transactions: valid.transactions.map((transaction, index) => index === 1 ? { ...transaction, hash: valid.transactions[0]!.hash } : transaction) }],
    ["wrong canonical deployment fee", { ...valid, transactions: valid.transactions.map((transaction) => transaction.stage === "DEPLOY" ? { ...transaction, decodedEvents: transaction.decodedEvents.map((event) => event.name === "ProjectDeployed" ? { ...event, args: { ...event.args, fee: "1" } } : event) } : transaction) }],
    ["wrong canonical fee recipient", { ...valid, transactions: valid.transactions.map((transaction) => transaction.stage === "DEPLOY" ? { ...transaction, decodedEvents: transaction.decodedEvents.map((event) => event.name === "ProjectDeployed" ? { ...event, args: { ...event.args, recipient: "0x9000000000000000000000000000000000000009" } } : event) } : transaction) }],
    ["required event emitted by the wrong contract", { ...valid, transactions: valid.transactions.map((transaction) => transaction.stage === "MINT" ? { ...transaction, decodedEvents: transaction.decodedEvents.map((event) => ({ ...event, address: "0x9000000000000000000000000000000000000009" })) } : transaction) }],
    ["Flap mint that does not exactly fill the configured goal", { ...valid, transactions: valid.transactions.map((transaction) => transaction.stage === "MINT" ? { ...transaction, decodedEvents: transaction.decodedEvents.map((event) => event.name === "MintPurchased" ? { ...event, args: { ...event.args, paid: "99" } } : event) } : transaction) }],
    ["non-proportional Flap claim", { ...valid, transactions: valid.transactions.map((transaction) => transaction.stage === "CLAIM" ? { ...transaction, decodedEvents: transaction.decodedEvents.map((event) => event.name === "Claimed" ? { ...event, args: { ...event.args, tokenAmount: "99" } } : event) } : transaction) }],
  ])("rejects %s", (_name, evidence) => {
    expect(() => validateEvidence(evidence)).toThrow();
  });

  it("accepts nested RPC values regardless of object insertion order", () => {
    const reordered = {
      ...valid,
      rpcSnapshots: valid.rpcSnapshots.map((snapshot) => ({ ...snapshot, primary: { ...snapshot.primary, nested: { a: 1, b: 2 } }, secondary: { ...snapshot.secondary, nested: { b: 2, a: 1 } } })),
    };
    expect(() => validateEvidence(reordered)).not.toThrow();
  });

  it("requires exact standard-fill, claim, failed-finalization, and refund economics", () => {
    const standard = validTestEvidence("standard-mint");
    expect(() => validateEvidence(standard)).not.toThrow();
    const tampered = {
      ...standard,
      rpcSnapshots: standard.rpcSnapshots.map((snapshot) => snapshot.stage === "CLAIM"
        ? { ...snapshot, primary: { ...snapshot.primary, claimTokenAllocation: "99" }, secondary: { ...snapshot.secondary, claimTokenAllocation: "99" } }
        : snapshot),
    };
    expect(() => validateEvidence(tampered)).toThrow("ECONOMIC_CLAIM_PROPORTION_INVALID");
  });

  it("rejects approval evidence whose observed allowance exceeds the exact planned funding", () => {
    const rewards = validTestEvidence("time-weighted-rewards");
    expect(() => validateEvidence(rewards)).not.toThrow();
    const overApproved = {
      ...rewards,
      rpcSnapshots: rewards.rpcSnapshots.map((snapshot) => snapshot.stage === "REWARD_APPROVE"
        ? { ...snapshot, primary: { ...snapshot.primary, allowance: "1000000000000000001" }, secondary: { ...snapshot.secondary, allowance: "1000000000000000001" } }
        : snapshot),
    };
    expect(() => validateEvidence(overApproved)).toThrow("ECONOMIC_ASSET_APPROVAL_INVALID:REWARD_APPROVE");
    const unspent = {
      ...rewards,
      rpcSnapshots: rewards.rpcSnapshots.map((snapshot) => snapshot.stage === "REWARD_FUND"
        ? { ...snapshot, primary: { ...snapshot.primary, remainingAllowance: "1" }, secondary: { ...snapshot.secondary, remainingAllowance: "1" } }
        : snapshot),
    };
    expect(() => validateEvidence(unspent)).toThrow("ECONOMIC_ASSET_ALLOWANCE_REMAINS:REWARD_FUND");
  });

  it("serializes bigint evidence without leaking RPC credentials or private keys", () => {
    const output = writeEvidence(valid);
    expect(JSON.parse(output).transactions[0].receipt.blockNumber).toBe("100");
    expect(output).not.toMatch(/private.?key|api[_-]?key|https:\/\/[^\s\"]+@/i);
  });

  it("refuses credential-bearing URLs anywhere in otherwise matching evidence", () => {
    const credentialUrl = { endpoint: "https://indexer.example/config?apiKey=do-not-persist" };
    expect(() => writeEvidence({
      ...valid,
      config: { ...valid.config, form: credentialUrl, chain: credentialUrl, index: credentialUrl },
    })).toThrow("CREDENTIAL_URL_FORBIDDEN");
  });
});
