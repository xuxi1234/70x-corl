import { describe, expect, it } from "vitest";
import { PLATFORM_FEE_WEI } from "./index";

describe("protocol constants", () => {
  it("uses the approved 0.005 BNB fee", () => {
    expect(PLATFORM_FEE_WEI).toBe(5_000_000_000_000_000n);
  });
});
