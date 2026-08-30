import { createPublicClient, http, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bscTestnet } from "viem/chains";

export const DEFAULT_CHAIN97_RPC_PRIMARY = "https://bsc-testnet-rpc.publicnode.com";
export const DEFAULT_CHAIN97_RPC_SECONDARY = "https://data-seed-prebsc-1-s1.bnbchain.org:8545";

type WalletSlot = "A" | "B" | "C";
type RunnerEnvironment = Record<string, string | undefined>;
type Chain97Provider = "publicnode" | "bnbchain";
type ResolvedRpcEndpoint = { endpoint: string; provider: Chain97Provider };

export type Chain97Wallet = { slot: WalletSlot; address: string };
export type Chain97PreflightResult = {
  chainId: 97;
  wallets: Array<Chain97Wallet & { balanceWei: bigint }>;
};
export type Chain97RpcClient = {
  getChainId(): Promise<number>;
  getBalance(input: { address: string }): Promise<bigint>;
};

const walletSlots: WalletSlot[] = ["A", "B", "C"];
const privateKeyPattern = /^0x[0-9a-fA-F]{64}$/;
const approvedChain97Providers: Record<string, Chain97Provider> = {
  "bsc-testnet-rpc.publicnode.com": "publicnode",
  "data-seed-prebsc-1-s1.bnbchain.org": "bnbchain",
  "data-seed-prebsc-2-s1.bnbchain.org": "bnbchain",
};

const defaultDeriveAddress = (privateKey: string) => privateKeyToAccount(privateKey as `0x${string}`).address;

const defaultCreateClient = (endpoint: string): Chain97RpcClient => {
  const client = createPublicClient({ chain: bscTestnet, transport: http(endpoint) });
  return {
    getChainId: () => client.getChainId(),
    getBalance: ({ address }) => client.getBalance({ address: address as Address }),
  };
};

const requiredPrivateKey = (env: RunnerEnvironment, slot: WalletSlot) => {
  const key = `CHAIN97_PRIVATE_KEY_${slot}`;
  const value = env[key]?.trim();
  if (!value) throw new Error(`${key}_MISSING`);
  if (!privateKeyPattern.test(value)) throw new Error(`${key}_INVALID`);
  return value;
};

const resolveRpcEndpoint = (env: RunnerEnvironment, name: "PRIMARY" | "SECONDARY"): ResolvedRpcEndpoint => {
  const key = `CHAIN97_RPC_${name}`;
  const endpoint = env[key]?.trim() || (name === "PRIMARY" ? DEFAULT_CHAIN97_RPC_PRIMARY : DEFAULT_CHAIN97_RPC_SECONDARY);
  let parsed: URL;
  try {
    parsed = new URL(endpoint);
    if (parsed.protocol !== "https:") throw new Error("HTTPS_REQUIRED");
  } catch {
    throw new Error(`${key}_INVALID`);
  }
  const provider = approvedChain97Providers[parsed.hostname.toLowerCase()];
  if (!provider) throw new Error(`${key}_PROVIDER_UNAPPROVED`);
  return { endpoint: parsed.toString(), provider };
};

const minimumBalance = (env: RunnerEnvironment) => {
  const value = env.CHAIN97_MIN_BALANCE_WEI?.trim() || "1";
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error("CHAIN97_MIN_BALANCE_WEI_INVALID");
  return BigInt(value);
};

const rpcCall = async <T>(name: "PRIMARY" | "SECONDARY", call: () => Promise<T>) => {
  try {
    return await call();
  } catch {
    throw new Error(`CHAIN97_RPC_CONNECTIVITY_FAILED:${name}`);
  }
};

export function redactRpcUrl(_endpoint: string) {
  return "[REDACTED_RPC_URL]";
}

export function redactAddress(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function validateChain97Wallets(
  env: RunnerEnvironment,
  deriveAddress: (privateKey: string) => string = defaultDeriveAddress,
): Chain97Wallet[] {
  const wallets = walletSlots.map((slot) => {
    const privateKey = requiredPrivateKey(env, slot);
    try {
      return { slot, address: deriveAddress(privateKey) };
    } catch {
      throw new Error(`CHAIN97_PRIVATE_KEY_${slot}_INVALID`);
    }
  });

  if (new Set(wallets.map(({ address }) => address.toLowerCase())).size !== wallets.length) {
    throw new Error("CHAIN97_WALLETS_NOT_DISTINCT");
  }
  return wallets;
}

export async function preflightChain97(input: {
  env: RunnerEnvironment;
  deriveAddress?: (privateKey: string) => string;
  createClient?: (endpoint: string) => Chain97RpcClient;
}): Promise<Chain97PreflightResult> {
  const wallets = validateChain97Wallets(input.env, input.deriveAddress);
  const primaryEndpoint = resolveRpcEndpoint(input.env, "PRIMARY");
  const secondaryEndpoint = resolveRpcEndpoint(input.env, "SECONDARY");
  if (primaryEndpoint.provider === secondaryEndpoint.provider) {
    throw new Error("CHAIN97_RPCS_NOT_INDEPENDENT");
  }

  const createClient = input.createClient ?? defaultCreateClient;
  const primary = createClient(primaryEndpoint.endpoint);
  const secondary = createClient(secondaryEndpoint.endpoint);
  const [primaryChainId, secondaryChainId] = await Promise.all([
    rpcCall("PRIMARY", () => primary.getChainId()),
    rpcCall("SECONDARY", () => secondary.getChainId()),
  ]);
  if (primaryChainId !== 97) throw new Error("CHAIN97_RPC_CHAIN_ID_INVALID:PRIMARY");
  if (secondaryChainId !== 97) throw new Error("CHAIN97_RPC_CHAIN_ID_INVALID:SECONDARY");

  const minimum = minimumBalance(input.env);
  const checkedWallets = await Promise.all(wallets.map(async (wallet) => {
    const [primaryBalance, secondaryBalance] = await Promise.all([
      rpcCall("PRIMARY", () => primary.getBalance({ address: wallet.address })),
      rpcCall("SECONDARY", () => secondary.getBalance({ address: wallet.address })),
    ]);
    if (primaryBalance < minimum || secondaryBalance < minimum) throw new Error(`CHAIN97_WALLET_UNFUNDED:${wallet.slot}`);
    if (primaryBalance !== secondaryBalance) throw new Error(`CHAIN97_WALLET_BALANCE_DIVERGENCE:${wallet.slot}`);
    return { ...wallet, balanceWei: primaryBalance };
  }));

  return { chainId: 97, wallets: checkedWallets };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const result = await preflightChain97({ env: process.env });
  console.log(JSON.stringify({
    chainId: result.chainId,
    wallets: result.wallets.map(({ slot, address, balanceWei }) => ({ slot, address: redactAddress(address), balanceWei: balanceWei.toString() })),
  }));
}
