# Task 8 Report: Threshold, Scheduled, and External-Token Buybacks

## Status

Implemented the three versioned, factory-compatible buyback templates and one shared immutable companion vault:

- `AUTO_BUYBACK`, version `1`
- `TIMED_BUYBACK`, version `1`
- `EXTERNAL_BURN`, version `1`

The templates preserve the existing `MintVault` funding/finalization/refund/claim lifecycle and keep the complete project-token supply in MintVault custody. Each template records the companion in `buybackVaultOf` and emits `BuybackCompanionDeployed` with the template ID/version, project token, mint vault, buyback vault, and complete specialized config hash.

Planned commit message: `feat: add buyback burn templates`

## Implementation Summary

### BuybackVault

- Exposes permissionless `executeBuyback(uint256 minOut,uint256 deadline)` and never accepts a caller-selected path or recipient.
- Sends swap output directly from the pinned Pancake router to `0x000000000000000000000000000000000000dEaD`; there is no caller bounty or withdrawal/recovery path.
- Enforces immutable nonzero threshold and maximum spend, spending `min(balance,maxSpend)` only after the threshold is met.
- Supports no schedule or an immutable interval from 5 minutes through 30 days. Scheduled execution advances `nextExecutionAt` before route/router external calls. A downstream revert atomically restores the prior timestamp and native balance, preserving the same retry slot and funds.
- Pins router, factory, WBNB, target, dependency codehashes, pair codehash, and the direct WBNB-to-target route hash. External targets additionally pin the canonical pair at creation.
- Validates the factory-returned pair's trusted runtime codehash and exact WBNB/target members. External-target creation also requires a nonzero trusted-router quote. It does not trust a target-supplied compatibility marker.
- Revalidates dependency and target codehashes, canonical route/pair, and a fresh quote at every execution.
- Derives an immutable-slippage quote floor and uses the greater of that floor and the permissionless caller's `minOut`, so a malicious caller can tighten but cannot weaken execution protection.
- Rejects expired deadlines, router-reported input mismatches, native balance mismatches, reported/delivered output mismatches, zero/malformed quotes, fee-on-transfer output, pair changes, runtime code changes, and reentrancy.
- Emits `BuybackFunded`, `BuybackExecuted`, and `Burned` events.

### Templates and Mint Lifecycle

- All three templates use the composite `(StandardConfig launch, SpecializedConfig buyback)` pattern and reject noncanonical ABI encodings.
- `AUTO_BUYBACK` targets the newly created project token with threshold, per-call cap, and maximum slippage.
- `TIMED_BUYBACK` targets the project token and adds the bounded immutable interval.
- `EXTERNAL_BURN` targets one immutable nonzero, non-WBNB contract and requires its trusted canonical direct pair and quote during companion construction.
- Template deployment is restricted to the immutable factory before any untrusted config decoding.
- The template snapshots and rechecks the finalization executor plus Pancake router/factory/WBNB codehashes and route before every project deployment.
- A template-owned immutable companion deployer keeps template runtime/initcode within applicable EVM deployment limits without proxies or mutable routing.

## Files

Created:

- `contracts/src/vaults/BuybackVault.sol`
- `contracts/src/templates/AutoBuybackTemplateV1.sol`
- `contracts/src/templates/TimedBuybackTemplateV1.sol`
- `contracts/src/templates/ExternalBurnTemplateV1.sol`
- `contracts/test/templates/BuybackTemplates.t.sol`
- `contracts/test/fuzz/BuybackBounds.fuzz.t.sol`

## TDD Evidence

### Initial RED

The unit/template and fuzz files were written before the four production files. Commands from `contracts/`:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackTemplates.t.sol
pnpm dlx @foundry-rs/forge test --match-path test/fuzz/BuybackBounds.fuzz.t.sol
```

Both reached Solidity compilation and failed for the intended missing-feature reason:

```text
Source "src/vaults/BuybackVault.sol" not found
Source "src/templates/AutoBuybackTemplateV1.sol" not found
Source "src/templates/ExternalBurnTemplateV1.sol" not found
Source "src/templates/TimedBuybackTemplateV1.sol" not found
Error: Compilation failed
```

The npm Forge launcher reported process exit code `0`; the textual Solidity compiler failure is authoritative, matching prior task behavior.

### Authorization Ordering RED/GREEN

Self-review added a regression proving factory authorization precedes malformed config decoding. Before the fix:

```text
pnpm dlx @foundry-rs/forge test --match-test testUnauthorizedCallerIsRejectedBeforeMalformedConfigDecoding
[FAIL: call reverted as expected, but without data]
0 passed; 1 failed
```

After adding the early factory gate:

```text
[PASS] testUnauthorizedCallerIsRejectedBeforeMalformedConfigDecoding
```

### Focused GREEN

Fresh final unit/template command:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackTemplates.t.sol
```

Result:

