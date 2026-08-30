# 70X Corla-Style Launch Platform Design

Date: 2026-08-29  
Status: Approved in chat; awaiting written-spec approval  
Target network: BNB Smart Chain, with Chain 97 used for pre-production acceptance

## 1. Goal

Build a new, independent 70X-branded launch platform that reproduces Corla's public launch flows and eleven observable on-chain mechanisms without copying Corla's private source code or branded assets. The existing `xuxi1234/70x` repository and production site remain unchanged until the new system passes acceptance.

The product is only considered complete when the form schema, transaction encoding, stored configuration, runtime behavior, emitted events, indexer data, and detail-page display agree for every field.

## 2. Scope

The first release includes all ten token templates plus the Flap joint-launch flow:

1. Standard mint launch
2. Time-weighted holder rewards
3. Threshold-triggered buyback and burn
4. Scheduled buyback and burn
5. Native LP-holder rewards
6. Holder and dead-wallet rewards
7. Finance exit-multiple rewards
8. Time-window wallet holding limits
9. Buyback and burn of a specified external token
10. Whitelist mint
11. Flap joint launch through a BNB mint vault

The release also includes the web application, mobile layout, Factory, template registry, template contracts, vaults, Flap adapter, event indexer, project/detail pages, verification worker, and Chain 97 acceptance tooling.

Out of scope for the first production cut: modifying the existing 70X contracts, migrating existing projects, accepting a 70X platform token as a fee asset, and enabling chains other than BSC.

## 3. Product Identity and Fixed Platform Configuration

- All names, logos, copy, links, suffix rules, Owner addresses, and revenue addresses are 70X-owned values.
- Ordinary template deployment costs `0.005 BNB`.
- Creating a Flap mint vault costs `0.005 BNB`.
- Fees are enforced by the Factory and transferred to the configured 70X revenue address in the same transaction.
- The Owner may set a new fee for future deployments only, capped at `0.05 BNB`.
- Each emitted deployment event records the fee amount and recipient used for that deployment.
- BNB is the only fee asset in this release.

## 4. Architecture

### 4.1 Components

- **LaunchFactory:** validates fees and common parameters, resolves a registered template version, deploys project contracts, and emits canonical deployment events.
- **TemplateRegistry:** maps immutable `(templateId, version)` pairs to implementations and schemas. Existing entries cannot be replaced.
- **Template implementations:** contain template-specific validation and create immutable project contracts.
- **Project token:** ERC-20 token with immutable supply and template-selected runtime modules.
- **MintVault:** accepts mint payments, counts shares, finalizes a filled launch, and enables refunds on failure paths.
- **RewardVault:** accounts for claimable rewards without iterating over all holders.
- **BuybackVault:** isolates buyback funds and applies threshold, interval, slippage, and per-call limits.
- **FlapAdapter:** versioned, allowlisted integration boundary for Flap creation and first purchase.
- **Indexer:** consumes canonical events and persists a read model; it never invents configuration not present on-chain.
- **Verification worker:** submits source and constructor metadata to BscScan and Sourcify, records attempts, and retries failures.
- **Web application:** renders forms from versioned schemas and compares indexed data against direct chain reads on detail pages.

### 4.2 Versioning and immutability

Project tokens, mint vaults, reward vaults, and buyback vaults are not upgradeable. Factory and registry administration may add a new template version but may not alter an existing version. Every project permanently stores and emits `templateId`, `version`, and `configHash`.

Unknown template versions are displayed read-only. The web application must refuse to encode write transactions for an unknown schema.

## 5. Common Launch Rules

- Supply range: `1` through `100,000,000,000` whole tokens, converted to token decimals with checked arithmetic.
- Buy tax range: `0%` through `10%`.
- Sell tax range: `0%` through `10%` for ordinary templates. The Flap flow requires sell tax of at least `1%`, matching the observed public form.
- Active allocation categories must sum to exactly `100%`; zero total tax permits all allocation values to be zero.
- Marketing tax swaps to BNB on-chain and transfers to the immutable project receiver wallet.
- Default reward asset is BSC USDT. A custom reward asset must have a valid WBNB route at creation and again when a swap executes.
- LP disposition is either transfer to the canonical dead address or lock through an allowlisted PinkSale-compatible locker. The resulting transaction and amount are emitted.
- A project configuration is hashed using canonical ABI encoding. The same encoding library is shared by the web application, deployment tooling, and acceptance tests.
- All value-bearing functions use reentrancy protection, checked state transitions, deadlines, minimum-output limits, and pull-based claims where applicable.

