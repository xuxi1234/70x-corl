const stable = (value: unknown): string => {
  if (typeof value === "bigint") return JSON.stringify(value.toString());
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${stable(item)}`).join(",")}}`;
  return JSON.stringify(value);
};

export async function readBothRpcs<T>(
  stage: string,
  primary: () => Promise<T>,
  secondary: () => Promise<T>,
  identity: { blockNumber: bigint; blockHash: string; primaryProvider: "publicnode" | "bnbchain"; secondaryProvider: "publicnode" | "bnbchain" },
) {
  const [left, right] = await Promise.all([primary(), secondary()]);
  if (stable(left) !== stable(right)) throw new Error(`RPC_DIVERGENCE:${stage}`);
  return { stage, ...identity, primary: left, secondary: right };
}

export function compareConfig(form: Record<string, unknown>, chain: Record<string, unknown>, index: Record<string, unknown>) {
  if (stable(form) !== stable(chain) || stable(form) !== stable(index)) throw new Error("CONFIG_MISMATCH");
  return { form, chain, index };
}
