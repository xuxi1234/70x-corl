# Task 7 Report: Time-Weighted, LP, and Holder/Dead Rewards

## Status

Implemented three factory-compatible, versioned reward launch templates and their non-enumerating companion vaults:

- `TIME_WEIGHTED`, version `1`
- `LP_REWARDS`, version `1`
- `HOLDER_DEAD`, version `1`

All three templates preserve the existing `MintVault` funding/finalization/claim lifecycle. The entire initial project-token supply remains in the mint vault, and each template records and emits the companion reward-vault address. Selected reward assets are funded directly and exactly; these templates do not claim or attempt an unsupported project-token-to-reward-token conversion.

Planned commit message: `feat: add reward launch templates`

## Binding Interface Rulings Applied

- LP accounting uses permissionless `syncWeight(account)` reads against the immutable canonical LP token. A claim first synchronizes its caller. `lastSyncedBalance`, `lastSyncedAt`, and `LpWeightSynced` make stale state visible. Accrual follows the last synchronized balance until another sync.
- Time weighting uses bounded per-account active tranches, same-timestamp receipt merging, newest-first consumption, an exact global weight numerator/base/slope aggregate, and timestamp-ordered cap-expiry buckets.
- Expiry processing is gas bounded. Ordinary funding, claim, and transfer checkpoints process at most 64 due expiry buckets. Permissionless `checkpoint(maxExpiries)` processes at most 256 per call and reports whether it caught up. Economic actions never approximate overdue weights: if more than 64 buckets remain due, they revert until the explicit crank catches up.
- Specialized subtuples are exactly:
  - time weighted: `(uint16 maxMultiplierBps,uint32 growthDuration)`
  - LP rewards: `(address lpToken,uint256 minimumEligibleBalance)`
  - holder/dead: `(uint16 holderBps,uint16 deadBps)`
- Each template config is the composite `(StandardConfig launch, SpecializedConfig rewards)`, preserving creator-selected mint economics and validating canonical ABI encoding of both.
- The templates deploy companion vaults alongside specialized `MintVault` subclasses. MintVault-routed transfer callbacks preserve vault-only initial supply and update time/holder accounting only after actual token transfers.

## Implementation Summary

### TimeWeightedRewardVault

- Enforces a `1.0x` through `3.0x` multiplier and a 1 through 30 day growth duration.
- Stores at most 64 active tranches per account and merges receipts at the same timestamp.
- Consumes outgoing transfers newest first; capped balances are compacted into a single per-account aggregate.
- Maintains exact global weight as a numerator over the immutable basis-point/duration denominator. Active slope is advanced between ordered cap expiries, with one scheduled bucket per timestamp.
- Uses dual cumulative reward indexes (`rewardIndex` and `timeRewardIndex`) so a lazily settled tranche receives its exact instantaneous weight at every funding, including fundings on both sides of its cap expiry.
- Funding, claim delivery, and accounting use exact balance deltas and retain scaled rounding dust without exceeding funding.
- Zero, the canonical dead address, MintVault inventory, and the finalized AMM pair are never live-holder weight. Transfers during MintVault's atomic `Executing` state do not temporarily credit the executor/router/pair path; the pair becomes an immutable exclusion when MintVault records it.
- Loops only over a caller/account's bounded tranches or a caller-selected bounded expiry batch; it never enumerates holders.

### LpRewardVault

- Pins the canonical LP token, its runtime codehash, and an immutable minimum eligible balance.
- Allows anyone to synchronize any account from the LP token's current `balanceOf`.
- Records synchronized balance/time and emits old/new weight.
- Forces caller synchronization before claim while preserving rewards accrued under the prior synchronized weight.
- Excludes zero, the canonical dead address, the outer vault, and the inner accounting vault from eligible LP weight, and rejects using the LP token itself as its reward asset.
- Composes the hardened cumulative `RewardVault`; controller-triggered proxy claims can only deliver to the named account.

### HolderDeadRewardVault

- Enforces holder/dead basis points totaling exactly `10_000`.
- Excludes zero and the canonical dead address from live-holder weight.
- Excludes MintVault inventory and the finalized AMM pair from live-holder weight; the separate configured dead share is therefore never double-counted as holder weight.
- Updates only transfer participants from actual post-transfer project-token balances.
- Pulls the selected reward asset exactly, sends the dead share directly and exactly to `0x000000000000000000000000000000000000dEaD`, and funds only the holder remainder in cumulative accounting.
- Exposes no Owner/creator recovery or dead-share claim path.

