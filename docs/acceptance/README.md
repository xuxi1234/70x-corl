# 70X Chain 97 acceptance evidence

Each of the eleven modes produces one JSON bundle bound to the exact 40-character release commit. A valid bundle contains Chain ID 97, public contract addresses, transaction hashes, status-1 receipts, canonical block hashes, decoded required events, identical finalized reads from two independent RPC providers, BscScan and Sourcify `Verified` results, and identical form/chain/index configuration.

The runner is fail-closed. It refuses empty transaction hashes, failed receipts, missing required events, RPC divergence, partial verification, configuration mismatch, absent executor configuration, or non-Chain-97 evidence. Secrets and credential-bearing RPC URLs are redacted before serialization.

Required scenario IDs:

1. `standard-mint`
2. `time-weighted-rewards`
3. `threshold-buyback`
4. `scheduled-buyback`
5. `native-lp-rewards`
6. `holder-dead-rewards`
7. `finance-exit-multiple`
8. `wallet-limit-windows` (`LAUNCH_LIMIT`)
9. `external-token-burn`
10. `whitelist-mint`
11. `flap-joint-launch`

Local schema gate: `pnpm --filter @70x/acceptance test`.

Live evidence requires a separately configured Chain 97 executor module plus two independent RPC endpoints, a funded dedicated test wallet, and verification credentials. The executor must use the approved protocol IDs, including `LAUNCH_LIMIT` and `FLAP_JOINT`. Never place private keys, mnemonics, API keys, or credential-bearing RPC URLs in evidence.

Before adding the executor, use the manually dispatched **Chain 97 acceptance preflight** workflow from `main`. It injects `CHAIN97_PRIVATE_KEY_A`, `CHAIN97_PRIVATE_KEY_B`, and `CHAIN97_PRIVATE_KEY_C` only into its preflight step, derives their public addresses in memory, requires three distinct funded wallets, and checks both Chain 97 RPCs. It sends no transactions and prints only redacted addresses and balances. The optional encrypted secrets `CHAIN97_RPC_PRIMARY` and `CHAIN97_RPC_SECONDARY` may add credentials or a path to an approved host, but may not select a provider: the allowlist is `bsc-testnet-rpc.publicnode.com` (PublicNode) and `data-seed-prebsc-{1,2}-s1.bnbchain.org` (BNB Chain). The two selected endpoints must resolve to different allowlisted provider identities. `CHAIN97_MIN_BALANCE_WEI` is an optional repository variable (default: `1`).

Set `CHAIN97_EXECUTOR_MODULE` to an ESM module path. The module must export
`runAcceptance({ scenarioIds, releaseCommit })` and return one complete evidence bundle for every requested scenario. The runner validates each bundle, rejects missing or duplicate scenarios and release-commit mismatches, then writes immutable files below `docs/acceptance/evidence/<releaseCommit>/`.

Use `RELEASE_COMMIT` locally or `GITHUB_SHA` in CI. Run all scenarios with:

```sh
pnpm --filter @70x/acceptance run run -- --all
```

The live command is intentionally fail-closed until these runtime values exist: `CHAIN97_EXECUTOR_MODULE`, `RELEASE_COMMIT` (or `GITHUB_SHA`), two independent Chain 97 RPC endpoints, a dedicated wallet private key with test BNB, and BscScan/Sourcify verification configuration. The executor is responsible for returning real status-1 receipts and provider URLs; the core runner will not synthesize them.