```text
BuybackVaultBehaviorTest:      16 passed; 0 failed
BuybackTemplateDeploymentTest:  6 passed; 0 failed
Focused total:                 22 passed; 0 failed; 0 skipped
```

Coverage includes threshold, exact cap/remainder, no bounty, direct dead output, attempted caller redirection, immutable target/route, missing/zero-quote external routes, deadline, 5-minute early boundary, pre-call interval advancement observed from inside the router, failed scheduled retry/fund preservation, reentrancy, quote-derived and caller minima, fee-on-transfer output, input/output report mismatches, and dependency codehash replacement.

Fresh final fuzz command:

```text
pnpm dlx @foundry-rs/forge test --match-path test/fuzz/BuybackBounds.fuzz.t.sol
```

Result:

```text
5 properties passed; 0 failed; 0 skipped
256 runs per property
```

The properties cover exact threshold/cap spending and retained balances, every generated valid slippage value, invalid intervals below 5 minutes and above 30 days, and execution-time-based advancement for valid intervals.

### Full GREEN

Fresh full-suite command:

```text
pnpm dlx @foundry-rs/forge test
```

Result:

```text
Ran 19 test suites: 159 tests passed, 0 failed, 0 skipped
```

This includes all existing MintVault invariants at 256 runs and 128,000 calls per invariant, plus the existing reward-accounting fuzz suite.

## Formatting, Lint, and Deployable Size

Commands from `contracts/`:

```text
pnpm dlx @foundry-rs/forge fmt --check
pnpm dlx @foundry-rs/forge lint
pnpm dlx @foundry-rs/forge build --force --sizes
```

All exited successfully. Task 8 paths add no lint warnings. Lint still reports two pre-existing warnings in `TimeWeightedRewardVault.sol` (one timestamp comparison and one bounded `uint64` cast).

Relevant runtime/initcode sizes:

```text
Contract                    Runtime      Initcode
BuybackVault                 5,577 B       9,214 B
AutoBuybackTemplateV1       18,872 B      30,481 B
TimedBuybackTemplateV1      18,983 B      30,592 B
ExternalBurnTemplateV1      19,025 B      30,641 B
BuybackCompanionDeployer    10,069 B      10,097 B
BuybackMintVault             7,576 B      12,539 B
```

Every runtime and initcode is below its applicable limit.

## Self-Review

- **Custody/lifecycle:** specialized MintVault subclasses only construct and expose the companion; base MintVault owns the launch supply and retains its existing principal state machine.
- **No redirection/bounty:** the public API has only minimum output and deadline. Route, target, recipient, threshold, cap, interval, and slippage ceiling are immutable. Tests append a malicious recipient to calldata and still observe direct dead delivery and zero caller proceeds.
- **Schedule ordering/retry:** `entered` and `nextExecutionAt` are set before route, quote, and swap calls. The router observes the advanced timestamp. Router failure reverts the complete call, restoring the old timestamp and all funds.
- **Slippage:** the effective minimum is `max(callerMin,quoteFloor)`. Tests cover a caller-provided zero minimum, an independently tighter minimum, and a router that ignores its minimum argument but returns insufficient output.
- **Exact asset effects:** router amounts must report exact native input and exact dead-wallet output; the vault's native balance must fall by exactly the spend; the target's dead balance must rise by exactly the report. Fee-on-transfer and false router accounting revert atomically.
- **Trusted route:** router/factory/WBNB and their codehashes are pinned and rechecked. Pair address (external mode), pair codehash, pair members, target codehash, and direct route hash are fixed/checkable. Route compatibility uses the trusted factory/pair/router rather than a target-token self-attestation method.
- **External target:** zero/EOA, WBNB, absent pair, untrusted pair code, wrong pair members, and zero/malformed quote paths are rejected by construction/runtime boundaries.
- **Config/version discovery:** all IDs/version constants are tested. Mapping and event assertions prove companion addresses and the composite config hash are indexable.
- **Bounds:** threshold and cap reject zero; scheduled intervals are either disabled or 5 minutes through 30 days; slippage is below 10,000 bps; fuzzing covers economic and timing bounds.
- **Mutation coverage:** moving schedule advancement after the router would fail the router-observation assertion; removing threshold/cap/dead-recipient/output-delta/dependency checks has a dedicated behavior test that would fail.

## Concerns / Follow-Up Boundaries

- The direct route intentionally supports WBNB-to-target pairs only. If a future schema needs multi-hop routes, it requires a new immutable template version and independent path/codehash validation rather than mutable route storage.
- Project-token templates cannot require their pair at creation because the canonical pair is created during MintVault finalization. They validate the pinned factory/WBNB target route and trusted pair bytecode on every execution. `EXTERNAL_BURN` additionally requires and pins its pair at creation.
- Chain 97 acceptance must still confirm production Pancake router/factory/WBNB/pair codehashes, direct route quotes/liquidity, exact router return arrays, and selected external-token transfer behavior.
- Plain `pnpm dlx forge` resolves an unrelated npm package in this environment and fails with `EISDIR`; all evidence uses the official `@foundry-rs/forge` package (version 1.7.1) via `pnpm dlx`.

