import { describe, expect, it } from "vitest";

import { validateEvidence } from "../evidence";
import { runLifecycleScenario, scenarios, type TransactionExecutor } from ".";
import { templateIds } from "@70x/protocol";
import { canonicalReference, canonicalStagePolicy } from "../scenario-manifest";

const txHash = `0x${"1".repeat(64)}`;
const blockHash = `0x${"2".repeat(64)}`;
const project = "0x1000000000000000000000000000000000000001";
const factory = "0x2000000000000000000000000000000000000002";
const sourceHash = `0x${"3".repeat(64)}`;
const runtimeCodeHash = `0x${"4".repeat(64)}`;
const constructorArgumentsHash = `0x${"6".repeat(64)}`;
const verificationBase = { address: project, status: "Verified" as const, compilerVersion: "0.8.28+commit.7893614a", sourceHash, runtimeCodeHash, constructorArgumentsHash };
const argsFor = (stage: string, name: string) => name === "ProjectDeployed" ? { vault: project, fee: "5000000000000000", recipient: factory }
  : name === "MintPurchased" ? { shares: 1, paid: "100", totalSharesSold: 1 }
  : name === "ExecutionAttempt" ? { success: stage !== "FLAP_FAIL" }
  : name === "Refunded" ? { amount: "100" }
  : name === "RefundsEnabled" ? { enabledAt: "87400" }
  : name === "Launched" ? { token: project, pair: factory, purchasedAmount: "100" }
  : name === "Claimed" ? { account: project, tokenAmount: "100" }
  : {};

