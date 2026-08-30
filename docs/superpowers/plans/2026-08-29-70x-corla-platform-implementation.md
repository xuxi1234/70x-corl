# 70X Corla-Style Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test a new 70X-branded BSC launch platform with ten token templates and one Flap joint-launch flow whose UI, encoded configuration, stored state, events, and indexed display agree.

**Architecture:** A pnpm monorepo contains immutable Foundry contracts, a shared TypeScript schema/ABI package, a Ponder event indexer, a Next.js application, and an acceptance runner. `LaunchFactory` deploys versioned implementations registered in an append-only `TemplateRegistry`; schemas use the same canonical ABI tuple in TypeScript and Solidity.

**Tech Stack:** Solidity 0.8.28, Foundry, OpenZeppelin Contracts 5.x, pnpm, TypeScript 5.x strict mode, Next.js 16, React 19, wagmi 2, viem 2, Ponder, PostgreSQL, Vitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-29-70x-corla-launch-platform-design.md`

## Global Constraints

- Work only in the new repository; do not modify `xuxi1234/70x` or switch `70x.sh`.
- Ordinary deployment and Flap vault creation each cost exactly `0.005 BNB` initially.
- Only BNB pays platform fees; a future fee cannot exceed `0.05 BNB`.
- Project token, MintVault, RewardVault, and BuybackVault contracts are immutable and non-proxy.
- Existing `(templateId, version)` registry entries cannot be replaced.
- Supply is 1 through 100,000,000,000 whole tokens; taxes are bounded by the approved specification.
- Emergency pause never blocks refunds or claims.
- A mode passes only with reproducible Chain 97 receipts, decoded events, two-RPC reads, source verification, and UI/config comparison.
- Use test-driven development and commit after each task.

## File Map

- `contracts/src/core/`: Factory, registry, canonical configuration, platform access control.
- `contracts/src/vaults/`: Mint, reward, buyback, finance, and Flap vaults.
- `contracts/src/templates/`: eleven versioned template deployers.
- `contracts/src/adapters/`: Pancake, PinkSale, and Flap external boundaries.
- `contracts/test/`: unit, fuzz, invariant, and fork tests grouped by contract responsibility.
- `packages/protocol/`: canonical TypeScript schema, ABI exports, config hashing, form rules.
- `apps/indexer/`: Ponder event ingestion and PostgreSQL read model.
- `apps/web/`: 70X UI, deployment wizard, project list/detail, verification state.
- `apps/verify-worker/`: BscScan/Sourcify submission and bounded retry state machine.
- `apps/acceptance/`: Chain 97 lifecycle runner and evidence bundle generator.

---

## Workstream A — Protocol Foundation

### Task 1: Monorepo and deterministic toolchain

**Files:**
- Create: `pnpm-workspace.yaml`, `package.json`, `tsconfig.base.json`, `.gitignore`, `.github/workflows/ci.yml`
- Create: `contracts/foundry.toml`, `contracts/remappings.txt`
- Create: `packages/protocol/package.json`, `packages/protocol/tsconfig.json`, `packages/protocol/src/index.ts`
- Test: `packages/protocol/src/index.test.ts`

**Interfaces:**
- Produces: workspace scripts `lint`, `typecheck`, `test`, `build`; package `@70x/protocol`.

- [ ] **Step 1: Add a failing protocol smoke test**

```ts
import { describe, expect, it } from "vitest";
import { PLATFORM_FEE_WEI } from "./index";