---

## Fix Round 1 — 2026-08-29

### Status

All Critical, High, and Medium review findings were addressed. Buyback funding now originates from actual project-token buy/sell tax collection, permissionless buyback and tax processing require independently committed nonzero price floors, external targets require a platform-owned codehash approval plus concrete interface/runtime postconditions, scheduled execution starts at successful launch, and only accounted tax proceeds can be spent.

The final deployment layout uses two separately predeployed, immutable, codehash-pinned platform deployers (`BuybackCompanionDeployer` and `BuybackTaxProcessorDeployer`). Creators cannot provide or change router, factory, WBNB, quote controller, target registry, deployer, route, pair-codehash, or dependency-codehash values.

### Finding Resolution

1. **Tax-funded buybacks:** `LaunchToken` activates immutable buy/sell detection only after MintVault records the finalized canonical pair. It sends the bounded tax to `BuybackTaxProcessor`, whose explicit common-allocation mapping is `[marketing BNB -> receiver, liquidity project tokens -> canonical pair, rewards project tokens -> receiver, buyback BNB -> BuybackVault]`. Integer dust goes to liquidity, matching Task 6 allocation conservation. `rewardAsset`, `rewardThreshold`, all four allocation bps, receiver, and the full config hash remain directly readable. Only the processor can call `fundBuyback`; creator/manual calls revert.
2. **Independent price protection:** the platform-pinned `quoteController` commits an exact input, nonzero output floor, and expiry before either tax conversion or buyback execution. Missing, stale, zero, or wrong-input commitments revert. The fresh trusted-router quote and caller minimum can only tighten that independent floor.
3. **External target compatibility:** `TargetCompatibilityRegistry` is owned by the platform and allowlists runtime codehashes. External creation additionally performs exact-return `balanceOf(dead)` and `transfer(dead,0)` checks, pins the target codehash and canonical pair, and runtime execution requires the exact reported/direct-to-dead balance delta. Unapproved spoof, false-return, malformed-return, and fee-on-transfer profiles are rejected.
4. **Full project hash:** `BuybackMintVault.fullConfigHash`, `BuybackVault.fullConfigHash`, `LaunchToken.projectConfigHash`, `BuybackTaxProcessor.fullConfigHash`, `fullConfigHashOf[mintVault]`, and `BuybackCompanionDeployed.fullConfigHash` agree on `keccak256(abi.encode(common, standard, specialized))`. `LaunchFactory.ProjectDeployed.commonConfigHash` remains the separate common-only `ConfigHash.hash(common)` value; source and test names now reflect that distinction.
5. **Launch-relative schedule:** timed vaults start inactive. `BuybackMintVault._onLiquidityTokenSet` activates the schedule only inside a successful MintVault finalization, so the first slot is exactly `launchedAt + interval`. A failed bounded self-call rolls this activation back with the launch attempt.
6. **Runtime trust:** vault and tax-processor executions recheck dependency codehashes and reread `router.factory()` plus `router.WETH()` against the pinned platform route. Template deployment also rechecks executor, DEX, registry, and both companion deployers.
7. **Forced native isolation:** `accountedFunds` changes only through authorized `fundBuyback`. Thresholds, caps, and spend use that value, while raw/SELFDESTRUCT/router-callback native credits remain visible only through `unsolicitedNativeBalance` and cannot be spent or recovered.
8. **Nonzero execution:** independent floor commits reject zero, effective minima reject zero, trusted quotes reject zero, and successful swaps require a nonzero exact delivered output.
9. **Adversarial lifecycle coverage:** the new suite covers finalized pair activation, buy and sell tax collection, all four allocation buckets, accounted BNB funding, threshold/cap execution, direct dead output, dependency mutation, forced balances, schedule activation, canonical encoding, full hash consistency, external target profiles, and manual-funding rejection.

### TDD Evidence

#### RED — missing implementation

`contracts/test/templates/BuybackFixRound1.t.sol` was added before the production contracts and run from `contracts/`:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackFixRound1.t.sol
```

The Solidity compiler failed for the intended missing-feature reason:

```text
Source "src/core/TargetCompatibilityRegistry.sol" not found
Source "src/modules/BuybackTaxProcessor.sol" not found
Error: Compilation failed
```

Once the first implementation compiled, the executable RED run exposed three real fixture/behavior defects before GREEN:

```text
external unapproved-profile case: expected revert was not observed
taxed project-token buyback: OutputAmountMismatch(5e18, 4.5e18)
delayed timed launch fixture: FundingExpired
```

These led respectively to a genuinely distinct spoof runtime profile, a canonical-dead tax exemption so buyback output is not taxed again, and a delay that remains inside MintVault's immutable funding window. The subsequently added four-allocation test first failed with `InsufficientBalance(CREATOR,0,100e18)`, exposing a prank consumed while evaluating an external getter; reading the pair before the prank fixed the test setup without weakening the assertion.

#### RED — deployment limits

The first mandatory size run caught a production deployment blocker:

```text
pnpm dlx @foundry-rs/forge build --force --sizes