describe("Chain 97 lifecycle scenarios", () => {
  it("defines exactly the eleven approved modes", () => {
    expect(scenarios.map((item) => item.id)).toHaveLength(11);
    expect(new Set(scenarios.map((item) => item.templateId)).size).toBe(11);
    expect(new Set(scenarios.map((item) => item.templateId))).toEqual(new Set(templateIds));
  });

  it("runs stages through status-1 receipts, required events, dual RPC reads, and evidence validation", async () => {
    let activeEvents: string[] = [];
    let sent = 0;
    const executor: TransactionExecutor = {
      async send(stage) { activeEvents = stage.requiredEvents; sent += 1; return `0x${sent.toString(16).repeat(64)}`; },
      async waitReceipt() { const stage = scenarios[10]!.stages[sent - 1]!.name; const policy = canonicalStagePolicy("flap-joint-launch", stage); return { status: 1, blockNumber: 100n, blockHash, transactionIndex: 0, gasUsed: 100_000n, effectiveGasPrice: 3_000_000_000n, from: factory, to: project, contractAddress: null, logs: activeEvents.map((name, logIndex) => { const emitter = policy.events[logIndex]!.emitter; return { name, address: emitter === "factory" || emitter === "template" || emitter === "launchedPair" ? factory : project, logIndex, args: argsFor(stage, name) }; }) }; },
    };
    const evidence = await runLifecycleScenario({
      scenario: scenarios[10]!, executor, releaseCommit: "abcdef1234567890abcdef1234567890abcdef12",
      addresses: {
        project, walletA: factory, walletB: project, walletC: factory, factory,
        [canonicalReference("flap-joint-launch", "FLAP_JOINT", "template")]: factory,
        [canonicalReference("flap-joint-launch", "FLAP_JOINT", "primaryVault")]: project,
        [canonicalReference("flap-joint-launch", "FLAP_JOINT", "refundVault")]: project,
        [canonicalReference("flap-joint-launch", "FLAP_JOINT", "launchedToken")]: project,
        [canonicalReference("flap-joint-launch", "FLAP_JOINT", "launchedPair")]: factory,
      },
      deployedContracts: [{ name: "project", address: project, artifact: "LaunchToken.sol/LaunchToken", transactionHash: txHash, creationKind: "event", creationLocator: "ProjectDeployed.vault", creationTransactionInputHash: `0x${"7".repeat(64)}`, creationBytecodeHash: `0x${"5".repeat(64)}`, runtimeCodeHash, constructorArgumentsHash, sourceHash, compilerVersion: "0.8.28+commit.7893614a" }],
      readPrimary: async () => {
        const stage = scenarios[10]!.stages[sent - 1]!.name;
        const state = ({ MINT: "1", FLAP_FAIL: "1", FLAP_RETRY: "3", CLAIM: "5", REFUND_ENABLE: "4", REFUND: "5" } as Record<string, string>)[stage] ?? "0";
        return { state, totalPaid: "100", totalSharesSold: "1", lastFailureAt: "1100", lastFailureHash: sourceHash, token: project, pair: factory, purchasedAmount: "100", protectionDuration: "300", sellProtectedUntil: "2000", totalClaimedShares: "1", createdAt: "1000", filledAt: "0", totalRefundedShares: "1", blockTimestamp: "1100" };
      },
      readSecondary: async () => {
        const stage = scenarios[10]!.stages[sent - 1]!.name;
        const state = ({ MINT: "1", FLAP_FAIL: "1", FLAP_RETRY: "3", CLAIM: "5", REFUND_ENABLE: "4", REFUND: "5" } as Record<string, string>)[stage] ?? "0";
        return { state, totalPaid: "100", totalSharesSold: "1", lastFailureAt: "1100", lastFailureHash: sourceHash, token: project, pair: factory, purchasedAmount: "100", protectionDuration: "300", sellProtectedUntil: "2000", totalClaimedShares: "1", createdAt: "1000", filledAt: "0", totalRefundedShares: "1", blockTimestamp: "1100" };
      },
      rpcProviders: { primary: "publicnode", secondary: "bnbchain" },
      verification: [{ ...verificationBase, provider: "bscscan", url: `https://testnet.bscscan.com/address/${project}#code` }, { ...verificationBase, provider: "sourcify", url: `https://repo.sourcify.dev/contracts/full_match/97/${project}/` }],
      config: { form: { goal: "100", totalShares: 1, protectionDuration: "300", receiver: factory }, encoded: { commonConfig: "0x01", templateConfig: "0x02", deploymentTransaction: txHash }, chain: { goal: "100", totalShares: 1, protectionDuration: "300", receiver: factory }, direct: { goal: "100", totalShares: 1, protectionDuration: "300", receiver: factory }, index: { goal: "100", totalShares: 1, protectionDuration: "300", receiver: factory } },
    });
    expect(() => validateEvidence(evidence)).not.toThrow();
    expect(evidence.transactions.map((item) => item.stage)).toEqual([
      "DEPLOY", "MINT", "FLAP_FAIL", "FLAP_RETRY", "CLAIM", "REFUND_DEPLOY", "REFUND_MINT", "REFUND_ENABLE", "REFUND",
    ]);
  });

  it("executes specialized economic stages instead of documentation-only assertions", () => {
    const stages = Object.fromEntries(scenarios.map((item) => [item.templateId, item.stages.map((stage) => stage.name)]));
    expect(stages.TIME_WEIGHTED).toEqual(expect.arrayContaining(["REWARD_FUND", "REWARD_CLAIM"]));
    expect(stages.AUTO_BUYBACK).toEqual(expect.arrayContaining(["BUYBACK_FUND", "BUYBACK_EXECUTE"]));
    expect(stages.FINANCE_EXIT).toEqual(expect.arrayContaining(["POSITION_OPEN_NATIVE", "POSITION_OPEN_TOKEN", "POSITION_CLAIM_NATIVE", "POSITION_CLAIM_TOKEN"]));
    expect(stages.LAUNCH_LIMIT).toEqual(expect.arrayContaining(["LIMIT_ACTIVE_TRANSFER", "LIMIT_EXEMPT_TRANSFER", "LIMIT_EXPIRED_TRANSFER"]));
    expect(stages.WHITELIST).toContain("WHITELIST_EPOCH");
  });
});
