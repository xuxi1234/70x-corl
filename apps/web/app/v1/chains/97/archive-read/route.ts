import { validateArchiveRequest } from "@70x/indexer/archive-policy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

async function rpc(endpoint: string, method: string, params: unknown[]) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    cache: "no-store",
  });
  if (!response.ok) throw new Error("UPSTREAM_HTTP_ERROR");
  const payload = await response.json() as { result?: unknown; error?: unknown };
  if (payload.error || payload.result === undefined) throw new Error("UPSTREAM_RPC_ERROR");
  return payload.result;
}

export async function POST(request: Request) {
  const endpoint = process.env.CHAIN97_INDEXER_RPC?.trim();
  if (!endpoint) return Response.json({ error: "ARCHIVE_RPC_UNAVAILABLE" }, { status: 503 });
  try {
    const input = validateArchiveRequest(await request.json());
    const tag = `0x${input.blockNumber.toString(16)}`;
    const block = await rpc(endpoint, "eth_getBlockByNumber", [tag, false]) as { hash?: string };
    if (!block.hash || block.hash.toLowerCase() !== input.blockHash.toLowerCase()) return Response.json({ error: "ARCHIVE_BLOCK_MISMATCH" }, { status: 409 });
    const result = await rpc(endpoint, input.method, [input.first, { blockHash: input.blockHash, requireCanonical: true }]);
    return Response.json({ result });
  } catch (error) {
    const message = error instanceof Error && error.message.startsWith("CHAIN97_ARCHIVE_") ? error.message : "ARCHIVE_READ_FAILED";
    return Response.json({ error: message }, { status: message === "ARCHIVE_READ_FAILED" ? 503 : 400 });
  }
}