## 6. Template Semantics

### 6.1 Standard mint launch

The creator selects supply, total mint count, BNB per mint, taxes, allocations, reward asset, reward threshold, receiver, and LP disposition. Each paid mint creates shares. Once all shares are sold, the vault finalizes once, creates liquidity, applies LP disposition, and opens token claims proportional to shares. Before finalization, token claims are impossible.

### 6.2 Time-weighted holder rewards

Reward weight is token balance multiplied by an elapsed-holding multiplier. The multiplier grows linearly from `1.0x` to a creator-selected cap no greater than `3.0x` over a duration from 1 to 30 days. Incoming transfers start a new weighted tranche; outgoing transfers consume the newest tranche first. This prevents a transfer from granting historical holding time. Rewards use cumulative reward-per-weight accounting and user claims.

### 6.3 Threshold buyback and burn

The configured tax share accumulates as BNB in BuybackVault. Anyone may trigger execution when the balance meets the immutable threshold. Execution spends no more than the immutable maximum per transaction, observes slippage and deadline limits, purchases the project token, and sends the output directly to the dead address.

### 6.4 Scheduled buyback and burn

The vault adds an immutable execution interval from 5 minutes to 30 days and an immutable BNB cap per execution. A call before the next execution time reverts. A successful execution advances the next time before external calls and sends purchased project tokens directly to the dead address.

### 6.5 Native LP-holder rewards

Eligibility is based on balance of the canonical project/WBNB LP token. Reward weight changes with LP transfers. The minimum eligible LP balance is immutable. Rewards use cumulative reward-per-LP accounting and user claims; the contract never loops across providers.

### 6.6 Holder and dead-wallet rewards

The reward allocation is divided between live eligible holders and the canonical dead address using immutable percentages totaling `100%`. Holder rewards use cumulative accounting. The dead-wallet share is transferred directly to the dead address in the reward asset and is never claimable by Owner or creator.

### 6.7 Finance exit-multiple rewards

Users open positions by depositing one supported asset: BNB or BSC USDT. Each position has principal, claimed reward, opening time, and an immutable exit multiple selected from `1.0x` through `5.0x`. Claims cannot make lifetime payout exceed principal multiplied by the exit multiple. At the cap the position closes permanently. Funding shortfalls preserve accounting and allow later claims; they do not mint an Owner debt privilege.

### 6.8 Time-window wallet holding limits

The creator configures up to five consecutive windows beginning at launch, each with a duration in minutes and a maximum wallet balance expressed as a supply percentage. Percentages must be non-decreasing across later windows and no window may exceed 24 hours. Transfers exceeding the active receiver limit revert. Router, pair, vault, dead address, and zero address exemptions are explicit and immutable. Limits disappear automatically after the last window.

### 6.9 External-token buyback and burn

The buyback vault purchases one immutable target token and transfers it to the canonical dead address. Creation requires a valid WBNB route and rejects the zero address, WBNB, and tokens whose transfer behavior fails a route quote or dry-run compatibility check. Runtime execution enforces minimum output, deadline, threshold, and maximum spend. Holder rewards remain a separate allocation.

### 6.10 Whitelist mint

Before an immutable whitelist deadline, only Merkle-proof addresses may mint. The creator may append whitelist epochs but may not remove eligibility already granted or extend the restricted period beyond 24 hours from vault creation. After the deadline minting is public. Claims and refunds depend on paid shares, not whitelist membership.

### 6.11 Flap joint launch

The creator supplies metadata, a native-BNB goal from `2` through `16 BNB`, total shares, anti-farmer protection duration, receiver, a supported Portal v5 tax tier, allocations, and links. Version 1 fixes the supply at `1,000,000,000` whole tokens, requires equal buy and sell tax, and does not accept an alternate reward token or LP mode. Whitelisted Flap funding is disabled in the Chain 97 release plan.