### Templates and Mint Lifecycle

- `TimeWeightedTemplateV1`, `LpRewardsTemplateV1`, and `HolderDeadTemplateV1` implement `ITemplate`, restrict deployment to their immutable factory, expose immutable IDs/version constants, validate common and composite template ABI encodings, and emit `RewardCompanionDeployed` with token, mint vault, reward vault, and complete config hash.
- Initial supply remains entirely in `MintVault`; creators receive no inventory and have no withdrawal path.
- `LaunchToken` calls its immutable mint-vault observer after each real transfer. Base `MintVault` validates that only its token can call and provides a no-op hook, preserving standard launches. Specialized mint vaults override only the internal hook.
- `MintVault` also invokes a no-op-by-default liquidity-token hook in the same successful finalization transaction that records the pair. Specialized vaults use it to make pair exclusion active atomically; pre-launch vault inventory and post-launch pair inventory cannot dilute or strand rewards.
- The LP template snapshots the selected executor/factory/WBNB codehashes and route, rechecks them at deployment, creates or resolves the canonical project/WBNB pair through the pinned factory, checks exact pair membership and the configured expected pair, then pins it in `LpRewardVault`.
- Companion construction is split into immutable helper deployers created with each template. This keeps all template runtimes below EIP-170 without adding upgradeability or mutable routing.

## Files

Created:

- `contracts/src/vaults/TimeWeightedRewardVault.sol`
- `contracts/src/vaults/LpRewardVault.sol`
- `contracts/src/vaults/HolderDeadRewardVault.sol`
- `contracts/src/templates/TimeWeightedTemplateV1.sol`
- `contracts/src/templates/LpRewardsTemplateV1.sol`
- `contracts/src/templates/HolderDeadTemplateV1.sol`
- `contracts/src/templates/RewardTemplateTypes.sol`
- `contracts/test/templates/RewardTemplates.t.sol`
- `contracts/test/fuzz/RewardAccounting.fuzz.t.sol`

Modified:

- `contracts/src/tokens/LaunchToken.sol`
- `contracts/src/vaults/MintVault.sol`
- `contracts/src/vaults/RewardVault.sol`
- `contracts/test/vaults/RewardVault.t.sol`

## TDD Evidence

### Initial RED

The two required test files were written before the six required production artifacts. Command, from `contracts/`:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/templates/RewardTemplates.t.sol'
```

Expected result:

```text
Source "src/vaults/HolderDeadRewardVault.sol" not found
Source "src/vaults/LpRewardVault.sol" not found
Source "src/vaults/TimeWeightedRewardVault.sol" not found
Source "src/templates/HolderDeadTemplateV1.sol" not found
Source "src/templates/LpRewardsTemplateV1.sol" not found
Source "src/templates/TimeWeightedTemplateV1.sol" not found
Error: Compilation failed
```

The npm Forge launcher reported process exit code `0`; the textual compiler failure is authoritative, matching earlier task behavior.

### Boundary RED/GREEN

LP runtime replacement test before the codehash boundary existed:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-test testLpSyncRejectsCanonicalTokenRuntimeReplacement
Error: Member "UnexpectedLpTokenCodehash" not found
Error: Compilation failed
```

LP mutable-executor-route test before route revalidation existed:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-test testLpTemplateRejectsExecutorWhosePinnedRouteChanges
Error: Member "UnexpectedExecutorRoute" not found
Error: Compilation failed
```

After the minimal boundaries were implemented, both regressions passed in the focused template suite.

Final live-holder eligibility regressions were also observed RED before implementation:

```text
testHolderPairBecomesAtomicallyExcludedWithoutDilutiveWeight: FAIL
testTimeWeightedPairBecomesAtomicallyExcludedWithoutDilutiveWeight: FAIL
testFinalizationAtomicallyExcludesPairThenClaimsCreateLiveWeight: FAIL
testHolderDeadTemplateDeploysMintCustodyAndDiscoverableCompanion: FAIL
testTimeWeightedTemplateIsFactoryCompatibleAndKeepsSupplyInMintVault: FAIL
0 passed; 5 failed
```

After adding the atomic MintVault liquidity hook and live-holder exclusions, all five passed. Additional LP regressions cover dead/vault LP balances and self-referential LP reward assets.

The same-expiry scheduling guard received an explicit mutation check. Replacing the `expiryScheduled` guard with a slope-nonzero check and running:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-test testOneTimesReceiptsShareOneScheduledExpiryBucket
```

produced:

```text
[FAIL: zero-slope receipts duplicated the same expiry bucket]
0 passed; 1 failed
```

Restoring the guard returned the regression and focused suite to green. This proves the one-expiry-bucket behavior even for a `1.0x` configuration whose slope is zero.

### Focused GREEN

Reward templates and vault behavior:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/templates/RewardTemplates.t.sol'
RewardTemplateDeploymentTest: 7 passed; 0 failed
RewardVaultBehaviorTest: 18 passed; 0 failed
Focused total: 25 passed; 0 failed
```

Base reward accounting, including controller-only account-directed claims:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --match-path 'test/vaults/RewardVault.t.sol'
RewardVaultTest: 7 passed; 0 failed
```

Transfer-sequence/accounting fuzzing with claims interleaved:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/fuzz/RewardAccounting.fuzz.t.sol' --fuzz-runs 512
RewardAccountingFuzzTest: 3 passed; 0 failed
512 runs per fuzz property
```

The fuzz properties cover time-weighted, LP-sync, and holder/dead transfer sequences and assert claimed plus claimable (plus direct dead distribution where applicable) never exceeds funding. Exact on-contract reward-asset balances plus claimed/directly distributed amounts also equal funding.

### Full GREEN

Fresh full-suite command:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force
```

Result:

```text
Compiling 32 files with Solc 0.8.28
Compiler run successful
Ran 16 test suites: 120 tests passed, 0 failed, 0 skipped
```

This includes all four existing MintVault invariants at 256 runs and 128,000 calls each with zero handler reverts. The only compiler warning is the pre-existing Task 5 `selfdestruct` force-native test helper.

## Formatting, Lint, and Deployable Size

Commands:

```text
pnpm dlx @foundry-rs/forge@1.7.1 fmt --check
pnpm dlx @foundry-rs/forge@1.7.1 lint --force
pnpm dlx @foundry-rs/forge@1.7.1 build --force --sizes
```

All exited successfully. Full lint reports only the pre-existing `selfdestruct` compiler warning in `test/vaults/MintVault.t.sol`.

Relevant final runtime sizes:

```text
TimeWeightedRewardVault       10,134 B
LpRewardVault                  3,883 B
HolderDeadRewardVault          5,967 B
TimeWeightedTemplateV1        16,428 B
LpRewardsTemplateV1           17,590 B
HolderDeadTemplateV1          16,345 B
TimeWeightedCompanionDeployer 12,461 B
LpRewardCompanionDeployer     10,070 B
HolderDeadCompanionDeployer   11,691 B
```

Every runtime and initcode is below its applicable limit. The first size check caught the original monolithic templates above EIP-170 (`26,895 B`, `25,884 B`, and `26,052 B`); immutable helper deployers fixed that deployment blocker.

## Self-Review

- **Mint custody:** successful factory deployment tests assert the entire initial supply remains at the returned MintVault and creator inventory is zero. That pre-launch custody has zero reward weight.
- **Transfer authority:** `LaunchToken` has one immutable observer (its mint vault); `MintVault` rejects callback calls from any address except its own token. Specialized vault callbacks accept only their immutable specialized mint vault controller.
- **Time age:** hand-derived funding fixtures cover different-age tranches, linear growth, the `3x` cap, funding across cap expiries, and newest-first removal. The old tranche timestamp and amount remain unchanged after a newer tranche is consumed.
- **Time gas bounds:** active account tranches cap at 64, same-timestamp receipts merge, expiry queues store one bucket per timestamp, ordinary checkpoints cap at 64, and explicit checkpoints cap at 256. Batch-processing tests prove the final capped aggregate is exact.
- **No holder enumeration:** there is no holder array. Holder/dead and LP updates touch one or two explicit accounts. Time loops only over one account's bounded tranches or bounded global expiry buckets.
- **LP trust and staleness:** the template derives/creates the pair only through the pinned factory/WBNB route; route and dependency codehashes are rechecked. The vault rechecks LP runtime codehash on every sync. Tests explicitly document last-sync accrual and claim-time sync.
- **Live-holder eligibility:** zero, dead, MintVault/controller inventory, finalized pair inventory, and LP reward-vault inventory are excluded. An end-to-end finalization proves pair inventory has zero weight and a later token claim creates exactly the live user's weight.
- **Dead authority:** the dead address is a constant, has zero holder weight, receives its reward asset directly, and has no claim/recovery path. Holder plus dead funding is assigned exactly once, with integer remainder left in the holder share.
- **Reward asset boundary:** all companion vaults pull the configured reward token exactly and verify actual funding/delivery deltas. No caller-selected router, route, conversion, or substitute asset exists. Template creation requires selected reward-token code.
- **Accounting:** fuzzed transfer/funding/claim sequences cover all three models. Claimed plus pending plus direct-dead amounts never exceed funding, while held reward assets plus completed payouts exactly equal funding.
- **Version/discovery:** immutable uppercase IDs and version `1` are tested. Template mappings/events expose the companion, token, mint vault, and complete template config hash for later schema/indexer work.
- **Mutation checks:** removing the zero-slope expiry scheduling guard fails its regression. LP runtime replacement and executor route mutation both have dedicated rejection tests.