AutoBuybackTemplateV1       runtime 24,137 B; initcode 50,930 B; initcode margin -1,778 B
TimedBuybackTemplateV1      runtime 24,248 B; initcode 51,041 B; initcode margin -1,889 B
ExternalBurnTemplateV1      runtime 24,291 B; initcode 51,091 B; initcode margin -1,939 B
BuybackCompanionDeployer    runtime 25,031 B; runtime margin -455 B
Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)
```

Splitting vault and processor deployment into separately predeployed, immutable platform dependencies removed embedded creation code and brought every contract below EIP-170/EIP-3860.

### Final GREEN Evidence

Focused adversarial suite:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackFixRound1.t.sol
13 passed; 0 failed; 0 skipped
```

Existing Task 8 regression suite:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackTemplates.t.sol
22 passed; 0 failed; 0 skipped
```

Task 8 bounds fuzzing:

```text
pnpm dlx @foundry-rs/forge test --match-path test/fuzz/BuybackBounds.fuzz.t.sol
5 passed; 0 failed; 0 skipped; 256 runs per property
```

Factory common-hash naming regression:

```text
pnpm dlx @foundry-rs/forge test --match-path test/core/LaunchFactory.t.sol
10 passed; 0 failed; 0 skipped
```

Fresh post-refactor full suite:

```text
pnpm dlx @foundry-rs/forge test
Ran 20 test suites: 172 tests passed, 0 failed, 0 skipped
```

The full run includes four Mint accounting invariants at 256 runs / 128,000 calls each, the reward fuzz suite, and all Task 8 fuzz properties.

Formatting and lint:

```text
pnpm dlx @foundry-rs/forge fmt --check
# clean

pnpm dlx @foundry-rs/forge lint
# exits successfully; only the two pre-existing TimeWeightedRewardVault warnings remain
```

Final deployable sizes:

```text
pnpm dlx @foundry-rs/forge build --force --sizes

