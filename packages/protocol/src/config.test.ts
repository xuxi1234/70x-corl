import { describe, expect, it } from "vitest";
import fixture from "../fixtures/common-config.json";
import {
  CommonConfigSchema,
  encodeCommonConfig,
  hashCommonConfig,
} from "./config";

const { expectedHash, ...commonConfigFixture } = fixture;

describe("canonical common configuration", () => {
  it("matches the cross-language ABI-encoded fixture hash", () => {
    expect(hashCommonConfig(commonConfigFixture)).toBe(expectedHash);
    expect(encodeCommonConfig(commonConfigFixture)).toHaveLength(2 + 608 * 2);
  });

  it.each(["0", "100000000001"])("rejects supply %s outside the approved whole-token range", (supply) => {
    expect(() => CommonConfigSchema.parse({ ...commonConfigFixture, supply })).toThrow();
  });

  it.each([1, Number.MAX_SAFE_INTEGER + 1, true])("rejects number or boolean supply input %s", (supply) => {
    expect(() => CommonConfigSchema.parse({ ...commonConfigFixture, supply })).toThrow();
  });

  it.each([500_000_000_000_000_001, true])(
    "rejects number or boolean reward threshold input %s",
    (rewardThreshold) => {
      expect(() => CommonConfigSchema.parse({ ...commonConfigFixture, rewardThreshold })).toThrow();
    },
  );

  it.each([
    ["buyTaxBps", -1],
    ["buyTaxBps", 1001],
    ["sellTaxBps", -1],
    ["sellTaxBps", 1001],
  ] as const)("rejects %s value %s outside 0..1000 bps", (field, value) => {
    expect(() => CommonConfigSchema.parse({ ...commonConfigFixture, [field]: value })).toThrow();
  });

  it("rejects the zero receiver", () => {
    expect(() => CommonConfigSchema.parse({
      ...commonConfigFixture,
      receiver: "0x0000000000000000000000000000000000000000",
    })).toThrow();
  });

  it("requires active tax allocations to total 10000 bps", () => {
    expect(() => CommonConfigSchema.parse({
      ...commonConfigFixture,
      allocationBps: [2500, 2500, 2500, 2499],
    })).toThrow();
  });

  it("requires every allocation to be zero when both taxes are zero", () => {
    expect(() => CommonConfigSchema.parse({
      ...commonConfigFixture,
      buyTaxBps: 0,
      sellTaxBps: 0,
    })).toThrow();

    expect(CommonConfigSchema.parse({
      ...commonConfigFixture,
      buyTaxBps: 0,
      sellTaxBps: 0,
      allocationBps: [0, 0, 0, 0],
    }).allocationBps).toEqual([0, 0, 0, 0]);
  });
});
