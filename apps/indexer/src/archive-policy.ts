import { isAddress, type Address, type Hex } from "viem";

const hashPattern = /^0x[0-9a-f]{64}$/i;
const dataPattern = /^0x[0-9a-f]*$/i;
const minimumCheckpointBlock = 128_297_492n;
const maximumCheckpointBlock = 128_297_551n;

export type ArchiveReadRequest = {
  method: "eth_getCode" | "eth_call";
  first: Address | { to: Address; data: Hex };
  blockNumber: bigint;
  blockHash: Hex;
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