Contract                       Runtime     Runtime margin   Initcode    Initcode margin
AutoBuybackTemplateV1          24,110 B          466 B      26,053 B       23,099 B
TimedBuybackTemplateV1         24,221 B          355 B      26,164 B       22,988 B
ExternalBurnTemplateV1         24,264 B          312 B      26,214 B       22,938 B
BuybackCompanionDeployer       13,757 B       10,819 B      13,785 B       35,367 B
BuybackTaxProcessorDeployer    11,460 B       13,116 B      11,488 B       37,664 B
BuybackMintVault                8,224 B       16,352 B      16,724 B       32,428 B
BuybackTaxProcessor             7,736 B       16,840 B      10,276 B       38,876 B
BuybackVault                    8,065 B       16,511 B      12,672 B       36,480 B
```

The size command exits successfully. Solidity emits the expected test-only EIP-6780 deprecation warning for the SELFDESTRUCT forced-native fixture (and the existing MintVault fixture).

### Files

Created:

- `contracts/src/core/TargetCompatibilityRegistry.sol`
- `contracts/src/modules/BuybackTaxProcessor.sol`
- `contracts/test/templates/BuybackFixRound1.t.sol`

Modified:

- `contracts/src/core/LaunchFactory.sol`
- `contracts/src/templates/AutoBuybackTemplateV1.sol`
- `contracts/src/templates/TimedBuybackTemplateV1.sol`
- `contracts/src/templates/ExternalBurnTemplateV1.sol`
- `contracts/src/tokens/LaunchToken.sol`
- `contracts/src/vaults/BuybackVault.sol`
- `contracts/test/core/LaunchFactory.t.sol`
- `contracts/test/templates/BuybackTemplates.t.sol`
- `contracts/test/fuzz/BuybackBounds.fuzz.t.sol`

### Self-Review

- **Funding authority:** the platform-created tax processor is the one-time immutable funder. Direct native receipts never increment accounting, and there is no creator/owner withdrawal or recovery function.
- **Tax activation/custody:** tax and pair state remain inactive throughout funding. Activation occurs only after MintVault validates executor asset deltas and records the canonical liquidity token; any activation failure returns the launch to retryable `Filled` with supply/principal preserved.
- **Price-floor rollback:** floors are consumed before external calls, but any failure reverts the whole transaction, restoring the floor, accounted funds, and scheduled retry slot. Successful execution makes each commitment one-use.
- **Exact effects:** tax processing consumes the exact processor token balance; router arrays must report exact input/output; buyback output is measured only as the dead-wallet delta. Project-token transfers to the processor and canonical dead are explicitly tax-exempt to avoid recursive taxation or output clipping.
- **Trust root:** template constructor values are platform registration inputs, not creator config. Address and runtime codehash checks cover router, factory, WBNB, registry, deployers, finalization executor, canonical pair profile, and external target profile; dynamic router route getters are re-read on execution.
- **Target compatibility:** registry approval is necessary but not sufficient. Concrete creation checks catch known malformed/static incompatibilities; exact runtime dead-balance deltas catch output-transfer taxes or lies that survive the dry run.
- **Hash consistency:** the full composite hash is set once during construction and exposed at token, mint-vault, processor, buyback-vault, template mapping, and event boundaries. The Factory event intentionally remains common-only and is named accordingly.
- **Deployment:** final runtime/initcode checks are green. The separately deployed helper contracts are immutable and codehash-pinned; their permissionless deployment methods cannot alter a registered template or gain access to an existing project.

### Remaining Boundaries / Concerns

- Production deployment must use the exact audited router/factory/WBNB/pair/registry/deployer codehash bundle and an operational quote controller. A missing or stale controller commitment intentionally pauses processing without making funds withdrawable.
- Routes remain immutable direct project-token/WBNB and WBNB/target pairs. Supporting a multihop route requires a new template version with its own pinned path and compatibility policy.
- External-token compatibility is necessarily profile-based: the platform should approve only audited runtime codehashes and confirm Chain 97 transfer behavior. Runtime exact deltas remain the final safeguard.

---

## Fix Round 2 — 2026-08-29

### Status

All five open re-review findings are resolved. The finalized project/WBNB pair is now pinned and revalidated on both tax-processing and project-token buyback paths; holder rewards use cumulative `RewardVault` accounting with system exclusions; tax inputs use an authorized exact accounting boundary; and the liquidity allocation is paired with exact native value through the hardened Pancake/LP-disposition adapters instead of being transferred directly to the pair.

The Round 1 independent quote controller, external-target registry, composite config hash, launch-relative schedule, accounted BNB isolation, and nonzero-output checks remain intact. New `BuybackTaxInfrastructureDeployed` discovery includes the tax processor, holder reward vault, liquidity adapter, and full composite hash.

### Finding Resolution

1. **Runtime canonical pair validation:** every `processTax` re-reads `factory.getPair(projectToken,WBNB)` and requires the exact launch-pinned pair, trusted pair codehash, and exact members. Project-target `BuybackVault` now pins the successful launch pair and applies the same address/code/member checks at execution. Same-codehash remaps are rejected.
2. **Adversarial pair and pre-launch coverage:** tests mutate the factory mapping, replace stored-pair runtime code, and mutate pair members, then assert both processor and vault paths fail. Tax processing requires activated launch state, creator funding remains unauthorized, and raw native transfers never become accounted.
3. **Functional holder rewards:** reward allocations swap over the pinned project/WBNB/reward-asset route under their own exact independent quote commitment, accumulate to the immutable `rewardThreshold`, and fund `HolderDeadRewardVault`/`RewardVault`. MintVault, pair, buyback vault, processor, liquidity adapter, dead address, and accounting companions cannot receive holder weight. Claims are pull-based and conservation includes the cumulative-accounting rounding remainder.
4. **Dust-resistant tax accounting:** `LaunchToken` notifies MintVault of each exact tax credit; MintVault is the only controller allowed to call `recordTax`. Processing consumes a bounded committed portion of `accountedTaxTokens`, never the untrusted live whole-token balance. Unsolicited project tokens stay visible through `unaccountedTaxTokenBalance` and cannot invalidate, inflate, or fund a committed batch.
5. **Real liquidity allocation:** liquidity tokens accumulate until a complete token/native batch exists. Half is converted to native under the independent processing floor; the exact other half and exact native amount go through a per-project, platform-pinned `PancakeV2Adapter`, which validates router consumption, canonical pair/code/members, LP mint delta, and immutable burn/lock disposition through `LpLockerAdapter`. The pinned adapter is explicitly tax-exempt so adding liquidity is not recursively taxed. Remainders stay accounted in the processor and pair balances remain non-skimmable.

Additional hardening isolates forced native delivered during a tax swap: only the trusted router-reported native output is allocated, while excess raw balance remains stranded and cannot inflate BuybackVault funding. Scheduled execution now rejects inactive schedules before threshold evaluation, and the timed lifecycle test obtains its funding only from post-launch tax processing.

### TDD Evidence

#### RED — executable adversarial tests

The Round 2 tests were written first in `contracts/test/templates/BuybackFixRound1.t.sol`. The first compile correctly failed because `BuybackMintVault.holderRewardVault` did not yet exist. Local test-only interfaces then allowed an executable RED run without adding production stubs:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackFixRound1.t.sol

Ran 21 tests: 13 passed; 8 failed
```

The eight intended failures were:

