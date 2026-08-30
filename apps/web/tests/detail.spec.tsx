import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import ProjectPage from "../app/project/[address]/page";
import { reconcileProject } from "../lib/indexer";
import { TransactionProgress } from "../components/launch/transaction-progress";

describe("project detail consistency", () => {
  it("removes the verified badge when direct RPC and indexed config diverge", () => {
    const result = reconcileProject({ address: "0x1000000000000000000000000000000000000001", templateId: "STANDARD", version: 1, configHash: "0xaaa", verification: "Verified" }, { configHash: "0xbbb" });
    expect(result.consistent).toBe(false);
    expect(result.verification).toBe("Mismatch");
  });

  it("forces unknown template versions into read-only mode", () => {
    const result = reconcileProject({ address: "0x1000000000000000000000000000000000000001", templateId: "STANDARD", version: 99, configHash: "0xaaa", verification: "Verified" }, { configHash: "0xaaa" });
    expect(result.readOnly).toBe(true);
  });

  it("renders an accessible mobile-safe detail warning and recovery action", async () => {
    render(await ProjectPage({ params: Promise.resolve({ address: "0x1000000000000000000000000000000000000001" }) }));
    expect(screen.getByRole("main")).toHaveAttribute("data-mobile", "stack");
    expect(screen.getByRole("status")).toHaveTextContent(/RPC 一致性/);
    expect(screen.getByRole("button", { name: "重试读取" })).toBeInTheDocument();
  });

  it("keeps transaction failures recoverable and announced", () => {
    render(<TransactionProgress stage="error" onRetry={() => undefined} />);
    expect(screen.getByRole("status")).toHaveTextContent(/资金未被修改/);
    expect(screen.getByRole("button", { name: "重新尝试" })).toBeInTheDocument();
  });
});
