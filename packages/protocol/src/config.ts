import {
  decodeAbiParameters,
  encodeAbiParameters,
  isAddress,
  keccak256,
  type Address,
  type Hex,
} from "viem";
import { z } from "zod";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const MAX_SUPPLY = 100_000_000_000n;
const MAX_TAX_BPS = 1_000;
const TOTAL_ALLOCATION_BPS = 10_000;
const MAX_UINT256 = (1n << 256n) - 1n;

const addressSchema = z.string().refine(isAddress, "Invalid address");
const allocationSchema = z.number().int().min(0).max(TOTAL_ALLOCATION_BPS);
const losslessBigIntSchema = z.union([
  z.bigint(),
  z.string().regex(/^\d+$/).transform((value) => BigInt(value)),
]);

export const CommonConfigSchema = z.object({
  name: z.string(),
  symbol: z.string(),
  supply: losslessBigIntSchema.pipe(z.bigint().min(1n).max(MAX_SUPPLY)),
  buyTaxBps: z.number().int().min(0).max(MAX_TAX_BPS),
  sellTaxBps: z.number().int().min(0).max(MAX_TAX_BPS),
  receiver: addressSchema.refine(
    (receiver) => receiver.toLowerCase() !== ZERO_ADDRESS,
    "Receiver must be nonzero",
  ),
  rewardToken: addressSchema,
  rewardThreshold: losslessBigIntSchema.pipe(z.bigint().min(0n).max(MAX_UINT256)),
  lpMode: z.number().int().min(0).max(255),
  allocationBps: z.tuple([
    allocationSchema,
    allocationSchema,
    allocationSchema,
    allocationSchema,
  ]),
  metadataHash: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
}).superRefine((config, context) => {
  const allocationTotal = config.allocationBps.reduce((total, allocation) => total + allocation, 0);
  const hasTax = config.buyTaxBps > 0 || config.sellTaxBps > 0;

  if (hasTax && allocationTotal !== TOTAL_ALLOCATION_BPS) {
    context.addIssue({
      code: "custom",
      message: "Active tax allocations must total 10000 bps",
      path: ["allocationBps"],
    });
  }

  if (!hasTax && allocationTotal !== 0) {
    context.addIssue({
      code: "custom",
      message: "Zero-tax configurations must have zero allocations",
      path: ["allocationBps"],
    });
  }
});

export type CommonConfig = z.infer<typeof CommonConfigSchema>;

export const commonConfigAbiParameter = {
  type: "tuple",
  components: [
    { name: "name", type: "string" },
    { name: "symbol", type: "string" },
    { name: "supply", type: "uint256" },
    { name: "buyTaxBps", type: "uint16" },
    { name: "sellTaxBps", type: "uint16" },
    { name: "receiver", type: "address" },
    { name: "rewardToken", type: "address" },
    { name: "rewardThreshold", type: "uint256" },
    { name: "lpMode", type: "uint8" },
    { name: "allocationBps", type: "uint16[4]" },
    { name: "metadataHash", type: "bytes32" },
  ],
} as const;

export function encodeCommonConfig(input: unknown): Hex {
  const config = CommonConfigSchema.parse(input);

  return encodeAbiParameters([commonConfigAbiParameter], [{
    ...config,
    receiver: config.receiver as Address,
    rewardToken: config.rewardToken as Address,
    metadataHash: config.metadataHash as Hex,
  }]);
}

export function decodeCommonConfig(encoded: Hex): CommonConfig {
  const [decoded] = decodeAbiParameters([commonConfigAbiParameter], encoded);
  return CommonConfigSchema.parse(decoded);
}

export function hashCommonConfig(input: unknown): Hex {
  return keccak256(encodeCommonConfig(input));
}