```text
testFactoryPairRemapCannotReplacePinnedProjectRouteForProcessorOrVault
  next call did not revert
testStoredPairCodehashReplacementBlocksProcessorAndVault
  next call did not revert
testStoredPairMemberMutationBlocksProcessorAndVault
  next call did not revert
testForcedProjectTokenDustCannotInvalidateOrInflateCommittedTaxBatch
  InvalidProcessingFloor
testRewardAllocationFundsExcludedHolderAccountingAndConservesClaims
  InvalidProcessingFloor
testFullLiquidityAllocationMintsAndBurnsLpWithoutSkimmableTaxTokens
  liquidity LP not burned
testPartialLiquidityAllocationRetainsOnlyUnpairableRemainder
  InvalidProcessingFloor
testPreLaunchTaxFundingAndBuybackExecutionRemainImpossible
  EvmError: Revert
```

These failures directly demonstrated the missing pair revalidation, exact tax-accounting boundary, holder-reward path, liquidity path, and pre-launch accounting reads.

#### RED — deployment size self-review

The first size audit after functional GREEN caught an EIP-170 blocker caused by one helper embedding both processor and liquidity-adapter creation code:

```text
BuybackTaxProcessorDeployer runtime: 30,165 B
```

Splitting the Pancake adapter creation into the immutable `BuybackLiquidityDeployer`, referenced by the registered tax deployer, reduced the final tax deployer runtime to `20,235 B` without introducing proxies or creator-supplied dependencies.

### Final GREEN Evidence

Commands below were run from `contracts/` with the official Forge package.

Focused Round 1/2 adversarial suite:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackFixRound1.t.sol
23 passed; 0 failed; 0 skipped
```

Original Task 8 regression suite:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackTemplates.t.sol
22 passed; 0 failed; 0 skipped
```

Threshold/slippage/interval fuzz suite:

```text
pnpm dlx @foundry-rs/forge test --match-path test/fuzz/BuybackBounds.fuzz.t.sol
5 passed; 0 failed; 0 skipped; 256 runs per property
```

Fresh full suite:

```text
pnpm dlx @foundry-rs/forge test
Ran 20 test suites: 182 tests passed, 0 failed, 0 skipped
```

The full run includes the four Mint accounting invariants at 256 runs / 128,000 calls each, seven reward-accounting fuzz properties, and all five buyback bound properties.

Formatting, lint, and deployable sizes:

```text
pnpm dlx @foundry-rs/forge fmt --check
# clean

pnpm dlx @foundry-rs/forge lint
# success; only the two pre-existing TimeWeightedRewardVault warnings remain

pnpm dlx @foundry-rs/forge build --force --sizes
# success
```

Relevant final sizes:

```text
Contract                       Runtime     Runtime margin   Initcode    Initcode margin
AutoBuybackTemplateV1           8,035 B       16,541 B      10,086 B       39,066 B
TimedBuybackTemplateV1          8,146 B       16,430 B      10,197 B       38,955 B
ExternalBurnTemplateV1          8,189 B       16,387 B      10,247 B       38,905 B
BuybackVault                    8,386 B       16,190 B      13,022 B       36,130 B
BuybackTaxProcessor            14,464 B       10,112 B      18,346 B       30,806 B
BuybackTaxProcessorDeployer    20,235 B        4,341 B      20,539 B       28,613 B
BuybackLiquidityDeployer       10,351 B       14,225 B      11,010 B       38,142 B
BuybackProjectDeployer         21,835 B        2,741 B      21,863 B       27,289 B
BuybackMintVault                9,127 B       15,449 B      19,067 B       30,085 B
```

### Files Modified

- `contracts/src/modules/BuybackTaxProcessor.sol`
- `contracts/src/templates/AutoBuybackTemplateV1.sol`
- `contracts/src/tokens/LaunchToken.sol`
- `contracts/src/vaults/BuybackVault.sol`
- `contracts/src/vaults/HolderDeadRewardVault.sol`
- `contracts/src/vaults/MintVault.sol`
- `contracts/test/templates/BuybackFixRound1.t.sol`
- `contracts/test/templates/BuybackTemplates.t.sol`

### Self-Review

- **Tax boundary:** only tax credits emitted by the project token and relayed through the immutable MintVault controller increase `accountedTaxTokens`. Raw project-token balance is never an input oracle. The postcondition conserves accounted tax, retained liquidity/reward balances, and pre-existing unsolicited dust separately.
- **Pair trust:** processor and vault both require the exact launch-pinned address, not merely a matching codehash. Codehash and token members are re-read on every affected execution. Router factory/WETH and their pinned runtime hashes are also re-read.
- **Reward conservation:** the holder allocation never reaches the receiver as project tokens. External reward swaps require exact input, exact balance delta, pinned route, independent amount/minimum/expiry, and runtime route validation. Thresholded assets have no owner/creator recovery path.
- **Liquidity conservation:** no allocation transfers tokens directly to the pair. The hardened adapter pulls exact tokens, consumes exact native, validates LP creation, and immediately burns or locks LP. Incomplete batches stay in processor accounting, and the tests prove no pair-skimmable surplus.
- **System exclusions:** pair, processor, buyback vault, liquidity adapter, dead, MintVault/controller, wrapper, and inner accounting vault cannot dilute live holder weight. Only the pinned liquidity adapter is exempted from project-token tax for system liquidity operations.
- **Failure rollback:** processing/schedule/accounting effects are set before external calls where required; any router, adapter, reward-vault, or postcondition failure reverts the transaction, restoring quote floors, funds, retained assets, and retry time.
- **Deployment trust and size:** creators never provide infrastructure dependencies. Registered template/deployer instances and their immutable constructor values are the platform trust root. All runtime and initcode sizes are within EIP limits.

