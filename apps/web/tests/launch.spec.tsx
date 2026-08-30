import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { decodeAbiParameters } from "viem";

import LaunchPage from "../app/launch/page";
import FlapLaunchPage from "../app/flap-launch/page";
import { templateFields } from "@70x/protocol";
import { LaunchWizard } from "../components/launch/launch-wizard";
import { buildFactoryTransaction, buildLaunchReview, templateCatalog, type LaunchDraft } from "../lib/chain";

const validDraft = {
  templateId: "STANDARD" as const,
  version: 1,
  name: "Seventy X",
  symbol: "70X",
  supply: "1000000000",
  buyTaxBps: 0,
  sellTaxBps: 0,
  receiver: "0x1000000000000000000000000000000000000001",
  rewardToken: "0x0000000000000000000000000000000000000000",
  rewardThreshold: "0",
  lpMode: 0,
  allocationBps: [0, 0, 0, 0] as [number, number, number, number],
  metadataHash: `0x${"00".repeat(32)}`,
  templateConfig: {
    totalShares: 10,
    pricePerShare: 100_000_000_000_000n,
    claimTokenBps: 2_000,
    minimumLiquidityOutput: 1n,
  },
};

describe("launch wizard", () => {
  it("encodes the reviewed configuration without changing a field", () => {
    const review = buildLaunchReview(validDraft);
    const [decoded] = decodeAbiParameters([{
      type: "tuple",
      components: [
        { name: "name", type: "string" }, { name: "symbol", type: "string" }, { name: "supply", type: "uint256" },
        { name: "buyTaxBps", type: "uint16" }, { name: "sellTaxBps", type: "uint16" }, { name: "receiver", type: "address" },
        { name: "rewardToken", type: "address" }, { name: "rewardThreshold", type: "uint256" }, { name: "lpMode", type: "uint8" },
        { name: "allocationBps", type: "uint16[4]" }, { name: "metadataHash", type: "bytes32" },
      ],
    }], review.commonConfig);
    expect(decoded.name).toBe("Seventy X");
    expect(decoded.supply).toBe(1_000_000_000n);
    expect(review.configHash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(review.templateConfig).not.toBe("0x");
    const transaction = buildFactoryTransaction(validDraft);
    expect(transaction.args[0]).toMatch(/^0x[0-9a-f]{64}$/);
    expect(transaction.data).toMatch(/^0x[0-9a-f]+$/);
  });

  it("rejects tax and template bounds before a wallet transaction is built", () => {
    expect(() => buildLaunchReview({ ...validDraft, buyTaxBps: 1001 })).toThrow();
    expect(() => buildLaunchReview({ ...validDraft, templateId: "UNKNOWN" } as unknown as LaunchDraft)).toThrow("UNKNOWN_TEMPLATE");
  });

  it("renders all eleven modes from one catalog on the deployment and Flap pages", () => {
    render(<LaunchPage />);
    for (const template of templateCatalog) expect(screen.getByRole("option", { name: template.label })).toBeInTheDocument();
    expect(screen.getByText(/0.005 BNB/)).toBeInTheDocument();

    const flap = render(<FlapLaunchPage />);
    expect(within(flap.container).getByRole("heading", { name: /Flap 发射模式/ })).toBeInTheDocument();
    expect(within(flap.container).getByRole("option", { name: "Flap 联合发射" })).toHaveValue("FLAP_JOINT");
  });

  it.each(templateCatalog)("renders protocol-owned fields for $id", (template) => {
    render(<LaunchWizard initialTemplateId={template.id} />);
    for (const field of templateFields[template.id]) {
      expect(screen.getByLabelText(field.label)).toBeInTheDocument();
    }
  });
});
