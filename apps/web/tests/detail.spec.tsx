import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import ProjectPage from "../app/project/[address]/page";
import { reconcileProject } from "../lib/indexer";

describe("project detail consistency", () => {
  it("removes the verified badge when direct RPC and indexed config diverge", () => {
    const result = reconcileProject({ address: "0x1000000000000000000000000000000000000001", version: 1, configHash: "0xaaa", verification: "Verified" }, { configHash: "0xbbb" });
    expect(result.consistent).toBe(false);
    expect(result.verification).toBe("Mismatch");
  });

  it("forces unknown template versions into read-only mode", () => {
    const result = reconcileProject({ address: "0x1000000000000000000000000000000000000001", version: 99, configHash: "0xaaa", verification: "Verified" }, { configHash: "0xaaa" });
    expect(result.readOnly).toBe(true);
  });

  it("renders an accessible mobile-safe detail warning and recovery action", () => {
    render(<ProjectPage params={{ address: "0x1000000000000000000000000000000000000001" }} />);
    expect(screen.getByRole("main")).toHaveAttribute("data-mobile", "stack");
    expect(screen.getByRole("status")).toHaveTextContent(/RPC 一致性/);
    expect(screen.getByRole("button", { name: "重试读取" })).toBeInTheDocument();
  });
});
