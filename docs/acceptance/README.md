# 70X Chain 97 acceptance evidence

The Chain 97 runner is a transaction executor, not an evidence generator. It writes a bundle only from status-1 receipts, decoded receipt logs, EIP-1898 reads pinned to a canonical block hash through two approved independent RPC operators, exact BscScan and Sourcify source/metadata matches, RPC-observed runtime code, direct Factory configuration storage, an actual indexed configuration response, and the exact Factory deployment calldata. Missing data fails the run; the executor does not substitute placeholders.

The eleven scenario IDs are `standard-mint`, `time-weighted-rewards`, `threshold-buyback`, `scheduled-buyback`, `native-lp-rewards`, `holder-dead-rewards`, `finance-exit-multiple`, `wallet-limit-windows`, `external-token-burn`, `whitelist-mint`, and `flap-joint-launch`.

## Authorized execution path

Transactions may run only through the manually dispatched **Chain 97 acceptance transactions** workflow on `main`, using the protected `chain97-acceptance` GitHub environment. The dispatcher must type `SEND_CHAIN97_TRANSACTIONS` exactly. The workflow checks out the selected release, builds its Foundry artifacts, and sets both `RELEASE_COMMIT` and the executor's required `GITHUB_SHA` identity to the exact workflow commit.

The three private keys and any credential-bearing RPC values exist only in the environment of the single **Preflight budget and execute confirmed Chain 97 transactions** step. They are not available to checkout, install, build, test, or artifact-upload steps. The executor derives addresses in memory and never includes private keys or RPC URLs in output. Do not run the executor in a debug shell or enable shell tracing.

The transaction step requires these protected secrets:

| Name | Requirement |
| --- | --- |
| `CHAIN97_PRIVATE_KEY_A` | Distinct deployer/owner wallet key |
| `CHAIN97_PRIVATE_KEY_B` | Distinct participant wallet key |
| `CHAIN97_PRIVATE_KEY_C` | Distinct retry/funder/caller wallet key |
| `CHAIN97_BSCSCAN_API_KEY` | BscScan/Etherscan V2 verification credential |
| `CHAIN97_INDEXER_AUTH_TOKEN` | Indexer read credential, when the release indexer requires one |
| `CHAIN97_RPC_PRIMARY` | Optional credential/path on the approved PublicNode host |
| `CHAIN97_RPC_SECONDARY` | Optional credential/path on an approved BNB Chain host |

The workflow also supports a `checkpoint_run_id` input. It downloads only the `chain97-checkpoint-<release SHA>` artifact from that prior run. The checkpoint is bound to the exact release and canonical plan hash, has an integrity hash, and every imported receipt/input/block/event is revalidated through both RPCs before a new sender is constructed. This is the supported way to resume the protocol-enforced 24-hour refund branch.

The RPC overrides cannot select arbitrary operators. The approved identities are PublicNode at `bsc-testnet-rpc.publicnode.com` and BNB Chain at `data-seed-prebsc-{1,2}-s1.bnbchain.org`; the two configured endpoints must resolve to different identities. HTTPS is mandatory. URLs and credentials are never persisted.

These protected environment variables are also required:

| Name | Requirement |
| --- | --- |
| `CHAIN97_PLAN_PATH` | Repository-relative path to the audited JSON execution plan bound to the checked-out release commit |
| `CHAIN97_INDEXER_BASE_URL` | Credential-free HTTPS origin for the release indexer |
| `CHAIN97_CHECKPOINT_PATH` | Repository-contained writable JSON path; the workflow fixes this to `.chain97/checkpoint.json` |

## Audited execution plan

There is deliberately no generic or dynamically invented all-scenarios Chain 97 plan. Every live plan must be committed and audited with `releaseCommit: "self"`, then selected through `CHAIN97_PLAN_PATH`. The executor resolves only that sentinel to the workflow's exact 40-character `GITHUB_SHA`, after independently requiring the checked-out `HEAD` to equal that SHA. An explicit 40-character value remains supported for externally prepared plans and must match exactly. This avoids an impossible self-referential Git commit while preserving release binding and prevents the runner from inventing Pancake, Flap, token, locker, or verification dependencies.

The first audited release plan is `apps/acceptance/config/chain97-flap.json`; the workflow uses it when the protected environment does not override `CHAIN97_PLAN_PATH`. It pins the official Chain 97 Flap Portal v5.8.5 address and dual-RPC runtime-code hash, deploys and verifies the release Factory/registry/config/adapter/template stack, and exercises the full Flap launch, bounded low-gas failure, permissionless retry, claim, and delayed refund lifecycle. The first run is expected to checkpoint at the protocol's 24-hour refund boundary; resume it with that run's `checkpoint_run_id` after the delay.

Every plan has this top-level contract:

```ts
type Chain97Plan = {
  schemaVersion: 1;
  chainId: 97;
  releaseCommit: string;       // "self" in a committed plan, resolved to exact GITHUB_SHA
  confirmations: number;      // 2..100
  maxGasPriceWei: string;      // positive integer, used for worst-case budgeting
  dependencies: Dependency[];
  assetRequirements: AssetRequirement[];
  verificationTargets: VerificationTarget[]; // infrastructure created by bootstrap
  bootstrap: Step[];           // deterministic infrastructure deploy/register calls
  scenarios: Scenario[];
};
```

The dependency list must contain exact, nonzero address/code-hash pairs for every dependency required by the selected canonical manifest. These names include:

- `pancakeRouter`
- `pancakeFactory`
- `wbnb`
- `bscUsdt`
- `flapProtocol`
- `flapPoolAsset`
- `externalBurnTarget`

