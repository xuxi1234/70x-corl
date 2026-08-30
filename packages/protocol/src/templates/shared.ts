import { isAddress, type AbiParameter, type Address, type Hex } from "viem";
import { z } from "zod";

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
export const MAX_UINT32 = 4_294_967_295;
export const MAX_UINT64 = (1n << 64n) - 1n;
export const MAX_UINT96 = (1n << 96n) - 1n;
export const MAX_UINT256 = (1n << 256n) - 1n;

export const addressSchema = z.string().refine(isAddress, "Invalid address").transform((value) => value as Address);
export const nonzeroAddressSchema = addressSchema.refine((value) => value.toLowerCase() !== ZERO_ADDRESS, "Address must be nonzero");
export const bytes32Schema = z.string().regex(/^0x[0-9a-fA-F]{64}$/).transform((value) => value as Hex);
export const nonzeroBytes32Schema = bytes32Schema.refine((value) => !/^0x0{64}$/i.test(value), "Bytes32 must be nonzero");
export const uint32Schema = z.number().int().min(0).max(MAX_UINT32);

export function bigintSchema(maximum: bigint = MAX_UINT256) {
  return z.union([
    z.bigint(),
    z.string().regex(/^\d+$/).transform((value) => BigInt(value)),
    z.number().int().nonnegative().safe().transform((value) => BigInt(value)),
  ]).pipe(z.bigint().min(0n).max(maximum));
}

export const standardLaunchSchema = z.object({
  totalShares: uint32Schema.min(1),
  pricePerShare: bigintSchema(MAX_UINT96).pipe(z.bigint().min(1n)),
  claimTokenBps: z.number().int().min(1).max(9_999),
  minimumLiquidityOutput: bigintSchema().pipe(z.bigint().min(1n)),
});

export type StandardLaunchConfig = z.infer<typeof standardLaunchSchema>;

export const standardLaunchAbi = {
  name: "launch",
  type: "tuple",
  components: [
    { name: "totalShares", type: "uint32" },
    { name: "pricePerShare", type: "uint96" },
    { name: "claimTokenBps", type: "uint16" },
    { name: "minimumLiquidityOutput", type: "uint256" },
  ],
} as const satisfies AbiParameter;

export interface TemplateDefinition<T> {
  readonly templateId: string;
  readonly version: 1;
  readonly label: string;
  readonly schema: z.ZodType<T>;
  readonly abiParameters: readonly AbiParameter[];
  readonly toAbiValues: (config: T) => readonly unknown[];
  readonly fromAbiValues: (values: readonly unknown[]) => unknown;
}

export function defineTemplate<T>(definition: TemplateDefinition<T>): TemplateDefinition<T> {
  return definition;
}

export function standardTupleDefinition(templateId: string, label: string) {
  return defineTemplate({
    templateId,
    version: 1,
    label,
    schema: standardLaunchSchema,
    abiParameters: [standardLaunchAbi],
    toAbiValues: (config) => [config],
    fromAbiValues: ([config]) => config,
  });
}