### Remaining Boundaries / Concerns

- Production registration must pin the audited router/factory/WBNB/pair profile, LP adapter, optional allowlisted locker, target registry, all companion deployers, and operational quote controller. Incorrect platform deployment parameters intentionally make project creation or processing fail closed.
- The reward route is the immutable direct `projectToken -> WBNB -> rewardAsset` route. Adding alternate multihop routes or different holder/dead reward splits requires a new template version and schema.
- Sub-two-token liquidity allocations are intentionally retained until an exact token/native batch can be formed. They are not recoverable by creator or Owner and remain available to a later permissionless processing call.
- The SELFDESTRUCT warnings are confined to forced-balance test fixtures; production contracts do not use SELFDESTRUCT. Chain 97 acceptance remains required for the pinned production codehash bundle and real router/locker behavior.

---

## Fix Round 3 — 2026-08-29

### Status

The remaining liquidity-path finding is resolved. Tax processing now stages separately accounted project-token and native liquidity sides instead of requiring an immediate exact-ratio add. The immutable quote controller commits an exact bounded batch, independent token/native minima, LP minimum, and expiry. Permissionless execution uses those bounds with the pinned Pancake adapter, accounts only actual consumption, and retains exact router leftovers for later processing.

The original MintVault launch path remains exact-consumption-only. The new bounded adapter entrypoint is used only by the immutable tax processor, whose `token()` launch context is statically verified by the adapter. Existing pair-address/code/member checks, router/factory/WBNB runtime trust checks, independent buyback/reward floors, reward accounting, LP burn/lock disposition, tax-token accounting, and forced-balance isolation remain intact.

### Finding Resolution

1. **Independent bounded liquidity floor:** only the immutable `quoteController` can commit the desired token/native sides, their nonzero minima, minimum LP output, and expiry. Desired sides cannot exceed staged accounting; missing or stale commitments fail closed. Anyone may trigger execution but cannot weaken the committed bounds.
2. **Production-compatible V2 optimization:** `PancakeV2Adapter.addLiquidityWithBounds` passes independent minima to the standard `addLiquidityETH` ABI and accepts actual token/native consumption only inside `[minimum, desired]`. The existing MintVault `execute` and `addLiquidity` methods continue to require exact consumption.
3. **Exact effects and disposition:** the adapter verifies the canonical pinned pair, project-token and WBNB reserve deltas, router-reported consumption, exact LP balance delta, and immutable burn/lock result. Processor and adapter allowances are reset after use.
4. **Refund and accounting conservation:** router ETH refunds are accepted only from the pinned router while the adapter reentrancy guard is active. The adapter returns only `desired - actual` token/native amounts to its immutable caller. The processor classifies those exact refunds back into `availableLiquidityTokens` and `pendingLiquidityNative`, so final accounting decreases only by actual consumption and leftovers can be used by later processing.
5. **Dust isolation:** processor and adapter accounting is based on staged amounts and measured deltas, not whole live balances. Pre-existing or callback-forced project tokens/native remain outside accounted liquidity, cannot be forwarded or refunded, and do not brick successful optimized adds.
6. **Asymmetric-router adversarial coverage:** the test router implements V2-style side optimization from explicit asymmetric token/native reserves. Tests cover token-side leftover, native-side refund, later leftover reuse, full and partial allocations, an unpairable retained remainder, too-tight minima, missing/stale floors, malicious token/native/LP reports, forced dust, zero skim exposure, exact LP burn, and exact bounded LP lock.

### TDD Evidence

#### RED — executable asymmetric-router tests

The six Round 3 processor tests were added before production changes and run from `contracts/`:

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackFixRound1.t.sol -vv

Ran 29 tests: 23 passed; 6 failed; 0 skipped
```

The intended failures were:

```text
testLiquidityForcedTokenAndNativeDustStayUnaccountedAcrossRefunds
  liquidity minimum
testLiquidityIndependentMinimaFailurePreservesFloorAndAccountedAssets
  liquidity minimum
testLiquidityMisreportedConsumptionAndLpCannotCorruptAccounting
  EvmError: Revert
testOptimizingRouterRetainsNativeRefundAndUsesItInLaterProcessing
  liquidity minimum
testOptimizingRouterRetainsTokenSideLeftoverAndBurnsExactLp
  liquidity minimum
testPartialLiquidityStagesOnlyPairableTokensAndKeepsUnsplitRemainder
  partial token accounting