The runner compares every configured code hash against bytecode returned by both RPCs at the same finalized block before broadcasting anything. Every configured dependency must be consumed by a typed reference; decorative dependencies cannot satisfy coverage. A plan may add more named dependencies, such as an allowlisted locker, but may not replace a required identity with a literal or default.

Each step selects wallet `A`, `B`, or `C`, declares the exact canonical assertion, `gasLimit`, `valueWei`, required event emitters, explicit event-address captures, and at least one block-hash-pinned read. Supported kinds are:

- `deploy`: loads `contracts/out/<artifact>.json`, resolves constructor arguments, calculates the CREATE address from the wallet and preflight nonce, broadcasts the artifact bytecode, and requires the receipt contract address to match.
- `factoryDeploy`: uses `@70x/protocol`'s `encodeDeployment` and canonical template ID, never hand-authored Factory calldata.
- `call`: encodes the named function from the named Foundry artifact ABI.

Arguments may contain `{ "uint": "<base-10 integer>" }`, `{ "ref": "<typed dependency/wallet/deployment/event reference>" }`, or `{ "localAddress": "ZERO" | "DEAD" }`. Audited plans use absolute integer deadlines; relative deadlines are rejected so checkpointed transaction input is exactly reproducible. Every ABI `address`, form address, target, event emitter, asset, and spender must use a typed reference or the explicitly allowlisted local constant; raw address literals are rejected. Only declared event arguments are captured. Reads name a typed target reference, artifact, view function, and arguments.

Every contract created directly or internally must have a `verificationTarget` with its artifact, exact constructor arguments, captured address, and creation transaction step. The run submits the artifact's standard JSON and sources, then waits for both the public BscScan code page and the Sourcify full-match metadata. Partial or pending verification cannot produce evidence.

Each scenario contains the shared-protocol `form` (`templateId`, version `1`, common config, and template config), the exact canonical ordered stage/action/event/assertion manifest, an event-derived `indexProjectRef`, and verification targets for every contract it creates. Factory companion events are mandatory for reward, buyback, finance, and Flap deployments. The Chain 97 Flap scenario is native-BNB-only, calls Portal v5, captures the launched token, permits a zero pre-graduation pair, and verifies the configured anti-farmer duration without requiring a custom token getter. Failure/retry/refund branches call the real contracts and require their real events. Refund enablement and refund are separate stages; a release-bound checkpoint allows the same audited execution to resume after 24 hours.

## Budget and no-broadcast preflight

Before the first broadcast, the executor completes all of these checks:

1. Exact confirmation, `GITHUB_SHA`, checked-out HEAD, plan SHA, and Chain ID agree.
2. The complete plan is compiled without side effects: every artifact, ABI function/event, constructor/call argument, typed reference/capture, Factory creation link, direct/index reference, dependency use, verification target, budget, nonce sequence, and gas bound is valid.
3. Three wallet addresses are distinct; both independent RPCs report Chain 97, identical balances, and identical pending nonces.
4. Dependency bytecode and code hashes agree at one finalized block hash, and both RPCs still report that hash after all reads.
5. Both observed gas prices are at or below the plan ceiling.
6. For each wallet, balance covers the sum of every remaining selected step's `valueWei + gasLimit * maxGasPriceWei`.
7. Every selected ERC-20 funding requirement has matching balance and allowance on both RPCs at the canonical block hash.
8. Any checkpoint is an exact plan prefix and all historical transaction inputs, receipts, events, confirmations, reads, and block hashes are authentic.

Any failure occurs before a transaction is sent. In particular, a Flap plan must budget the real 2–16 BNB goal in addition to fees and worst-case gas. The executor also rejects Flap common configuration that Portal v5 cannot represent: supply other than one billion, unequal or unsupported tax tiers, a reward token, or a nonzero LP mode.

## Indexer and evidence contracts

The configured indexer must expose:

- `GET /health` returning `{ "chainId": 97, "releaseCommit": "<exact SHA>" }` before execution.
- `GET /v1/chains/97/projects/<address>/config?releaseCommit=<exact SHA>` returning `{ "chainId": 97, "releaseCommit": "<exact SHA>", "project": "<event-derived address>", "deploymentTransaction": "<hash>", "deploymentBlockHash": "<hash>", "config": ... }` after finalized ingestion.

The returned config must equal the normalized form, configuration decoded from the real Factory transaction input, and exact bytes read directly from `LaunchFactory.projectConfig(project)` at the deployment block hash. The indexed project must be the token or vault emitted by that same `ProjectDeployed` receipt.

Each immutable file under `docs/acceptance/evidence/<releaseCommit>/` contains full receipt provenance (block, index, gas, sender, destination/created address), sent/resumed identity, log address/index/decoded arguments, per-stage canonical dual-RPC reads and provider identities, receipt/event creation binding, creation/runtime/source/constructor/compiler hashes, exact verification metadata per deployed address, and form/encoded/calldata/direct/index configuration. The writer uses exclusive creation and refuses overwrite, incomplete canonical lifecycle coverage, failed/synthetic receipts, missing events, reorged blocks, same-provider or divergent reads, incomplete/mismatched verification, unbound creation transactions, or config mismatch.

Schema/unit gate: `pnpm --filter @70x/acceptance test`. The manual workflow is the only approved broadcast path. Before the credential-bearing transaction step, the workflow installs a pinned Playwright Chromium runtime and runs the real desktop/mobile browser lifecycle suite in `apps/web/tests/browser/`.