## Concerns / Follow-Up Boundaries

- LP rewards deliberately follow the last synchronized balance. LP transfers do not callback on Pancake V2, so an indexer/UI must surface `lastSyncedBalance`/`lastSyncedAt` and offer permissionless sync. This is explicit behavior, not hidden real-time accounting.
- A time-weighted project with more than 64 overdue distinct expiry timestamps must be advanced through permissionless `checkpoint` calls before funding, claim, or project-token transfer can proceed. The manual crank is exact and gas bounded; Task 11/12 UI and keeper work should surface/call it proactively.
- An account cannot hold more than 64 simultaneously active distinct-timestamp tranches. Same-timestamp receipts merge, and expired tranches compact on the next account checkpoint. A 65th still-active distinct receipt reverts atomically instead of creating an unbounded claim/transfer cost.
- LP template callers must provide the expected deterministic canonical pair address. The template creates the pair through the pinned factory when absent and rejects any mismatch; deployment tooling must compute this address from the predicted launch token and production Pancake factory.
- Chain 97 acceptance must still validate the production factory's `createPair/getPair/token0/token1` behavior, Pancake pair bytecode, the selected custom reward tokens, and off-chain LP sync/checkpoint operations.

## Fix Round 1

### Status

PASS. All review findings are addressed with focused unit regressions and fuzz properties.

- Composed LP and holder/dead accounting vaults now instantiate `RewardVault` in immutable `ControllerOnly` mode. Direct inner funding and direct inner claims reject, while the standalone/base `RewardVault` retains its original public funding and self-claim behavior through `Public` mode.
- Time-weighted expiries now use an indexed removable min-heap. A fully canceled timestamp is removed immediately, heap processing counts only live work, and `1x` projects keep constant balances directly in the capped aggregate without scheduling economically empty expiries.
- The externally fillable 64-tranche hard stop is removed. Exact receipt timestamps remain stored, outgoing consumption remains newest-first, recipient-side receipts do not settle prior history, and claims settle at most 256 tranches per call while retaining scaled remainder for subsequent calls. A regression exercises 300 distinct dust receipts, funding before and after a legitimate receipt, two exact batched claims, and newest-first outgoing conservation.
- Time-weighted companions, holder/dead companions, and holder/dead inner accounting vaults are excluded from project-token live weight. Funding tests prove the remaining live holder receives the entire holder allocation without stranded companion weight.
- Fuzzing now covers direct inner bypass attempts, 100+ timestamp cancel/recreate churn, >64 distinct dust receipt saturation, and companion-held project-token balances.

The prior report's statements that account tranches are capped at 64 and that zero-slope receipts schedule an expiry bucket are superseded by this round.

### RED Evidence

The inherited partial access-mode change first exposed the remaining LP constructor using the obsolete public constructor shape:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/templates/RewardTemplates.t.sol'
Error (6160): Wrong argument count for function call: 2 arguments given but expected 3.
  --> src/vaults/LpRewardVault.sol:40:28
Error: Compilation failed
```

Before the time-queue implementation, the focused template suite produced the expected behavior failures:

```text
[FAIL: zero-slope receipts created economically empty expiry work] testOneTimesReceiptsShareOneScheduledExpiryBucket
[FAIL: removed middle expiry remained scheduled] testTimeWeightedExpiryHeapRemovesMiddleBucketAndProcessesInOrder
[FAIL: expired tranche compaction was not linear] testTimeWeightedMaxTrancheCompactionIsLinearForBothTransferParticipants
[FAIL: consumed tranches left empty expiry buckets] testTimeWeightedPingPongRemovesEmptyExpiryBucketsImmediately
```

The saturation and companion exclusions were separately observed RED:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-test 'testTimeWeightedMoreThanSixtyFourDustReceiptsCannotBlockLegitimateReceiptOrClaim|testCompanionProjectTokenBalancesHaveZeroWeightAndDoNotStrandRewards'
[FAIL: time companion became live weight] testCompanionProjectTokenBalancesHaveZeroWeightAndDoNotStrandRewards
[FAIL: MaxTranchesExceeded(0x0000000000000000000000000000000000000B0b)] testTimeWeightedMoreThanSixtyFourDustReceiptsCannotBlockLegitimateReceiptOrClaim
0 passed; 2 failed
```

