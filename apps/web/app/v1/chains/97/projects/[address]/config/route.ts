import { buildIndexedConfigResponse, parseDeploymentBlock } from "@70x/indexer/http";
import { createPublicClient, http, isAddress, isAddressEqual, type Address, type Hex } from "viem";
import { bscTestnet } from "viem/chains";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const rpcUrl = process.env.CHAIN97_INDEXER_RPC?.trim() || "https://bsc-testnet-rpc.publicnode.com";
const client = createPublicClient({ chain: bscTestnet, transport: http(rpcUrl, { timeout: 12_000 }) });

export async function GET(request: Request, context: { params: Promise<{ address: string }> }) {
  const releaseCommit = process.env.VERCEL_GIT_COMMIT_SHA?.trim() || process.env.CHAIN97_RELEASE_COMMIT?.trim();
  const requestedCommit = new URL(request.url).searchParams.get("releaseCommit");
  const factory = new URL(request.url).searchParams.get("factory");
  const deploymentTransaction = new URL(request.url).searchParams.get("deploymentTransaction");
  const { address } = await context.params;
  if (!releaseCommit || !/^[0-9a-f]{40}$/i.test(releaseCommit) || requestedCommit?.toLowerCase() !== releaseCommit.toLowerCase()) {
    return Response.json({ error: "RELEASE_COMMIT_MISMATCH" }, { status: 409 });
  }
  if (!isAddress(address)) return Response.json({ error: "PROJECT_ADDRESS_INVALID" }, { status: 400 });
  if (!factory || !isAddress(factory)) return Response.json({ error: "FACTORY_ADDRESS_INVALID" }, { status: 400 });
  if (!deploymentTransaction || !/^0x[0-9a-f]{64}$/i.test(deploymentTransaction)) return Response.json({ error: "DEPLOYMENT_TRANSACTION_INVALID" }, { status: 400 });

  try {
    const latest = await client.getBlockNumber();
    const deploymentBlock = parseDeploymentBlock(new URL(request.url).searchParams.get("deploymentBlock"), latest);
    const receipt = await client.getTransactionReceipt({ hash: deploymentTransaction as Hex });
    if (receipt.blockNumber !== deploymentBlock || latest < receipt.blockNumber + 11n) return Response.json({ error: "PROJECT_NOT_INDEXED" }, { status: 404 });
    const transaction = await client.getTransaction({ hash: deploymentTransaction as Hex });
    for (const log of receipt.logs.filter((item) => isAddressEqual(item.address, factory))) {
      try {
        return Response.json(buildIndexedConfigResponse({
          releaseCommit: releaseCommit.toLowerCase(),
          factory,
          project: address as Address,
          deploymentLog: {
            address: log.address,
            data: log.data,
            topics: log.topics as [Hex, ...Hex[]],
            transactionHash: deploymentTransaction as Hex,
            blockHash: receipt.blockHash,
          },
          transactionInput: transaction.input,
        }));
      } catch { /* inspect the next factory log from the same receipt */ }
    }
    return Response.json({ error: "PROJECT_NOT_INDEXED" }, { status: 404 });
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("CHAIN97_INDEX_DEPLOYMENT_BLOCK_")) {
      return Response.json({ error: error.message }, { status: 400 });
    }
    return Response.json({ error: "INDEXER_RPC_UNAVAILABLE" }, { status: 503 });
  }
}
