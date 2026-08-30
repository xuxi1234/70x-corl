const stable = (value: unknown): string => JSON.stringify(value, Object.keys(value as object).sort());

export async function readBothRpcs<T>(stage: string, primary: () => Promise<T>, secondary: () => Promise<T>) {
  const [left, right] = await Promise.all([primary(), secondary()]);
  if (stable(left) !== stable(right)) throw new Error(`RPC_DIVERGENCE:${stage}`);
  return { stage, primary: left, secondary: right };
}

export function compareConfig(form: Record<string, unknown>, chain: Record<string, unknown>, index: Record<string, unknown>) {
  if (stable(form) !== stable(chain) || stable(form) !== stable(index)) throw new Error("CONFIG_MISMATCH");
  return { form, chain, index };
}
