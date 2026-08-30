import { describe, expect, it } from "vitest";

import { BscScanAdapter, InMemoryVerificationQueue, SourcifyAdapter, submitVerification, type VerificationAdapter, type VerificationProject } from "./index";

const project: VerificationProject = {
  chainId: 97,
  address: "0x1000000000000000000000000000000000000001",
  transactionInput: "0x6000cafe",
  creationBytecode: "0x6000",
  standardJsonInput: { language: "Solidity", sources: { "Token.sol": { content: "contract Token {}" } }, settings: {} },
};

const adapter = (name: "bscscan" | "sourcify", outcomes: Array<"Verified" | "Pending" | "Failed" | "RateLimited">): VerificationAdapter => ({
  name,
  async submit() { return { status: outcomes.shift() ?? "Verified", url: `https://${name}.example/address/${project.address}` }; },
});

describe("verification worker", () => {
  it("records BscScan and Sourcify success and extracts constructor arguments", async () => {
    const queue = new InMemoryVerificationQueue();
    const result = await submitVerification(project, [adapter("bscscan", ["Verified"]), adapter("sourcify", ["Verified"])], queue, 1_000);
    expect(result.overallStatus).toBe("Verified");
    expect(result.constructorArguments).toBe("0xcafe");
    expect(result.providers.map((item) => item.status)).toEqual(["Verified", "Verified"]);
    expect(result.sourceHash).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("keeps partial success pending and retries rate limits with a six-hour cap", async () => {
    const queue = new InMemoryVerificationQueue();
    const providers = [adapter("bscscan", ["Verified"]), adapter("sourcify", ["RateLimited", "RateLimited", "RateLimited", "Verified"])] as const;
    const first = await submitVerification(project, providers, queue, 1_000);
    expect(first.overallStatus).toBe("Pending");
    expect(first.nextRetryAt).toBe(61_000);

    await queue.retryPending(61_000);
    await queue.retryPending(181_000);
    const pending = queue.get(project.address)!;
    expect(pending.nextRetryAt! - 181_000).toBeLessThanOrEqual(6 * 60 * 60 * 1_000);
  });

  it("rejects malformed compiler metadata without calling a provider", async () => {
    const queue = new InMemoryVerificationQueue();
    await expect(submitVerification({ ...project, standardJsonInput: { nope: true } }, [adapter("bscscan", ["Verified"])], queue, 1_000)).rejects.toThrow("MALFORMED_STANDARD_JSON");
    expect(queue.get(project.address)).toBeUndefined();
  });

  it("is idempotent after both providers verify", async () => {
    const queue = new InMemoryVerificationQueue();
    const providers = [adapter("bscscan", ["Verified"]), adapter("sourcify", ["Verified"])] as const;
    const first = await submitVerification(project, providers, queue, 1_000);
    const second = await submitVerification(project, providers, queue, 2_000);
    expect(second).toEqual(first);
  });

  it("normalizes provider-specific success and rate-limit responses", async () => {
    const okFetch = async () => new Response(JSON.stringify({ status: "1", message: "OK", result: "guid" }), { status: 200 });
    const limitedFetch = async () => new Response(JSON.stringify({ status: "0", message: "NOTOK", result: "Max rate limit reached" }), { status: 429 });
    const input = { ...project, constructorArguments: "0xcafe" as const, sourceHash: `0x${"11".repeat(32)}` as const };

    await expect(new BscScanAdapter("key", okFetch).submit(input)).resolves.toMatchObject({ status: "Verified" });
    await expect(new SourcifyAdapter("https://sourcify.example", limitedFetch).submit(input)).resolves.toMatchObject({ status: "RateLimited" });
  });
});
