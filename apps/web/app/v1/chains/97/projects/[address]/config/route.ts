import { buildIndexedConfigResponse, parseDeploymentBlock } from "@70x/indexer/http";
import { createPublicClient, http, isAddress, isAddressEqual, parseAbiItem, type Address, type Hex } from "viem";
import { bscTestnet } from "viem/chains";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const projectDeployed = parseAbiItem("event ProjectDeployed(bytes32 indexed id, uint32 indexed version, address indexed creator, address token, address vault, uint96 fee, address recipient, bytes32 commonConfigHash)");
const rpcUrl = process.env.CHAIN97_INDEXER_RPC?.trim() || "https://bsc-testnet-rpc.publicnode.com";
const client = createPublicClient({ chain: bscTestnet, transport: http(rpcUrl, { timeout: 12_000 }) });

export async function GET(request: Request, context: { params: Promise<{ address: string }> }) {
  const releaseCommit = process.env.VERCEL_GIT_COMMIT_SHA?.trim() || process.env.CHAIN97_RELEASE_COMMIT?.trim();
  const requestedCommit = new URL(request.url).searchParams.get("releaseCommit");
  const { address } = await context.params;
  if (!releaseCommit || !/^[0-9a-f]{40}$/i.test(releaseCommit) || requestedCommit?.toLowerCase() !== releaseCommit.toLowerCase()) {
    return Response.json({ error: "RELEASE_COMMIT_MISMATCH" }, { status: 409 });
  }
  if (!isAddress(address)) return Response.json({ error: "PROJECT_ADDRESS_INVALID" }, { status: 400 });

  try {
    const latest = await client.getBlockNumber();
    const deploymentBlock = parseDeploymentBlock(new URL(request.url).searchParams.get("deploymentBlock"), latest);
    const logs = await client.getLogs({ event: projectDeployed, fromBlock: deploymentBlock, toBlock: deploymentBlock, strict: true });
    const match = logs.find((log) => isAddressEqual(log.args.token, address as Address) || isAddressEqual(log.args.vault, address as Address));
    if (match?.transactionHash && match.blockHash && latest >= match.blockNumber + 11n) {
      const transaction = await client.getTransaction({ hash: match.transactionHash });
      return Response.json(buildIndexedConfigResponse({
        releaseCommit: releaseCommit.toLowerCase(),
        project: address as Address,
        deploymentLog: {
          data: match.data,
          topics: match.topics as [Hex, ...Hex[]],
          transactionHash: match.transactionHash,
          blockHash: match.blockHash,
        },
        transactionInput: transaction.input,
      }));
    }
    return Response.json({ error: "PROJECT_NOT_INDEXED" }, { status: 404 });
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("CHAIN97_INDEX_DEPLOYMENT_BLOCK_")) {
      return Response.json({ error: error.message }, { status: 400 });
    }
    return Response.json({ error: "INDEXER_RPC_UNAVAILABLE" }, { status: 503 });
  }
}
