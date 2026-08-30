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
8. `wallet-limit-windows`
9. `external-token-burn`
10. `whitelist-mint`
11. `flap-joint-launch`

Local schema gate: `pnpm --filter @70x/acceptance test`.

Live evidence requires a separately configured Chain 97 executor module plus two independent RPC endpoints and dedicated test wallets. Never place private keys, mnemonics, API keys, or credential-bearing RPC URLs in evidence.

Set `CHAIN97_EXECUTOR_MODULE` to an ESM module path. The module must export
`runAcceptance({ scenarioIds, releaseCommit })` and return one complete evidence bundle for every requested scenario. The runner validates each bundle, rejects missing or duplicate scenarios and release-commit mismatches, then writes immutable files below `docs/acceptance/evidence/<releaseCommit>/`.

Use `RELEASE_COMMIT` locally or `GITHUB_SHA` in CI. Run all scenarios with:

```sh
pnpm --filter @70x/acceptance run run -- --all
```
