import { describe, expect, it } from "vitest";

import {
  InMemoryReadModel,
  applyProtocolLogs,
  type ProtocolLog,
} from "./index";

const project = "0x1000000000000000000000000000000000000001";
const vault = "0x2000000000000000000000000000000000000002";
const buyer = "0x3000000000000000000000000000000000000003";
const refundProject = "0x6000000000000000000000000000000000000006";
const refundVault = "0x7000000000000000000000000000000000000007";

const logs: ProtocolLog[] = [
  { chainId: 97, blockNumber: 10n, blockHash: "0xa", txHash: "0x01", logIndex: 0, eventName: "ProjectDeployed", address: "0xfactory", args: { id: "STANDARD", version: 1, creator: buyer, token: project, vault, fee: 5n, recipient: project, commonConfigHash: "0xcafe" } },
  { chainId: 97, blockNumber: 11n, blockHash: "0xb", txHash: "0x02", logIndex: 0, eventName: "MintPurchased", address: vault, args: { buyer, shares: 2n, paid: 10n, totalSharesSold: 2n } },
  { chainId: 97, blockNumber: 12n, blockHash: "0xc", txHash: "0x03", logIndex: 0, eventName: "Filled", address: vault, args: { totalPaid: 10n } },
  { chainId: 97, blockNumber: 13n, blockHash: "0xd", txHash: "0x04", logIndex: 0, eventName: "ExecutionAttempt", address: vault, args: { success: false, resultHash: "0xfail" } },
  { chainId: 97, blockNumber: 14n, blockHash: "0xe", txHash: "0x05", logIndex: 0, eventName: "Launched", address: vault, args: { pair: "0x4000000000000000000000000000000000000004" } },
  { chainId: 97, blockNumber: 15n, blockHash: "0xf", txHash: "0x06", logIndex: 0, eventName: "Claimed", address: vault, args: { account: buyer, shares: 2n, tokenAmount: 50n } },
  { chainId: 97, blockNumber: 16n, blockHash: "0x10", txHash: "0x07", logIndex: 0, eventName: "RewardFunded", address: project, args: { amount: 8n } },
  { chainId: 97, blockNumber: 17n, blockHash: "0x11", txHash: "0x08", logIndex: 0, eventName: "RewardClaimed", address: project, args: { account: buyer, amount: 3n } },
  { chainId: 97, blockNumber: 18n, blockHash: "0x12", txHash: "0x09", logIndex: 0, eventName: "BuybackFunded", address: project, args: { amount: 7n, vaultBalance: 7n } },
  { chainId: 97, blockNumber: 19n, blockHash: "0x13", txHash: "0x0a", logIndex: 0, eventName: "BuybackExecuted", address: project, args: { nativeSpent: 2n, tokenBurned: 4n } },
  { chainId: 97, blockNumber: 20n, blockHash: "0x14", txHash: "0x0b", logIndex: 0, eventName: "LpLocked", address: project, args: { lpToken: "0x5000000000000000000000000000000000000005", amount: 9n, locker: project, beneficiary: buyer, unlockTime: 100n, lockId: 1n } },
  { chainId: 97, blockNumber: 21n, blockHash: "0x15", txHash: "0x0c", logIndex: 0, eventName: "OwnershipTransferred", address: project, args: { previousOwner: buyer, newOwner: project } },
  { chainId: 97, blockNumber: 22n, blockHash: "0x16", txHash: "0x0d", logIndex: 0, eventName: "FeeChanged", address: project, args: { oldFee: 1n, newFee: 2n } },
  { chainId: 97, blockNumber: 23n, blockHash: "0x17", txHash: "0x0e", logIndex: 0, eventName: "ProjectDeployed", address: "0xfactory", args: { id: "FLAP_JOINT", version: 1, creator: buyer, token: refundProject, vault: refundVault, fee: 5n, recipient: project, commonConfigHash: "0xbeef" } },
  { chainId: 97, blockNumber: 24n, blockHash: "0x18", txHash: "0x0f", logIndex: 0, eventName: "MintPurchased", address: refundVault, args: { buyer, shares: 1n, paid: 5n, totalSharesSold: 1n } },
  { chainId: 97, blockNumber: 25n, blockHash: "0x19", txHash: "0x10", logIndex: 0, eventName: "RefundsEnabled", address: refundVault, args: { enabledAt: 25n } },
  { chainId: 97, blockNumber: 26n, blockHash: "0x1a", txHash: "0x11", logIndex: 0, eventName: "Refunded", address: refundVault, args: { account: buyer, shares: 1n, nativeAmount: 5n } },
];

describe("event read model", () => {
  it("replays every lifecycle event idempotently", () => {
    const model = new InMemoryReadModel();
    applyProtocolLogs(model, logs, { finalizedBlock: 26n, confirmations: 12 });
    const first = model.snapshot();

    applyProtocolLogs(model, logs, { finalizedBlock: 26n, confirmations: 12 });

    expect(model.snapshot()).toEqual(first);
    expect(first.projects).toEqual([
      expect.objectContaining({ address: project, vault, templateId: "STANDARD", version: 1, status: "launched", configHash: "0xcafe" }),
      expect.objectContaining({ address: refundProject, vault: refundVault, status: "refunding" }),
    ]);
    expect(first.vaultStates).toEqual(expect.arrayContaining([
      expect.objectContaining({ vault, state: "launched", claimedTokens: 50n, rewardFunded: 8n, rewardClaimed: 3n, buybackFunded: 7n, buybackSpent: 2n, tokensBurned: 4n, lpDisposition: "locked" }),
      expect.objectContaining({ vault: refundVault, state: "refunding", refundedNative: 5n, totalPaid: 0n }),
    ]));
    expect(first.transactions).toHaveLength(logs.length);
    expect(first.transactions.every((item) => item.confirmations === 12 && item.finalized)).toBe(true);
    expect(first.protocolConfigs).toEqual([expect.objectContaining({ address: project, owner: project, fee: 2n })]);
    expect(first.cursor).toEqual({ chainId: 97, blockNumber: 26n, blockHash: "0x1a", confirmations: 12 });
  });

  it("rolls back orphaned blocks before applying the canonical replacement", () => {
    const model = new InMemoryReadModel();
    applyProtocolLogs(model, logs.slice(0, 2), { finalizedBlock: 11n, confirmations: 12 });

    const replacement: ProtocolLog = { ...logs[1]!, blockHash: "0xcanonical", txHash: "0x0b", args: { buyer, shares: 1n, paid: 5n, totalSharesSold: 1n } };
    applyProtocolLogs(model, [replacement], { finalizedBlock: 11n, confirmations: 12 });

    expect(model.snapshot().transactions.map((item) => item.txHash)).toEqual(["0x01", "0x0b"]);
    expect(model.snapshot().vaultStates[0]).toEqual(expect.objectContaining({ sharesSold: 1n, totalPaid: 5n }));
  });

  it("rejects unfinalized logs and never invents missing project fields", () => {
    const model = new InMemoryReadModel();
    expect(() => applyProtocolLogs(model, [{ ...logs[0]!, blockNumber: 20n }], { finalizedBlock: 19n, confirmations: 12 })).toThrow("UNFINALIZED_LOG");

    applyProtocolLogs(model, [logs[0]!], { finalizedBlock: 19n, confirmations: 12 });
    expect(model.snapshot().projects[0]).not.toHaveProperty("name");
  });
});
