import { describe, expect, it } from "vitest";

import {
  preflightChain97,
  redactAddress,
  redactRpcUrl,
  validateChain97Wallets,
} from "./preflight";

const keys = {
  CHAIN97_PRIVATE_KEY_A: `0x${"1".repeat(64)}`,
  CHAIN97_PRIVATE_KEY_B: `0x${"2".repeat(64)}`,
  CHAIN97_PRIVATE_KEY_C: `0x${"3".repeat(64)}`,
};

const addresses = {
  [keys.CHAIN97_PRIVATE_KEY_A]: "0x1000000000000000000000000000000000000001",
  [keys.CHAIN97_PRIVATE_KEY_B]: "0x2000000000000000000000000000000000000002",
  [keys.CHAIN97_PRIVATE_KEY_C]: "0x3000000000000000000000000000000000000003",
};

const deriveAddress = (privateKey: string) => addresses[privateKey]!;

describe("Chain 97 acceptance preflight", () => {
  it("derives three distinct wallet addresses without returning private keys", () => {
    const wallets = validateChain97Wallets(keys, deriveAddress);

    expect(wallets).toEqual([
      { slot: "A", address: addresses[keys.CHAIN97_PRIVATE_KEY_A]! },
      { slot: "B", address: addresses[keys.CHAIN97_PRIVATE_KEY_B]! },
      { slot: "C", address: addresses[keys.CHAIN97_PRIVATE_KEY_C]! },
    ]);
    expect(JSON.stringify(wallets)).not.toContain(keys.CHAIN97_PRIVATE_KEY_A);
  });

  it("rejects missing, malformed, and duplicate wallet keys without echoing them", () => {
    expect(() => validateChain97Wallets({ ...keys, CHAIN97_PRIVATE_KEY_B: undefined }, deriveAddress)).toThrow("CHAIN97_PRIVATE_KEY_B_MISSING");
    expect(() => validateChain97Wallets({ ...keys, CHAIN97_PRIVATE_KEY_B: "not-a-private-key" }, deriveAddress)).toThrow("CHAIN97_PRIVATE_KEY_B_INVALID");
    expect(() => validateChain97Wallets({ ...keys, CHAIN97_PRIVATE_KEY_B: keys.CHAIN97_PRIVATE_KEY_A }, deriveAddress)).toThrow("CHAIN97_WALLETS_NOT_DISTINCT");
  });

  it("redacts RPC endpoints and wallet displays", () => {
    expect(redactRpcUrl("https://user:password@rpc.example/v3/secret?apiKey=secret")).toBe("[REDACTED_RPC_URL]");
    expect(redactAddress(addresses[keys.CHAIN97_PRIVATE_KEY_A]!)).toBe("0x1000…0001");
  });

  it("checks both RPCs, Chain 97, and a nonzero balance for every wallet", async () => {
    const requested: Array<{ endpoint: string; address: string }> = [];
    const result = await preflightChain97({
      env: keys,
      deriveAddress,
      createClient: (endpoint) => ({
        getChainId: async () => 97,
        getBalance: async ({ address }) => {
          requested.push({ endpoint, address });
          return 2n;
        },
      }),
    });

    expect(result).toEqual({
      chainId: 97,
      wallets: [
        { slot: "A", address: addresses[keys.CHAIN97_PRIVATE_KEY_A]!, balanceWei: 2n },
        { slot: "B", address: addresses[keys.CHAIN97_PRIVATE_KEY_B]!, balanceWei: 2n },
        { slot: "C", address: addresses[keys.CHAIN97_PRIVATE_KEY_C]!, balanceWei: 2n },
      ],
    });
    expect(new Set(requested.map(({ endpoint }) => endpoint)).size).toBe(2);
    expect(requested).toHaveLength(6);
  });

  it("fails closed for a non-97 RPC or an unfunded wallet", async () => {
    await expect(preflightChain97({
      env: keys,
      deriveAddress,
      createClient: () => ({ getChainId: async () => 56, getBalance: async () => 2n }),
    })).rejects.toThrow("CHAIN97_RPC_CHAIN_ID_INVALID");

    await expect(preflightChain97({
      env: keys,
      deriveAddress,
      createClient: () => ({ getChainId: async () => 97, getBalance: async () => 0n }),
    })).rejects.toThrow("CHAIN97_WALLET_UNFUNDED:A");
  });

  it("rejects same-operator RPC aliases even when their origins differ", async () => {
    await expect(preflightChain97({
      env: {
        ...keys,
        CHAIN97_RPC_PRIMARY: "https://data-seed-prebsc-1-s1.bnbchain.org:8545/first-secret",
        CHAIN97_RPC_SECONDARY: "https://data-seed-prebsc-2-s1.bnbchain.org:8545/second-secret",
      },
      deriveAddress,
      createClient: () => ({ getChainId: async () => 97, getBalance: async () => 2n }),
    })).rejects.toThrow("CHAIN97_RPCS_NOT_INDEPENDENT");
  });

  it("rejects an override whose provider identity is not allowlisted", async () => {
    await expect(preflightChain97({
      env: { ...keys, CHAIN97_RPC_PRIMARY: "https://unapproved.example/credential" },
      deriveAddress,
      createClient: () => ({ getChainId: async () => 97, getBalance: async () => 2n }),
    })).rejects.toThrow("CHAIN97_RPC_PRIMARY_PROVIDER_UNAPPROVED");
  });

  it("rejects divergent wallet balances returned by the independent providers", async () => {
    await expect(preflightChain97({
      env: keys,
      deriveAddress,
      createClient: (endpoint) => ({
        getChainId: async () => 97,
        getBalance: async () => endpoint.includes("publicnode") ? 2n : 3n,
      }),
    })).rejects.toThrow("CHAIN97_WALLET_BALANCE_DIVERGENCE:A");
  });
});
