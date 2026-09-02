import { isAddress, type Address, type Hex } from "viem";

const hashPattern = /^0x[0-9a-f]{64}$/i;
const dataPattern = /^0x[0-9a-f]*$/i;
const minimumCheckpointBlock = 128_297_492n;
const maximumCheckpointBlock = 128_297_551n;
const checkpointTransactionHashes = new Set([
  "0xc6a0e22765b1b5d1efaa6171b039421b27b77ee844fc2f0b0d201aff357cccc7",
  "0x806cf5d82c0e4f150c0a888a410e076e4e167ff87614bb86d80639f59c175202",
  "0xfd278b542eb33da6887766d91a4dbf0da3594a854f2a700e13062a26867e37cd",
  "0x2ce9047552665393db4e3eb10f2982f876e573d254a519e9de134a09f843d2f6",
]);

export type ArchiveReadRequest = {
  method: "eth_getCode" | "eth_call";
  first: Address | { to: Address; data: Hex };
  blockNumber: bigint;
  blockHash: Hex;
};

export type ArchiveTransactionRequest = {
  method: "eth_getTransactionReceipt" | "eth_getTransactionByHash";
  hash: Hex;
};

export function validateArchiveRequest(value: unknown): ArchiveReadRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("CHAIN97_ARCHIVE_REQUEST_INVALID");
  const input = value as Record<string, unknown>;
  if (input.method !== "eth_call" && input.method !== "eth_getCode") throw new Error("CHAIN97_ARCHIVE_METHOD_FORBIDDEN");
  if (typeof input.blockNumber !== "string" || !/^\d+$/.test(input.blockNumber)) throw new Error("CHAIN97_ARCHIVE_BLOCK_INVALID");
  const blockNumber = BigInt(input.blockNumber);
  if (blockNumber < minimumCheckpointBlock || blockNumber > maximumCheckpointBlock) throw new Error("CHAIN97_ARCHIVE_BLOCK_FORBIDDEN");
  if (typeof input.blockHash !== "string" || !hashPattern.test(input.blockHash)) throw new Error("CHAIN97_ARCHIVE_HASH_INVALID");
  if (input.method === "eth_getCode") {
    if (typeof input.first !== "string" || !isAddress(input.first)) throw new Error("CHAIN97_ARCHIVE_TARGET_INVALID");
    return { method: input.method, first: input.first, blockNumber, blockHash: input.blockHash as Hex };
  }
  if (!input.first || typeof input.first !== "object" || Array.isArray(input.first)) throw new Error("CHAIN97_ARCHIVE_CALL_INVALID");
  const call = input.first as Record<string, unknown>;
  if (typeof call.to !== "string" || !isAddress(call.to) || typeof call.data !== "string" || !dataPattern.test(call.data)) throw new Error("CHAIN97_ARCHIVE_CALL_INVALID");
  return { method: input.method, first: { to: call.to, data: call.data as Hex }, blockNumber, blockHash: input.blockHash as Hex };
}

export function validateArchiveTransactionRequest(value: unknown): ArchiveTransactionRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("CHAIN97_ARCHIVE_REQUEST_INVALID");
  const input = value as Record<string, unknown>;
  if (input.method !== "eth_getTransactionReceipt" && input.method !== "eth_getTransactionByHash") throw new Error("CHAIN97_ARCHIVE_METHOD_FORBIDDEN");
  if (typeof input.hash !== "string" || !checkpointTransactionHashes.has(input.hash.toLowerCase())) throw new Error("CHAIN97_ARCHIVE_TRANSACTION_FORBIDDEN");
  return { method: input.method, hash: input.hash as Hex };
}