An explicit mutation check changed both composed accounting vaults back to `Public` mode:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-test testLpAndHolderComposedAccountingRejectsDirectInnerBypasses
[FAIL: LP staker bypassed wrapper claim semantics] testLpAndHolderComposedAccountingRejectsDirectInnerBypasses
0 passed; 1 failed
```

Restoring `ControllerOnly` mode returned the same regression to green:

```text
[PASS] testLpAndHolderComposedAccountingRejectsDirectInnerBypasses
1 passed; 0 failed
```

The final zero-slope accounting regression was also observed RED before its O(1) capped-index settlement was added:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-test testOneTimesIncomingAfterFundingCannotClaimEarlierRewards
[FAIL: new 1x holder received retroactive funding] testOneTimesIncomingAfterFundingCannotClaimEarlierRewards
0 passed; 1 failed
```

### GREEN Evidence

Focused reward-template behavior:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/templates/RewardTemplates.t.sol'
RewardTemplateDeploymentTest: 7 passed; 0 failed
RewardVaultBehaviorTest: 24 passed; 0 failed
Focused total: 31 passed; 0 failed
```

Generic base reward accounting:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/vaults/RewardVault.t.sol'
RewardVaultTest: 7 passed; 0 failed
```

Reward accounting and review-regression fuzzing:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/fuzz/RewardAccounting.fuzz.t.sol' --fuzz-runs 512
RewardAccountingFuzzTest: 7 passed; 0 failed
512 runs per fuzz property
```

Full repository suite:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force
Ran 16 test suites: 130 tests passed, 0 failed, 0 skipped
```

Formatting, lint, and size checks:

```text
pnpm dlx @foundry-rs/forge@1.7.1 fmt --check
pnpm dlx @foundry-rs/forge@1.7.1 lint --force
pnpm dlx @foundry-rs/forge@1.7.1 build --force --sizes
All exited 0. Lint/build report only the pre-existing MintVault test-helper selfdestruct warning.
TimeWeightedRewardVault runtime: 11,778 B
RewardVault runtime: 4,149 B
LpRewardVault runtime: 3,883 B
HolderDeadRewardVault runtime: 6,050 B
```

### Files Changed

- `contracts/src/vaults/RewardVault.sol`
- `contracts/src/vaults/LpRewardVault.sol`
- `contracts/src/vaults/HolderDeadRewardVault.sol`
- `contracts/src/vaults/TimeWeightedRewardVault.sol`
- `contracts/test/vaults/RewardVault.t.sol`
- `contracts/test/templates/RewardTemplates.t.sol`
- `contracts/test/fuzz/RewardAccounting.fuzz.t.sol`
- `.superpowers/sdd/2026-08-29-70x-corla-platform-implementation/task-7-report.md`

### Remaining Boundary

Exact newest-first outgoing consumption is necessarily proportional to the number of distinct receipt lots actually consumed. Inbound receipts are independent of the recipient's history, and claims are capped at 256 tranche settlements per call, so third-party dust cannot recreate the former fixed-cap receipt/buy/claim denial. A holder intentionally transferring an amount that crosses an extremely large number of exact lots may need to split that outgoing transfer; avoiding that work would require changing the economic interface to opt-in custody/staking or approximating receipt ages, neither of which is done here.

## Fix Round 2

### Status

PASS. The remaining tranche-history gas finding is fixed without approximating receipt ages or rewards.

- Time-weighted account tranches are now an indexed mapping-backed deque. Incoming receipts append or merge the newest same-timestamp lot without visiting recipient history. Fully consumed tail lots and batched expired head lots are deleted, so historical indices never become future scan work.
- Each account caches tracked balance, current weight numerator, active slope, and its last weight checkpoint. The balance and weight reads used by transfer callbacks are O(1) after the bounded global checkpoint.
- Outgoing transfers settle and remove only the newest distinct lots actually consumed. Unconsumed lots keep their exact receipt timestamp and per-lot paid reward/time indices; there is no eager sender-wide settlement.
- Expiry work uses an indexed `(account, expiry)` min-heap. Each processed node advances the account weight exactly to expiry, removes that account's slope, and snapshots the shared global reward/time indices. Empty nodes are removed immediately.
- Claims compact and settle at most 256 lots per call. Expired prefixes move into the exact capped aggregate, active lots retain per-lot debt, and scaled fractional remainder remains claimable in later batches.