The vault accepts native BNB and passes the completed goal to the versioned adapter, which calls Portal v5 `newTokenV5` and performs the first bonding-curve purchase atomically. The token is recorded immediately and claims become proportional to paid shares. The pair may remain the zero address until the token graduates to a DEX pool; version 1 rejects crypto/RWA quote assets instead of silently translating them into unsupported Portal parameters.

An unfilled vault becomes refundable 24 hours after creation. A filled vault enters execution state. If every launch attempt continues to fail for 24 hours after filling, refunds become available. A failed external call cannot transfer funds to the platform or creator. Retrying is permissionless, but the caller cannot redirect funds or receive a bounty from user principal.

Portal anti-farmer protection may be disabled or set to 5 minutes, 10 minutes, 30 minutes, 1 hour, or 24 hours. Evidence binds the requested duration to the immutable vault configuration and the exact Portal call; it does not assume a non-standard getter on the launched token.

## 7. Permissions

Owner may change future deployment fees and the future revenue recipient, register new immutable template versions, pause creation of new projects, pause a proven-vulnerable automated executor, update allowlisted adapters and lockers for future projects, and transfer ownership.

Owner cannot withdraw mint principal, unclaimed tokens, rewards, or buyback funds; change existing supply, tax, allocation, receiver, mint, refund, claim, whitelist, limit, or buyback parameters; block refunds or claims; recover burned LP; or redirect an existing project's assets.

Emergency pause never blocks refunds or claims. Project creators have only the immutable capabilities explicitly described by their selected template.

## 8. State and Failure Handling

Mint and Flap vaults use explicit states: `Funding`, `Filled`, `Executing`, `Launched`, `Refundable`, and `Closed`. Each transition is one-way except that a failed external execution returns to a retryable `Filled` state while retaining failure timestamps and error hashes.

Swap failure, adapter failure, verification failure, indexer lag, and UI failure do not alter asset ownership. Verification failures mark a project `PendingVerification` and retry with bounded backoff. Indexer data includes block number and confirmation status; the UI falls back to direct reads for critical configuration and labels discrepancies.

## 9. Canonical Events

At minimum, contracts emit events for template registration, platform configuration changes, project deployment, configuration hash, mint purchase, fill, execution attempt, launch, refund availability, refund, claim, liquidity creation and disposition, reward funding and claim, buyback funding and execution, burn, whitelist epoch, limit-window selection, pause, and ownership transfer.

Events include stable project and template identifiers, affected addresses, input and output amounts, and configuration version. Sensitive off-chain metadata is stored by content hash and URI, not embedded as mutable platform state.

## 10. Web and Indexer Consistency

Each template version has one machine-readable schema used to render fields, validate input, encode transactions, decode stored configuration, and produce acceptance fixtures. Factory validation remains authoritative.

The detail page shows the template/version, config hash, supply, mint parameters, taxes, allocations, receiver, reward asset and threshold, LP disposition, specialized template parameters, verification status, and relevant vault balances. A field mismatch between the index and a direct RPC read produces a visible warning and disables the `Verified` badge.

## 11. Verification and Acceptance

Each of the eleven modes must pass:

- unit tests for successful lifecycle behavior;
- boundary tests for every numeric and address parameter;
- fuzz tests for share accounting, reward accounting, state transitions, and allocation totals;
- permission, reentrancy, slippage, fee-on-transfer compatibility, deadline, and failure-recovery tests;
- invariant tests proving user principal plus paid refunds/claims remains conserved within documented fees and swap effects;
- a real Chain 97 deployment and complete applicable lifecycle;
- transaction hash, successful receipt, decoded events, and before/after balances for every acceptance step;
- state comparison through two independent RPC endpoints;
- BscScan and Sourcify verification results;
- a field-by-field comparison between form input, config hash preimage, contract reads, indexed data, and detail-page display.

A mode does not pass because its page renders. It passes only after its intended economic behavior occurs in real testnet transactions and the evidence bundle is reproducible.

## 12. Rollout

Development occurs in a new repository. The existing 70X repository and `70x.sh` remain untouched. All eleven modes are implemented in the first release scope, but acceptance may run in batches. Production rollout requires all eleven evidence bundles, a final Owner/revenue/router/adapter/locker review, verified source, and a small-value BSC mainnet canary. Domain switching is a separate explicit decision after canary acceptance.
