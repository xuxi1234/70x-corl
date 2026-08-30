import { describe, expect, it } from "vitest";
import {
  compareProjectConfig,
  decodeProjectConfig,
  encodeDeployment,
  templateIds,
  templateFields,
  templateSchemas,
  type TemplateId,
} from "../registry";

const zero = "0x0000000000000000000000000000000000000000";
const token = "0x0000000000000000000000000000000000001234";
const root = `0x${"11".repeat(32)}`;

const common = {
  name: "70X",
  symbol: "X",
  supply: 1_000_000n,
  buyTaxBps: 0,
  sellTaxBps: 0,
  receiver: token,
  rewardToken: token,
  rewardThreshold: 0n,
  lpMode: 0,
  allocationBps: [0, 0, 0, 0] as [number, number, number, number],
  metadataHash: root,
};

const launch = {
  totalShares: 10,
  pricePerShare: 100_000_000_000_000n,
  claimTokenBps: 2_000,
  minimumLiquidityOutput: 1n,
};

const samples: Record<TemplateId, unknown> = {
  STANDARD: launch,
  TIME_WEIGHTED: { launch, rewards: { maxMultiplierBps: 30_000, growthDuration: 86_400 } },
  LP_REWARDS: { launch, rewards: { lpToken: token, minimumEligibleBalance: 1n } },
  HOLDER_DEAD: { launch, rewards: { holderBps: 8_000, deadBps: 2_000 } },
  AUTO_BUYBACK: { launch, buyback: { threshold: 1n, maxSpend: 1n, maxSlippageBps: 500 } },
  TIMED_BUYBACK: {
    launch,
    buyback: { threshold: 1n, maxSpend: 1n, interval: 300, maxSlippageBps: 500 },
  },
  EXTERNAL_BURN: {
    launch,
    buyback: { targetToken: token, threshold: 1n, maxSpend: 1n, maxSlippageBps: 500 },
  },
  FINANCE_EXIT: { launch, supportedToken: token },
  LAUNCH_LIMIT: { launch, durationsMinutes: [5, 60], maximumWalletBps: [100, 500] },
  WHITELIST: { launch, initialRoot: root, whitelistDeadline: 1_900_000_000 },
  FLAP_JOINT: {
    goal: 2_000_000_000_000_000_000n,
    totalShares: 2,
    initialRoot: root,
    whitelistDeadline: 1_900_000_000,
    protectionDuration: 300,
  },
};

describe("eleven launch template schemas", () => {
  it("publishes eleven unique version-one IDs", () => {
    expect(templateIds).toHaveLength(11);
    expect(new Set(templateIds).size).toBe(11);
    for (const id of templateIds) {
      expect(templateSchemas[id].templateId).toBe(id);
      expect(templateSchemas[id].version).toBe(1);
      expect(templateFields[id].length).toBeGreaterThan(0);
    }
  });

  it.each(Object.entries(samples) as [TemplateId, unknown][])("round-trips the %s Solidity tuple", (templateId, config) => {
    const encoded = encodeDeployment({ templateId, version: 1, commonConfig: common, templateConfig: config });
    const decoded = decodeProjectConfig(templateId, 1, encoded.commonConfig, encoded.templateConfig);
    expect(compareProjectConfig({ commonConfig: common, templateConfig: config }, decoded)).toEqual({
      matches: true,
      differences: [],
    });
  });

  it("enforces common allocation conservation", () => {
    expect(() => encodeDeployment({
      templateId: "STANDARD",
      version: 1,
      commonConfig: { ...common, buyTaxBps: 100, allocationBps: [1, 2, 3, 4] },
      templateConfig: launch,
    })).toThrow(/allocations/i);
  });

  it("enforces specialized field bounds before ABI encoding", () => {
    expect(() => encodeDeployment({
      templateId: "STANDARD",
      version: 1,
      commonConfig: common,
      templateConfig: { ...launch, claimTokenBps: 10_000 },
    })).toThrow();
    expect(() => encodeDeployment({
      templateId: "TIMED_BUYBACK",
      version: 1,
      commonConfig: common,
      templateConfig: { launch, buyback: { threshold: 1n, maxSpend: 1n, interval: 299, maxSlippageBps: 1 } },
    })).toThrow();
    expect(() => encodeDeployment({
      templateId: "LAUNCH_LIMIT",
      version: 1,
      commonConfig: common,
      templateConfig: { launch, durationsMinutes: [60, 5], maximumWalletBps: [500, 100] },
    })).toThrow();
    expect(() => encodeDeployment({
      templateId: "FLAP_JOINT",
      version: 1,
      commonConfig: common,
      templateConfig: { ...samples.FLAP_JOINT as object, goal: 1n },
    })).toThrow();
  });

  it("refuses to encode or decode an unknown schema version", () => {
    expect(() => encodeDeployment({
      templateId: "STANDARD",
      version: 2 as 1,
      commonConfig: common,
      templateConfig: launch,
    })).toThrow(/UNKNOWN_TEMPLATE_VERSION/);
    expect(() => decodeProjectConfig("STANDARD", 2, "0x", "0x")).toThrow(/UNKNOWN_TEMPLATE_VERSION/);
  });

  it("reports field-level mismatches", () => {
    const encoded = encodeDeployment({ templateId: "STANDARD", version: 1, commonConfig: common, templateConfig: launch });
    const decoded = decodeProjectConfig("STANDARD", 1, encoded.commonConfig, encoded.templateConfig);
    const comparison = compareProjectConfig(
      { commonConfig: common, templateConfig: { ...launch, totalShares: 11 } },
      decoded,
    );
    expect(comparison.matches).toBe(false);
    expect(comparison.differences).toContain("templateConfig.totalShares");
  });

  it("rejects a zero address where a specialized contract address is required", () => {
    expect(() => encodeDeployment({
      templateId: "LP_REWARDS",
      version: 1,
      commonConfig: common,
      templateConfig: { launch, rewards: { lpToken: zero, minimumEligibleBalance: 1n } },
    })).toThrow();
  });
});