This round supersedes Fix Round 1's statement that transfer-side behavior was sufficient merely because recipient insertion was history-independent. Sender-wide settlement and linear balance/weight getters have been removed from the transfer path.

### RED Evidence

The two Round 2 regressions were added first and run against the prior implementation:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-test 'testTimeWeightedNewestLotOutgoingGasIsIndependentOfThousandLotHistory|testTimeWeightedExpiredHistoryCompactsAcrossExactClaimBatches'
```

The prior code failed both tests:

```text
[FAIL: thousand-lot newest outgoing exceeded bounded gas] testTimeWeightedNewestLotOutgoingGasIsIndependentOfThousandLotHistory
[FAIL: expired claim batches retained historical tranches] testTimeWeightedExpiredHistoryCompactsAcrossExactClaimBatches
0 passed; 2 failed
```

The first regression constructs 10-lot and 1,000-lot histories, then consumes a single newest lot. It requires the 1,000-lot transfer to use less than 1,000,000 gas and less than twice the small-history transfer gas. The second creates 600 distinct receipts, funds on both sides of expiry, processes three global checkpoint batches, and requires three claim batches to preserve exact pending rewards and funding conservation while deleting all expired tranche storage.

### GREEN Evidence

The exact Round 2 regressions now pass:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-test 'testTimeWeightedNewestLotOutgoingGasIsIndependentOfThousandLotHistory|testTimeWeightedExpiredHistoryCompactsAcrossExactClaimBatches'
[PASS] testTimeWeightedExpiredHistoryCompactsAcrossExactClaimBatches() (gas: 172465860)
[PASS] testTimeWeightedNewestLotOutgoingGasIsIndependentOfThousandLotHistory() (gas: 225552129)
2 passed; 0 failed
```

The reported Forge gas includes construction of the 600/1,000-lot histories. The newest-lot callback itself is separately bounded by the in-test `< 1,000,000` absolute and `< 2x` history-ratio assertions.

Focused reward templates and behavior:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/templates/RewardTemplates.t.sol'
RewardTemplateDeploymentTest: 7 passed; 0 failed
RewardVaultBehaviorTest: 26 passed; 0 failed
Focused total: 33 passed; 0 failed
```

Generic base reward accounting:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/vaults/RewardVault.t.sol'
RewardVaultTest: 7 passed; 0 failed
```

Reward accounting and review-regression fuzzing:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force --match-path 'test/fuzz/RewardAccounting.fuzz.t.sol' --fuzz-runs 512
RewardAccountingFuzzTest: 7 passed; 0 failed
512 runs per fuzz property
```

Full repository suite:

```text
pnpm dlx @foundry-rs/forge@1.7.1 test --force
Ran 16 test suites: 132 tests passed, 0 failed, 0 skipped
```

Formatting, lint, and deployable size:

```text
pnpm dlx @foundry-rs/forge@1.7.1 fmt --check
pnpm dlx @foundry-rs/forge@1.7.1 lint --force
pnpm dlx @foundry-rs/forge@1.7.1 build --force --sizes
All exited 0.
TimeWeightedRewardVault runtime: 13,282 B (11,294 B EIP-170 margin)
```

Lint reports the intentional timestamp comparison/cast in the time-weighted heap plus the pre-existing MintVault test-helper `selfdestruct` warning. Compilation and deployable-size checks succeed.

### Files Changed

- `contracts/src/vaults/TimeWeightedRewardVault.sol`
- `contracts/test/templates/RewardTemplates.t.sol`
- `.superpowers/sdd/2026-08-29-70x-corla-platform-implementation/task-7-report.md`

### Remaining Boundary

Exact newest-first transfer accounting still must touch every distinct newest lot actually crossed by the transfer amount. A one-lot outgoing is history-independent even after 1,000 adversarial receipts, but a transfer intentionally consuming 1,000 distinct lots performs 1,000 exact removals. Eliminating that irreducible work would require changing the economic interface or approximating ages, both outside the approved semantics. Exact `pendingRewards(account)` is also a potentially linear off-chain view; state-changing claims remain capped at 256 lots and transfer callbacks do not call it.
