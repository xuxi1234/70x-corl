import { keccak256, stringToHex, type Hex } from "viem";
import { z } from "zod";

export type ProviderStatus = "Pending" | "Verified" | "Failed" | "RateLimited";
export type VerificationProject = { chainId: number; address: string; transactionInput: Hex; creationBytecode: Hex; standardJsonInput: unknown };
export type VerificationAdapter = { name: "bscscan" | "sourcify"; submit(input: VerificationSubmission): Promise<{ status: ProviderStatus; url?: string }> };
export type VerificationSubmission = VerificationProject & { constructorArguments: Hex; sourceHash: Hex };
type FetchLike = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

const standardJsonSchema = z.object({
  language: z.literal("Solidity"),
  sources: z.record(z.string(), z.object({ content: z.string() })),
  settings: z.record(z.string(), z.unknown()),
});

const stable = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${stable(item)}`).join(",")}}`;
  return JSON.stringify(value);
};

export function prepareVerification(project: VerificationProject): VerificationSubmission {
  const parsed = standardJsonSchema.safeParse(project.standardJsonInput);
  if (!parsed.success) throw new Error("MALFORMED_STANDARD_JSON");
  if (!project.transactionInput.toLowerCase().startsWith(project.creationBytecode.toLowerCase())) throw new Error("CREATION_BYTECODE_MISMATCH");
  const suffix = `0x${project.transactionInput.slice(project.creationBytecode.length)}` as Hex;
  return { ...project, standardJsonInput: parsed.data, constructorArguments: suffix, sourceHash: keccak256(stringToHex(stable(parsed.data))) };
}

async function normalizeProviderResponse(response: Response): Promise<{ status: ProviderStatus; url?: string }> {
  const body = await response.text();
  if (response.status === 429 || /rate limit/i.test(body)) return { status: "RateLimited" };
  if (!response.ok) return { status: response.status >= 500 ? "Pending" : "Failed" };
  try {
    const parsed = JSON.parse(body) as { status?: string; result?: unknown };
    if (parsed.status === "0" && !/already verified/i.test(String(parsed.result))) return { status: "Failed" };
  } catch {
    if (!body.trim()) return { status: "Failed" };
  }
  return { status: "Verified" };
}

export class BscScanAdapter implements VerificationAdapter {
  readonly name = "bscscan" as const;
  constructor(private readonly apiKey: string, private readonly request: FetchLike = fetch) {}
  async submit(input: VerificationSubmission) {
    const response = await this.request("https://api-testnet.bscscan.com/api", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ module: "contract", action: "verifysourcecode", apikey: this.apiKey, contractaddress: input.address, constructorArguements: input.constructorArguments.slice(2), sourceCode: stable(input.standardJsonInput), codeformat: "solidity-standard-json-input" }),
    });
    const result = await normalizeProviderResponse(response);
    return { ...result, ...(result.status === "Verified" ? { url: `https://testnet.bscscan.com/address/${input.address}#code` } : {}) };
  }
}

export class SourcifyAdapter implements VerificationAdapter {
  readonly name = "sourcify" as const;
  constructor(private readonly baseUrl = "https://sourcify.dev/server", private readonly request: FetchLike = fetch) {}
  async submit(input: VerificationSubmission) {
    const response = await this.request(`${this.baseUrl.replace(/\/$/, "")}/verify`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ address: input.address, chain: String(input.chainId), files: { "metadata.json": stable(input.standardJsonInput) } }) });
    const result = await normalizeProviderResponse(response);
    return { ...result, ...(result.status === "Verified" ? { url: `https://repo.sourcify.dev/contracts/full_match/${input.chainId}/${input.address}/` } : {}) };
  }
}