```

This demonstrated that the old path still passed exact desired minima, added liquidity immediately, and lacked staged token/native accounting and a separate bounded execution commitment.

#### GREEN — focused suites

```text
pnpm dlx @foundry-rs/forge test --match-path test/templates/BuybackFixRound1.t.sol -vv
30 passed; 0 failed; 0 skipped

pnpm dlx @foundry-rs/forge test --match-path test/adapters/LiquidityAdapters.t.sol -vv
18 passed; 0 failed; 0 skipped
```

The adapter suite includes a bounded partial-consumption lock test that proves exact token/native refunds, exact reported spend, exact LP delivery to the allowlisted immutable locker, and zero residual router allowance. The processor suite includes the realistic asymmetric reserve cases and a stale-floor retry-preservation case added during hardening.

#### GREEN — full regression, fuzz, invariants, format, and lint

```text
pnpm dlx @foundry-rs/forge test
Ran 20 test suites: 190 tests passed, 0 failed, 0 skipped
```

The full run includes all five buyback bound properties and all seven reward-accounting properties at 256 fuzz runs each, plus four Mint accounting invariants at 256 runs / 128,000 calls each.

```text
pnpm dlx @foundry-rs/forge fmt --check
# clean

pnpm dlx @foundry-rs/forge lint
# success; only the two pre-existing TimeWeightedRewardVault warnings remain
```

#### GREEN — deployable size check

```text
pnpm dlx @foundry-rs/forge build --force --sizes
# success
```

Relevant final sizes:

```text
Contract                       Runtime     Runtime margin   Initcode    Initcode margin
AutoBuybackTemplateV1           8,035 B       16,541 B      10,086 B       39,066 B
TimedBuybackTemplateV1          8,146 B       16,430 B      10,197 B       38,955 B
ExternalBurnTemplateV1          8,189 B       16,387 B      10,247 B       38,905 B
BuybackCompanionDeployer       14,107 B       10,469 B      14,135 B       35,017 B
BuybackLiquidityDeployer       12,643 B       11,933 B      13,302 B       35,850 B
BuybackTaxProcessor            16,952 B        7,624 B      20,869 B       28,283 B
BuybackTaxProcessorDeployer    22,758 B        1,818 B      23,062 B       26,090 B
PancakeV2Adapter                8,744 B       15,832 B      10,896 B       38,256 B
```

### Files Modified

- `contracts/src/adapters/PancakeV2Adapter.sol`
- `contracts/src/modules/BuybackTaxProcessor.sol`
- `contracts/test/adapters/LiquidityAdapters.t.sol`
- `contracts/test/templates/BuybackFixRound1.t.sol`
- `.superpowers/sdd/2026-08-29-70x-corla-platform-implementation/task-8-report.md`

### Self-Review

- **Accounting partition:** `pendingLiquidityTokens` is the total retained project-token liability; `availableLiquidityTokens` is the executable/refunded token side; `pendingLiquidityUnsplitTokens` is the unpairable input remainder; and `pendingLiquidityNative` is the exact native liability. Successful execution reduces these liabilities by router-measured actual consumption only.
- **Atomic retry:** floor fields and desired accounting are cleared/decremented before external calls. Any router, adapter, LP-disposition, result, or postcondition failure reverts the transaction, restoring the floor, allowances, assets, and accounting for retry.
- **No refund redirection:** neither executor nor quote controller supplies a refund recipient. The adapter returns measured leftovers only to `msg.sender`, which is the codehash-pinned processor in the bounded template path. There is no creator/owner recovery method.
- **Runtime verification:** each processor execution rechecks router/factory/WBNB codehash and route getters plus the exact launch-pinned pair address/code/members. The adapter independently repeats dependency codehash/route and pair/code/member checks and validates pair asset deltas.
- **Forced balances:** adapter snapshots include pre-existing dust, refunds only the bounded batch difference, and leaves raw surplus in place. Processor postconditions require old unaccounted balances to remain and allow newly forced surplus to remain unaccounted rather than bricking execution.
- **Legacy lifecycle:** exact MintVault finalization remains strict and all prior custody/lifecycle tests pass. Bounded execution cannot occur before launch activation because there are no staged sides and `processLiquidity` requires the pinned pair.

### Remaining Boundaries / Concerns

- Task 15 must confirm the selected Chain 97 router's deployed `addLiquidityETH` ABI, return values, ETH-refund behavior, WBNB-to-pair reserve delta, pair sync behavior, and pinned runtime codehash. Round 3 uses the canonical V2 ABI but does not treat unverified Chain 97 behavior as established evidence.
- Production quote-controller operations must calculate desired sides and minima from an independent trusted source, set bounded expiries, and refresh commitments when pool reserve ratios change. A missing, stale, or overly strict commitment intentionally preserves funds and pauses liquidity execution.
- Retained sub-batch tokens and optimized leftovers have no creator/owner withdrawal path. They remain isolated in processor accounting until a later independently committed permissionless liquidity execution can consume them.