describe("protocol constants", () => {
  it("uses the approved 0.005 BNB fee", () => {
    expect(PLATFORM_FEE_WEI).toBe(5_000_000_000_000_000n);
  });
});
```

- [ ] **Step 2: Run `pnpm --filter @70x/protocol test` and verify failure because the workspace and export do not exist.**
- [ ] **Step 3: Add pinned workspace manifests, strict TypeScript configuration, Foundry configuration, and `export const PLATFORM_FEE_WEI = 5_000_000_000_000_000n`.**
- [ ] **Step 4: Run `forge --version`, `pnpm install --frozen-lockfile=false`, and `pnpm --filter @70x/protocol test`; expect PASS.**
- [ ] **Step 5: Commit with `git commit -m "build: initialize 70X platform monorepo"`.**

### Task 2: Canonical configuration and cross-language hash

**Files:**
- Create: `contracts/src/core/LaunchTypes.sol`
- Create: `contracts/src/core/ConfigHash.sol`
- Create: `contracts/test/core/ConfigHash.t.sol`
- Create: `packages/protocol/src/config.ts`, `packages/protocol/src/config.test.ts`

**Interfaces:**
- Produces: Solidity `LaunchTypes.CommonConfig`; `ConfigHash.hash(CommonConfig)`; TypeScript `CommonConfigSchema`, `encodeCommonConfig`, `hashCommonConfig`.

- [ ] **Step 1: Write Solidity and TypeScript tests using the same fixture and expected Keccak hash file at `packages/protocol/fixtures/common-config.json`.**
- [ ] **Step 2: Run `forge test --match-contract ConfigHashTest` and `pnpm --filter @70x/protocol test`; verify both fail on missing implementations.**
- [ ] **Step 3: Define the tuple in this exact order: `name`, `symbol`, `supply`, `buyTaxBps`, `sellTaxBps`, `receiver`, `rewardToken`, `rewardThreshold`, `lpMode`, `allocationBps[4]`, `metadataHash`. Encode with `abi.encode`, never packed encoding.**
- [ ] **Step 4: Implement Zod refinements for supply, tax basis points, nonzero receiver, allocation total, and zero-tax allocation behavior.**
- [ ] **Step 5: Run both suites and assert byte-for-byte equal hashes.**
- [ ] **Step 6: Commit with `git commit -m "feat: add canonical launch configuration"`.**

### Task 3: Append-only registry and governed platform configuration

**Files:**
- Create: `contracts/src/core/TemplateRegistry.sol`, `contracts/src/core/PlatformConfig.sol`
- Create: `contracts/test/core/TemplateRegistry.t.sol`, `contracts/test/core/PlatformConfig.t.sol`

**Interfaces:**
- Produces: `register(bytes32 id,uint32 version,address implementation,bytes32 schemaHash)`; `resolve(bytes32,uint32)`; `setFee(uint96)`; `setRevenueRecipient(address)`.

- [ ] **Step 1: Write failing tests proving duplicate registrations revert, non-Owner calls revert, fee above `0.05 ether` reverts, and past deployment snapshots do not change when platform configuration changes.**
- [ ] **Step 2: Run `forge test --match-path 'test/core/*'`; expect FAIL on missing contracts.**
- [ ] **Step 3: Implement Ownable2Step, append-only registry storage, initial `0.005 ether` fee, nonzero recipient validation, and configuration-change events containing old and new values.**
- [ ] **Step 4: Run the focused tests and `forge test`; expect PASS.**
- [ ] **Step 5: Commit with `git commit -m "feat: add immutable template registry"`.**

### Task 4: LaunchFactory and clone deployment boundary

**Files:**
- Create: `contracts/src/interfaces/ITemplate.sol`, `contracts/src/core/LaunchFactory.sol`
- Create: `contracts/test/core/LaunchFactory.t.sol`

**Interfaces:**
- Consumes: registry resolution and canonical common configuration.
- Produces: `deploy(bytes32 id,uint32 version,bytes commonConfig,bytes templateConfig) payable returns (address token,address vault)` and `ProjectDeployed`.

- [ ] **Step 1: Write failing tests for exact fee, unknown template, config rejection, fee transfer, pause behavior, and event fields including fee, recipient, creator, token, vault, template, version, and config hash.**
- [ ] **Step 2: Run `forge test --match-contract LaunchFactoryTest`; expect FAIL.**
- [ ] **Step 3: Implement checks-effects-interactions, non-reentrant deployment, pause limited to new deployments, fee snapshot event, and an `ITemplate.deploy` call.**
- [ ] **Step 4: Run focused tests and a gas snapshot; expect PASS and no unbounded storage loops.**
- [ ] **Step 5: Commit with `git commit -m "feat: add launch factory"`.**

## Workstream B — Vaults and Ten Templates

### Task 5: Standard MintVault lifecycle

**Files:**
- Create: `contracts/src/vaults/MintVault.sol`, `contracts/src/tokens/LaunchToken.sol`, `contracts/src/templates/StandardTemplateV1.sol`
- Create: `contracts/test/vaults/MintVault.t.sol`, `contracts/test/invariant/MintAccounting.invariant.t.sol`

**Interfaces:**
- Produces: `mint(uint32 shares)`, `finalize(FinalizeParams)`, `claim()`, `enableRefunds()`, `refund()` and lifecycle events.

- [ ] **Step 1: Write failing lifecycle tests for multi-share mint, exact fill, overfill rejection, one-time finalization, proportional token claims, 24-hour unfilled refund, and claim/refund mutual exclusion.**
- [ ] **Step 2: Add an invariant asserting `vault BNB + finalized spend + refunded BNB == paid BNB` excluding documented platform fee and AMM price effects.**
- [ ] **Step 3: Run the focused unit and invariant tests; expect FAIL.**
- [ ] **Step 4: Implement immutable parameters, explicit enum states, CEI ordering, pull claims/refunds, and token minting solely to the vault.**
- [ ] **Step 5: Run `forge test --match-path 'test/vaults/*'` and `forge test --match-path 'test/invariant/*'`; expect PASS.**
- [ ] **Step 6: Commit with `git commit -m "feat: implement standard mint lifecycle"`.**

### Task 6: Tax router, reward accounting, liquidity disposition

**Files:**
- Create: `contracts/src/modules/TaxRouter.sol`, `contracts/src/vaults/RewardVault.sol`
- Create: `contracts/src/adapters/PancakeV2Adapter.sol`, `contracts/src/adapters/LpLockerAdapter.sol`
- Create: `contracts/test/modules/TaxRouter.t.sol`, `contracts/test/vaults/RewardVault.t.sol`, `contracts/test/adapters/LiquidityAdapters.t.sol`

**Interfaces:**
- Produces: `processTax(uint256)`, `fundRewards(uint256)`, `claimRewards()`, `addLiquidity`, `burnLp`, `lockLp`.

- [ ] **Step 1: Write failing tests for 100% allocation conservation, zero-tax behavior, BNB marketing settlement, reward-per-weight precision, dead LP transfer, allowlisted locker use, slippage, deadline, and fee-on-transfer rejection.**
- [ ] **Step 2: Run focused tests; expect FAIL.**
- [ ] **Step 3: Implement basis-point allocation with remainder assigned deterministically to liquidity, cumulative `rewardPerWeight` scaled by `1e36`, router allowances reset after use, and immutable receiver/LP mode.**
- [ ] **Step 4: Run focused tests and `forge test`; expect PASS.**
- [ ] **Step 5: Commit with `git commit -m "feat: add tax rewards and liquidity modules"`.**

### Task 7: Time-weighted, LP, and holder/dead reward templates

**Files:**
- Create: `contracts/src/vaults/TimeWeightedRewardVault.sol`, `contracts/src/vaults/LpRewardVault.sol`, `contracts/src/vaults/HolderDeadRewardVault.sol`
- Create: `contracts/src/templates/TimeWeightedTemplateV1.sol`, `LpRewardsTemplateV1.sol`, `HolderDeadTemplateV1.sol`
- Create: `contracts/test/templates/RewardTemplates.t.sol`, `contracts/test/fuzz/RewardAccounting.fuzz.t.sol`

**Interfaces:**
- Produces three registered implementations with IDs `TIME_WEIGHTED`, `LP_REWARDS`, and `HOLDER_DEAD`.

- [ ] **Step 1: Write failing tests for tranche age, newest-first outgoing consumption, `3x` cap, LP transfer weight updates, minimum LP eligibility, holder/dead split conservation, and dead share non-claimability.**
- [ ] **Step 2: Fuzz transfer sequences and assert distributed plus claimable rewards never exceed funding.**
- [ ] **Step 3: Implement each vault without holder enumeration and implement template deployers that validate their specialized ABI tuple.**
- [ ] **Step 4: Run reward unit and fuzz suites; expect PASS.**
- [ ] **Step 5: Commit with `git commit -m "feat: add reward launch templates"`.**

### Task 8: Threshold, scheduled, and external-token buyback templates

**Files:**
- Create: `contracts/src/vaults/BuybackVault.sol`
- Create: `contracts/src/templates/AutoBuybackTemplateV1.sol`, `TimedBuybackTemplateV1.sol`, `ExternalBurnTemplateV1.sol`
- Create: `contracts/test/templates/BuybackTemplates.t.sol`, `contracts/test/fuzz/BuybackBounds.fuzz.t.sol`

**Interfaces:**
- Produces IDs `AUTO_BUYBACK`, `TIMED_BUYBACK`, `EXTERNAL_BURN`; permissionless `executeBuyback(uint256 minOut,uint256 deadline)`.

- [ ] **Step 1: Write failing tests for threshold, interval, per-call cap, direct-to-dead output, target immutability, invalid route, early execution, malicious caller redirection, reentrancy, and slippage.**
- [ ] **Step 2: Run focused tests; expect FAIL.**
- [ ] **Step 3: Implement a single immutable vault configured for project-token or external-token targets; update interval state before router calls and never pay caller bounty from principal.**
- [ ] **Step 4: Run unit and fuzz suites; expect PASS.**
- [ ] **Step 5: Commit with `git commit -m "feat: add buyback burn templates"`.**

### Task 9: Finance exit, launch-limit, and whitelist templates

**Files:**
- Create: `contracts/src/vaults/FinanceVault.sol`, `contracts/src/modules/LaunchLimits.sol`, `contracts/src/modules/WhitelistMint.sol`
- Create: `contracts/src/templates/FinanceExitTemplateV1.sol`, `LaunchLimitTemplateV1.sol`, `WhitelistTemplateV1.sol`
- Create: `contracts/test/templates/ControlledLaunchTemplates.t.sol`, `contracts/test/invariant/FinanceCap.invariant.t.sol`

**Interfaces:**
- Produces IDs `FINANCE_EXIT`, `LAUNCH_LIMIT`, `WHITELIST`; Merkle epoch append API and capped position claims.

- [ ] **Step 1: Write failing tests for BNB/USDT positions, lifetime exit cap, funding shortage, non-decreasing limit windows, exemptions, automatic expiry, valid/invalid proofs, append-only whitelist epochs, and public mint after deadline.**
- [ ] **Step 2: Add an invariant that each position's paid amount never exceeds `principal * exitMultiple`.**
- [ ] **Step 3: Implement immutable window arrays capped at five, Merkle root epochs capped by the original 24-hour restriction, and per-position cumulative payouts.**
- [ ] **Step 4: Run controlled-template and invariant suites; expect PASS.**
- [ ] **Step 5: Commit with `git commit -m "feat: add controlled launch templates"`.**

## Workstream C — Flap Joint Launch

### Task 10: Flap adapter and refundable vault

**Files:**
- Create: `contracts/src/interfaces/IFlapAdapter.sol`, `contracts/src/adapters/FlapAdapterV1.sol`, `contracts/src/vaults/FlapMintVault.sol`, `contracts/src/templates/FlapTemplateV1.sol`
- Create: `contracts/test/flap/FlapMintVault.t.sol`, `contracts/test/flap/FlapAdapter.t.sol`, `contracts/test/invariant/FlapPrincipal.invariant.t.sol`

**Interfaces:**
- Produces: ID `FLAP_JOINT`; `mint`, `executeLaunch`, `retryLaunch`, `claim`, `refund`; adapter result `(token, purchasedAmount)`.

- [ ] **Step 1: Write failing tests for `2–16 BNB` goals, computed share price, optional whitelist, BNB/Crypto/RWA pool paths, atomic launch and first buy, proportional claim, 24-hour unfilled refund, and 24-hour post-fill failure refund.**
- [ ] **Step 2: Write adversarial tests where Flap, router, reward vault, or token transfer reverts; assert principal remains in the vault and the retry state is usable.**
- [ ] **Step 3: Add an invariant that the platform and creator cannot receive mint principal on any failed path.**
- [ ] **Step 4: Implement allowlisted adapter versions, error-hash events, retry timestamps, pull refunds, and sell-to-pair protection durations `0/5m/10m/30m/1h/24h`.**
- [ ] **Step 5: Run all Flap and invariant tests; expect PASS.**
- [ ] **Step 6: Commit with `git commit -m "feat: implement Flap joint launch"`.**

## Workstream D — Shared Schema, Indexer, Web, Verification, Acceptance

### Task 11: Eleven machine-readable schemas and ABI exports

**Files:**
- Create: `packages/protocol/src/templates/*.ts`, `packages/protocol/src/abi/*.ts`, `packages/protocol/src/registry.ts`
- Create: `packages/protocol/src/templates/templates.test.ts`

**Interfaces:**
- Produces: `templateSchemas`, `encodeDeployment`, `decodeProjectConfig`, `compareProjectConfig` for all eleven IDs.

- [ ] **Step 1: Write table-driven failing tests asserting eleven unique IDs, version `1`, field bounds, specialized tuple encoding, allocation total, and Solidity fixture hash equality.**
- [ ] **Step 2: Run protocol tests; expect FAIL.**
- [ ] **Step 3: Implement one schema module per template and exhaustively switch on the discriminated `templateId`; TypeScript must reject an unhandled ID.**
- [ ] **Step 4: Generate ABI exports from Foundry artifacts with `pnpm protocol:abi`, then run tests and `tsc --noEmit`; expect PASS.**
- [ ] **Step 5: Commit with `git commit -m "feat: publish eleven launch schemas"`.**

### Task 12: Event indexer and consistency read model

**Files:**
- Create: `apps/indexer/ponder.config.ts`, `apps/indexer/ponder.schema.ts`, `apps/indexer/src/index.ts`, `apps/indexer/src/handlers/*.ts`
- Create: `apps/indexer/src/index.test.ts`

**Interfaces:**
- Produces PostgreSQL entities `project`, `project_config`, `vault_state`, `transaction`, `verification_attempt`; query API consumed by web.

- [ ] **Step 1: Write failing replay tests using saved logs for deployment, mint, fill, retry, launch, refund, claim, rewards, buyback, LP disposition, and ownership/config changes.**
- [ ] **Step 2: Run `pnpm --filter @70x/indexer test`; expect FAIL.**
- [ ] **Step 3: Implement idempotent handlers keyed by `chainId/txHash/logIndex`, block/confirmation tracking, and no inferred fields outside event or direct-read data.**
- [ ] **Step 4: Replay fixtures twice and assert identical rows; run typecheck and tests.**
- [ ] **Step 5: Commit with `git commit -m "feat: index launch protocol events"`.**

### Task 13: 70X deployment wizard and project detail UI

**Files:**
- Create: `apps/web/app/page.tsx`, `apps/web/app/launch/page.tsx`, `apps/web/app/templates/page.tsx`, `apps/web/app/project/[address]/page.tsx`, `apps/web/app/flap-launch/page.tsx`
- Create: `apps/web/components/launch/*.tsx`, `apps/web/lib/chain.ts`, `apps/web/lib/indexer.ts`
- Create: `apps/web/tests/launch.spec.ts`, `apps/web/tests/detail.spec.ts`

**Interfaces:**
- Consumes `@70x/protocol` schemas and indexer API; produces wallet transactions through wagmi/viem.

- [ ] **Step 1: Write Playwright tests that select each template, verify its fields, reject invalid bounds, encode a fixture, and compare the review screen to decoded configuration.**
- [ ] **Step 2: Write detail tests for config hash, direct-RPC mismatch warning, unknown-version read-only behavior, verification states, mobile navigation, and transaction progress/error recovery.**
- [ ] **Step 3: Run `pnpm --filter @70x/web test:e2e`; expect FAIL.**
- [ ] **Step 4: Implement the 70X visual system and schema-driven wizard; do not duplicate validation constants in React components.**
- [ ] **Step 5: Implement list/detail views, RPC consistency check, and visible disabling of the Verified badge on mismatch.**
- [ ] **Step 6: Run desktop and mobile Playwright projects, accessibility scan, typecheck, and production build; expect PASS.**
- [ ] **Step 7: Commit with `git commit -m "feat: build 70X launch application"`.**

### Task 14: Verification worker and bounded retry

**Files:**
- Create: `apps/verify-worker/src/verify.ts`, `apps/verify-worker/src/queue.ts`, `apps/verify-worker/src/index.ts`
- Create: `apps/verify-worker/src/verify.test.ts`

**Interfaces:**
- Produces `submitVerification(project)`, `retryPending(now)`, and persisted status `Pending|Verified|Failed` per provider.

- [ ] **Step 1: Write failing tests for BscScan success, Sourcify success, partial success, rate limit, malformed metadata, exponential retry capped at six hours, and idempotent resubmission.**
- [ ] **Step 2: Run worker tests; expect FAIL.**
- [ ] **Step 3: Implement constructor-argument extraction from deployment receipts, standard-json input storage by content hash, provider-specific adapters, and bounded retry scheduling.**
- [ ] **Step 4: Run tests and typecheck; expect PASS.**
- [ ] **Step 5: Commit with `git commit -m "feat: automate contract verification"`.**

### Task 15: Chain 97 evidence runner and release gate

**Files:**
- Create: `apps/acceptance/src/scenarios/*.ts`, `apps/acceptance/src/rpc-compare.ts`, `apps/acceptance/src/evidence.ts`, `apps/acceptance/src/run.ts`
- Create: `apps/acceptance/src/evidence.test.ts`, `docs/acceptance/README.md`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces one JSON evidence bundle per mode containing chain ID, addresses, transaction hashes, receipt status, decoded events, two-RPC state snapshots, verification URLs/status, and config comparisons.

- [ ] **Step 1: Write failing serializer tests rejecting missing hashes, failed receipts, divergent finalized RPC values, absent required events, unverified source, or form/chain/index mismatch.**
- [ ] **Step 2: Run acceptance unit tests; expect FAIL.**
- [ ] **Step 3: Implement typed scenario primitives `send`, `waitReceipt`, `decodeRequiredEvents`, `readBothRpcs`, `compareConfig`, and `writeEvidence`; redact RPC credentials and private keys.**
- [ ] **Step 4: Implement all eleven lifecycle scenarios, including failure/retry/refund branches for Flap and specialized reward/buyback/limit/whitelist assertions.**
- [ ] **Step 5: Add CI gates for formatting, lint, typecheck, Foundry unit/fuzz/invariant tests, Vitest, Playwright, build, ABI drift, storage/layout checks, Slither, and evidence-schema validation.**
- [ ] **Step 6: Run the full local gate: `forge fmt --check && forge test && pnpm lint && pnpm typecheck && pnpm test && pnpm build`. Expect all PASS.**
- [ ] **Step 7: With configured Chain 97 secrets, run `pnpm --filter @70x/acceptance run run -- --all`; inspect all eleven complete evidence bundles.**
- [ ] **Step 8: Commit with `git commit -m "test: add Chain 97 release evidence gate"`.**

## Final Production Gate

- [ ] Review Owner, revenue recipient, Pancake router, Flap adapter, locker allowlist, template/version map, constructor arguments, and bytecode hashes.
- [ ] Verify all deployed source on BscScan and Sourcify.
- [ ] Re-run all eleven scenarios against the exact release commit and record the commit SHA in every evidence bundle.
- [ ] Perform a small-value BSC mainnet canary only after explicit mainnet authorization and funding confirmation.
- [ ] Keep `70x.sh` unchanged until the user separately approves domain switching after canary acceptance.
