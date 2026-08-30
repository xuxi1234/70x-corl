// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchFactory} from "../../src/core/LaunchFactory.sol";
import {LaunchTypes} from "../../src/core/LaunchTypes.sol";
import {PlatformConfig} from "../../src/core/PlatformConfig.sol";
import {TemplateRegistry} from "../../src/core/TemplateRegistry.sol";
import {ITemplate} from "../../src/interfaces/ITemplate.sol";
import {LpRewardsTemplateV1} from "../../src/templates/LpRewardsTemplateV1.sol";
import {HolderDeadTemplateV1} from "../../src/templates/HolderDeadTemplateV1.sol";
import {TimeWeightedTemplateV1} from "../../src/templates/TimeWeightedTemplateV1.sol";
import {LaunchToken} from "../../src/tokens/LaunchToken.sol";
import {MintVault, ILaunchExecutor} from "../../src/vaults/MintVault.sol";
import {HolderDeadRewardVault} from "../../src/vaults/HolderDeadRewardVault.sol";
import {LpRewardVault} from "../../src/vaults/LpRewardVault.sol";
import {TimeWeightedRewardVault} from "../../src/vaults/TimeWeightedRewardVault.sol";

interface Vm {
    function computeCreateAddress(address deployer, uint256 nonce) external returns (address);
    function deal(address account, uint256 newBalance) external;
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address sender) external;
    function warp(uint256 newTimestamp) external;
}

interface ITransferObserver {
    function onTokenTransfer(address from, address to, uint256 amount) external;
}

interface ILiquidityObserver {
    function onLiquidityTokenSet(address liquidityToken) external;
}

contract RewardAsset {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[owner][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[owner][msg.sender] = allowed - amount;
        _transfer(owner, recipient, amount);
        return true;
    }

    function _transfer(address owner, address recipient, uint256 amount) private {
        require(balanceOf[owner] >= amount, "balance");
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount;
    }
}

contract ObservedToken is RewardAsset {
    address public observer;

    function setObserver(address observer_) external {
        require(observer == address(0), "observer set");
        observer = observer_;
    }

    function observedTransfer(address owner, address recipient, uint256 amount) external {
        _observedTransfer(owner, recipient, amount);
    }

    function _observedTransfer(address owner, address recipient, uint256 amount) private {
        require(balanceOf[owner] >= amount, "balance");
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount;
        ITransferObserver(observer).onTokenTransfer(owner, recipient, amount);
    }
}

contract RewardLaunchExecutor is ILaunchExecutor {
    function execute(address, uint256, uint256, uint256) external payable returns (ExecutionResult memory) {
        revert("not exercised");
    }
}

contract RewardPair {}

contract RewardPairExecutor is ILaunchExecutor {
    RewardPair public immutable pair = new RewardPair();

    function execute(address token, uint256 tokenAmount, uint256, uint256)
        external
        payable
        returns (ExecutionResult memory result)
    {
        require(RewardAsset(token).transferFrom(msg.sender, address(pair), tokenAmount), "pair transfer failed");
        result = ExecutionResult({
            magic: bytes4(keccak256("MINT_VAULT_EXECUTION_SUCCESS")),
            liquidityToken: address(pair),
            liquidityAmount: 1,
            nativeSpent: msg.value,
            tokenSpent: tokenAmount
        });
    }
}

contract RewardTransferController {
    address public liquidityToken;
    uint8 public state;

    function notifyTransfer(address observer, address from, address to, uint256 amount) external {
        ITransferObserver(observer).onTokenTransfer(from, to, amount);
    }

    function activateLiquidityToken(address observer, address liquidityToken_) external {
        liquidityToken = liquidityToken_;
        ILiquidityObserver(observer).onLiquidityTokenSet(liquidityToken_);
    }

    function setState(uint8 state_) external {
        state = state_;
    }
}

contract ReplacementLpToken is RewardAsset {
    function replacementMarker() external pure returns (bytes32) {
        return keccak256("replacement");
    }
}

contract CanonicalPair is RewardAsset {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract CanonicalFactory {
    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "pair exists");
        bytes32 salt = keccak256(abi.encodePacked(tokenA, tokenB));
        pair = address(new CanonicalPair{salt: salt}(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }

    function predictPair(address tokenA, address tokenB) external view returns (address predicted) {
        bytes32 salt = keccak256(abi.encodePacked(tokenA, tokenB));
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(CanonicalPair).creationCode, abi.encode(tokenA, tokenB)));
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, initCodeHash)))));
    }
}

contract LpLaunchExecutor is ILaunchExecutor {
    address public immutable factory;
    address public immutable wbnb;

    constructor(address factory_, address wbnb_) {
        factory = factory_;
        wbnb = wbnb_;
    }

    function execute(address, uint256, uint256, uint256) external payable returns (ExecutionResult memory) {
        revert("not exercised");
    }
}

contract MutableLpLaunchExecutor is ILaunchExecutor {
    address public factory;
    address public wbnb;

    constructor(address factory_, address wbnb_) {
        factory = factory_;
        wbnb = wbnb_;
    }

    function setRoute(address factory_, address wbnb_) external {
        factory = factory_;
        wbnb = wbnb_;
    }

    function execute(address, uint256, uint256, uint256) external payable returns (ExecutionResult memory) {
        revert("not exercised");
    }
}

contract RewardVaultBehaviorTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    RewardAsset private reward;

    function setUp() public {
        reward = new RewardAsset();
    }

    function testTimeWeightedTrancheAgeGrowsLinearlyAndCapsAtThreeTimes() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 10 days);
        project.setObserver(address(vault));

        VM.warp(block.timestamp + 5 days);
        require(vault.weightedBalanceOf(ALICE) == 200 ether, "half-duration multiplier not 2x");

        VM.warp(block.timestamp + 20 days);
        vault.checkpoint(8);
        require(vault.weightedBalanceOf(ALICE) == 300 ether, "weight exceeded or missed 3x cap");
    }

    function testTimeWeightedOutgoingTransferConsumesNewestTrancheFirst() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 150 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 10 days);
        project.setObserver(address(vault));
        project.observedTransfer(ALICE, BOB, 50 ether);

        VM.warp(block.timestamp + 4 days);
        project.observedTransfer(BOB, ALICE, 50 ether);
        VM.warp(block.timestamp + 1 days);
        project.observedTransfer(ALICE, BOB, 60 ether);

        require(vault.trancheCount(ALICE) == 1, "newest tranche not removed first");
        (uint256 remaining, uint256 receivedAt,) = vault.trancheAt(ALICE, 0);
        require(remaining == 90 ether, "wrong tranche amount remained");
        // forge-lint: disable-next-line(block-timestamp)
        require(receivedAt + 5 days == block.timestamp, "old tranche age was rewritten");
        require(vault.weightedBalanceOf(ALICE) == 180 ether, "remaining old tranche lost age");
    }

    function testTimeWeightedFundingUsesExactAgeAdjustedWeights() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 10 days);
        project.setObserver(address(vault));
        project.observedTransfer(ALICE, BOB, 50 ether);
        VM.warp(block.timestamp + 5 days);
        project.observedTransfer(BOB, ALICE, 25 ether);

        VM.warp(block.timestamp + 5 days);
        _fundTime(vault, 275 ether);

        require(vault.pendingRewards(ALICE) == 200 ether - 1, "aged and fresh tranche weighting mismatch");
        require(vault.pendingRewards(BOB) == 75 ether - 1, "counterparty time weighting mismatch");
    }

    function testTimeWeightedConfigurationRejectsOverThreeTimesAndUnboundedDuration() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 1 ether);

        VM.expectRevert(
            abi.encodeWithSelector(TimeWeightedRewardVault.InvalidMaximumMultiplier.selector, uint16(30_001))
        );
        new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_001, 1 days);

        VM.expectRevert(abi.encodeWithSelector(TimeWeightedRewardVault.InvalidGrowthDuration.selector, uint32(31 days)));
        new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 31 days);
    }

    function testTimeWeightedExpiryCheckpointIsBoundedAndPreservesExactCappedWeight() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 1 days);
        project.setObserver(address(vault));

        for (uint256 index; index < 70; ++index) {
            VM.warp(block.timestamp + 1);
            // forge-lint: disable-next-line(unsafe-typecast)
            project.observedTransfer(ALICE, address(uint160(0x1000 + index)), 1 ether);
        }
        VM.warp(block.timestamp + 1 days);

        require(!vault.checkpoint(1), "one checkpoint unexpectedly processed every expiry");
        require(!vault.checkpoint(64), "bounded checkpoint ignored its expiry limit");
        require(vault.checkpoint(64), "remaining expiries did not become catchable");
        require(vault.totalWeight() == 300 ether, "batched expiry processing changed exact aggregate weight");
    }

    function testTimeWeightedMoreThanSixtyFourDustReceiptsCannotBlockLegitimateReceiptOrClaim() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 30 days);
        project.setObserver(address(vault));

        project.observedTransfer(ALICE, BOB, 1);
        project.observedTransfer(ALICE, BOB, 1);
        require(vault.trancheCount(BOB) == 1, "same-timestamp receipts did not merge");
        for (uint256 index; index < 300; ++index) {
            VM.warp(block.timestamp + 1);
            project.observedTransfer(ALICE, BOB, 1);
        }
        require(vault.trancheCount(BOB) == 301, "distinct dust ages were not retained exactly");

        _fundTime(vault, 100 ether);
        VM.warp(block.timestamp + 1);
        uint256 gasBeforeReceipt = gasleft();
        project.observedTransfer(ALICE, BOB, 10 ether);
        uint256 receiptGas = gasBeforeReceipt - gasleft();
        require(receiptGas < 1_000_000, "dust history made legitimate receipt unbounded");
        require(project.balanceOf(BOB) == 10 ether + 302, "legitimate receipt failed after dust saturation");
        require(vault.trancheCount(BOB) == 302, "legitimate receipt lost its exact age");

        _fundTime(vault, 100 ether);
        uint256 bobPending = vault.pendingRewards(BOB);
        VM.prank(BOB);
        uint256 firstClaim = vault.claimRewards();
        VM.prank(BOB);
        uint256 secondClaim = vault.claimRewards();
        require(firstClaim + secondClaim == bobPending, "batched saturated claims changed exact rewards");
        require(
            reward.balanceOf(address(vault)) + vault.totalClaimed() == vault.totalFunded(),
            "dust saturation broke reward conservation"
        );

        project.observedTransfer(BOB, ALICE, 5 ether);
        (uint256 newestRemaining,,) = vault.trancheAt(BOB, 301);
        require(newestRemaining == 5 ether, "post-saturation outgoing did not consume newest receipt first");
    }

    function testTimeWeightedNewestLotOutgoingGasIsIndependentOfThousandLotHistory() public {
        ObservedToken smallProject = new ObservedToken();
        smallProject.mint(ALICE, 100 ether);
        TimeWeightedRewardVault smallVault = new TimeWeightedRewardVault(
            address(reward), address(smallProject), address(smallProject), ALICE, 30_000, 30 days
        );
        smallProject.setObserver(address(smallVault));
        for (uint256 index; index < 10; ++index) {
            VM.warp(block.timestamp + 1);
            smallProject.observedTransfer(ALICE, BOB, 1);
        }
        VM.warp(block.timestamp + 1);
        smallProject.observedTransfer(ALICE, BOB, 1 ether);
        uint256 smallGasBefore = gasleft();
        smallProject.observedTransfer(BOB, address(0xCA901), 1 ether);
        uint256 smallGas = smallGasBefore - gasleft();

        ObservedToken largeProject = new ObservedToken();
        largeProject.mint(ALICE, 100 ether);
        TimeWeightedRewardVault largeVault = new TimeWeightedRewardVault(
            address(reward), address(largeProject), address(largeProject), ALICE, 30_000, 30 days
        );
        largeProject.setObserver(address(largeVault));
        for (uint256 index; index < 1_000; ++index) {
            VM.warp(block.timestamp + 1);
            largeProject.observedTransfer(ALICE, BOB, 1);
        }
        VM.warp(block.timestamp + 1);
        largeProject.observedTransfer(ALICE, BOB, 1 ether);
        uint256 largeGasBefore = gasleft();
        largeProject.observedTransfer(BOB, address(0xCA901), 1 ether);
        uint256 largeGas = largeGasBefore - gasleft();

        require(largeGas < 1_000_000, "thousand-lot newest outgoing exceeded bounded gas");
        require(largeGas < smallGas * 2, "newest outgoing gas scaled with historical lots");
        require(largeVault.trancheCount(BOB) == 1_000, "newest lot removal changed older exact ages");
        require(largeVault.trackedBalanceOf(BOB) == 1_000, "newest lot removal changed older balance");
    }

    function testTimeWeightedExpiredHistoryCompactsAcrossExactClaimBatches() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 1 days);
        project.setObserver(address(vault));
        for (uint256 index; index < 600; ++index) {
            VM.warp(block.timestamp + 1);
            project.observedTransfer(ALICE, BOB, 1);
        }
        _fundTime(vault, 100 ether);

        VM.warp(block.timestamp + 1 days);
        require(!vault.checkpoint(256), "first expired batch processed all history");
        require(!vault.checkpoint(256), "second expired batch processed all history");
        require(vault.checkpoint(256), "final expired batch did not catch up");
        _fundTime(vault, 100 ether);
        uint256 pendingBefore = vault.pendingRewards(BOB);

        VM.prank(BOB);
        uint256 firstClaim = vault.claimRewards();
        VM.prank(BOB);
        uint256 secondClaim = vault.claimRewards();
        VM.prank(BOB);
        uint256 thirdClaim = vault.claimRewards();

        require(firstClaim + secondClaim + thirdClaim == pendingBefore, "expired batches changed exact accrual");
        require(vault.trancheCount(BOB) == 0, "expired claim batches retained historical tranches");
        require(vault.trackedBalanceOf(BOB) == 600, "expired compaction changed tracked balance");
        require(
            reward.balanceOf(address(vault)) + vault.totalClaimed() == vault.totalFunded(),
            "expired batch claims broke funding conservation"
        );
    }

    function testOneTimesReceiptsShareOneScheduledExpiryBucket() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 10_000, 1 days);
        project.setObserver(address(vault));

        for (uint256 index; index < 70; ++index) {
            // forge-lint: disable-next-line(unsafe-typecast)
            project.observedTransfer(ALICE, address(uint160(0x2000 + index)), 1 ether);
        }
        require(vault.expiryCount() == 0, "zero-slope receipts created economically empty expiry work");
    }

    function testOneTimesIncomingAfterFundingCannotClaimEarlierRewards() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 10_000, 1 days);
        project.setObserver(address(vault));

        _fundTime(vault, 100 ether);
        project.observedTransfer(ALICE, BOB, 50 ether);
        require(vault.pendingRewards(ALICE) >= 100 ether - 1, "existing 1x holder lost prior funding");
        require(vault.pendingRewards(BOB) == 0, "new 1x holder received retroactive funding");

        _fundTime(vault, 100 ether);
        require(vault.pendingRewards(ALICE) >= 150 ether - 2, "existing 1x holder second funding mismatch");
        require(vault.pendingRewards(BOB) >= 50 ether - 1, "new 1x holder current funding mismatch");
    }

    function testTimeWeightedPingPongRemovesEmptyExpiryBucketsImmediately() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 1);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 1 days);
        project.setObserver(address(vault));

        for (uint256 index; index < 70; ++index) {
            VM.warp(block.timestamp + 1);
            project.observedTransfer(ALICE, BOB, 1);
            project.observedTransfer(BOB, ALICE, 1);
        }

        require(vault.expiryCount() == 1, "consumed tranches left empty expiry buckets");
        VM.warp(block.timestamp + 1 days);
        project.observedTransfer(ALICE, BOB, 1);
        require(vault.trackedBalanceOf(BOB) == 1, "empty expiry work halted a live transfer");
    }

    function testTimeWeightedExpiryHeapRemovesMiddleBucketAndProcessesInOrder() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 3 ether);
        uint256 startedAt = block.timestamp;
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 1 days);
        project.setObserver(address(vault));

        VM.warp(startedAt + 1);
        project.observedTransfer(ALICE, BOB, 1 ether);
        VM.warp(startedAt + 2);
        project.observedTransfer(ALICE, address(0xCA901), 1 ether);
        VM.warp(startedAt + 3);
        project.observedTransfer(BOB, ALICE, 1 ether);

        require(vault.expiryCount() == 3, "removed middle expiry remained scheduled");
        require(vault.nextExpiry() == startedAt + 1 days, "heap root is not the earliest active expiry");
        require(vault.activeSlope() == 3 ether * 20_000, "slope update lost active tranche weight");

        VM.warp(startedAt + 1 days);
        require(vault.checkpoint(1), "one due expiry did not leave the heap current");
        require(vault.nextExpiry() == startedAt + 1 days + 2, "removed middle expiry blocked ordered processing");
    }

    function testTimeWeightedExpiredNewestOutgoingAndRecipientReceiptAreHistoryIndependent() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 128 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 1 days);
        project.setObserver(address(vault));

        for (uint256 index; index < 64; ++index) {
            if (index != 0) VM.warp(block.timestamp + 1);
            project.observedTransfer(ALICE, BOB, 1 ether);
            project.observedTransfer(ALICE, address(0xCA901), 1 ether);
        }
        require(vault.trancheCount(BOB) == 64, "sender max-tranche setup mismatch");
        require(vault.trancheCount(address(0xCA901)) == 64, "recipient max-tranche setup mismatch");

        VM.warp(block.timestamp + 1 days);
        require(vault.checkpoint(256), "max-tranche expiries did not checkpoint");
        uint256 gasBefore = gasleft();
        project.observedTransfer(BOB, address(0xCA901), 1 ether);
        uint256 gasUsed = gasBefore - gasleft();

        require(gasUsed < 5_000_000, "expired newest outgoing scanned historical tranches");
        require(vault.trancheCount(BOB) == 63, "expired outgoing changed unconsumed exact ages");
        require(vault.trackedBalanceOf(BOB) == 63 ether, "expired outgoing changed unconsumed balance");
        require(vault.trancheCount(address(0xCA901)) == 65, "recipient receipt rewrote exact expired ages");
        require(vault.trackedBalanceOf(address(0xCA901)) == 65 ether, "recipient balance changed during compaction");
    }

    function testTimeWeightedFundingAcrossCapExpiriesPreservesEachFundingSnapshot() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 1 days);
        project.setObserver(address(vault));
        project.observedTransfer(ALICE, BOB, 50 ether);

        VM.warp(block.timestamp + 12 hours);
        project.observedTransfer(BOB, address(0xCA901), 25 ether);
        _fundTime(vault, 175 ether);

        VM.warp(block.timestamp + 12 hours);
        _fundTime(vault, 275 ether);

        uint256 alicePending = vault.pendingRewards(ALICE);
        uint256 bobPending = vault.pendingRewards(BOB);
        uint256 carolPending = vault.pendingRewards(address(0xCA901));
        require(alicePending >= 250 ether - 2 && alicePending <= 250 ether, "alice cap snapshot mismatch");
        require(bobPending >= 125 ether - 2 && bobPending <= 125 ether, "bob cap snapshot mismatch");
        require(carolPending >= 75 ether - 2 && carolPending <= 75 ether, "carol cap snapshot mismatch");
        require(alicePending + bobPending + carolPending <= vault.totalFunded(), "cap snapshots overallocated");
    }

    function testTimeWeightedPairBecomesAtomicallyExcludedWithoutDilutiveWeight() public {
        RewardAsset project = new RewardAsset();
        RewardTransferController launch = new RewardTransferController();
        RewardPair pair = new RewardPair();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(launch), ALICE, 30_000, 1 days);

        VM.prank(ALICE);
        require(project.transfer(address(pair), 40 ether), "project transfer failed");
        launch.notifyTransfer(address(vault), ALICE, address(pair), 40 ether);
        require(vault.weightedBalanceOf(address(pair)) == 40 ether, "pre-discovery pair setup mismatch");

        launch.activateLiquidityToken(address(vault), address(pair));
        require(vault.weightedBalanceOf(address(pair)) == 0, "finalized pair retained time weight");
        require(vault.totalWeight() == 60 ether, "pair exclusion diluted live time weight");
        _fundTime(vault, 60 ether);
        require(vault.pendingRewards(ALICE) == 60 ether - 1, "excluded pair stranded live-holder funding");
    }

    function testLpWeightTracksExplicitSyncAndMinimumEligibility() public {
        RewardAsset lp = new RewardAsset();
        lp.mint(ALICE, 9 ether);
        LpRewardVault vault = new LpRewardVault(address(reward), address(lp), 10 ether);

        vault.syncWeight(ALICE);
        require(vault.weightOf(ALICE) == 0, "below-minimum LP became eligible");

        lp.mint(ALICE, 1 ether);
        vault.syncWeight(ALICE);
        require(vault.weightOf(ALICE) == 10 ether, "eligible LP balance not synchronized");

        VM.prank(ALICE);
        require(lp.transfer(BOB, 5 ether), "LP transfer failed");
        vault.syncWeight(ALICE);
        vault.syncWeight(BOB);
        require(vault.weightOf(ALICE) == 0, "sender stayed eligible after LP transfer");
        require(vault.weightOf(BOB) == 0, "sub-minimum recipient became eligible");
    }

    function testLpAndHolderComposedAccountingRejectsDirectInnerBypasses() public {
        RewardAsset lp = new RewardAsset();
        lp.mint(ALICE, 10 ether);
        LpRewardVault lpVault = new LpRewardVault(address(reward), address(lp), 1 ether);
        lpVault.syncWeight(ALICE);
        _fundLp(lpVault, 10 ether);

        address lpAccounting = address(lpVault.rewardAccounting());
        VM.prank(ALICE);
        (bool lpClaimed,) = lpAccounting.call(abi.encodeWithSignature("claimRewards()"));
        require(!lpClaimed, "LP staker bypassed wrapper claim semantics");

        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        HolderDeadRewardVault holderVault =
            new HolderDeadRewardVault(address(reward), address(project), address(project), ALICE, 7_000, 3_000);
        project.setObserver(address(holderVault));
        reward.mint(address(this), 20 ether);
        reward.approve(address(holderVault.rewardAccounting()), 10 ether);
        (bool fundedInner,) =
            address(holderVault.rewardAccounting()).call(abi.encodeWithSignature("fundRewards(uint256)", 10 ether));
        require(!fundedInner, "holder accounting accepted funding that bypassed dead split");

        _fundHolderDead(holderVault, 10 ether);
        address holderAccounting = address(holderVault.rewardAccounting());
        VM.prank(ALICE);
        (bool holderClaimed,) = holderAccounting.call(abi.encodeWithSignature("claimRewards()"));
        require(!holderClaimed, "holder bypassed wrapper claim semantics");
    }

    function testCompanionProjectTokenBalancesHaveZeroWeightAndDoNotStrandRewards() public {
        ObservedToken timeProject = new ObservedToken();
        timeProject.mint(ALICE, 100 ether);
        TimeWeightedRewardVault timeVault = new TimeWeightedRewardVault(
            address(reward), address(timeProject), address(timeProject), ALICE, 30_000, 1 days
        );
        timeProject.setObserver(address(timeVault));
        timeProject.observedTransfer(ALICE, address(timeVault), 40 ether);

        require(timeVault.weightedBalanceOf(address(timeVault)) == 0, "time companion became live weight");
        require(timeVault.totalWeight() == 60 ether, "time companion balance diluted live weight");
        _fundTime(timeVault, 60 ether);
        require(timeVault.pendingRewards(ALICE) == 60 ether - 1, "time companion stranded live allocation");

        ObservedToken holderProject = new ObservedToken();
        holderProject.mint(ALICE, 100 ether);
        HolderDeadRewardVault holderVault = new HolderDeadRewardVault(
            address(reward), address(holderProject), address(holderProject), ALICE, 10_000, 0
        );
        holderProject.setObserver(address(holderVault));
        holderProject.observedTransfer(ALICE, address(holderVault), 20 ether);
        holderProject.observedTransfer(ALICE, address(holderVault.rewardAccounting()), 20 ether);

        require(holderVault.weightOf(address(holderVault)) == 0, "holder companion became live weight");
        require(
            holderVault.weightOf(address(holderVault.rewardAccounting())) == 0,
            "holder inner accounting became live weight"
        );
        require(holderVault.totalWeight() == 60 ether, "holder companion balances diluted live weight");
        _fundHolderDead(holderVault, 60 ether);
        require(holderVault.pendingRewards(ALICE) == 60 ether, "holder companion stranded live allocation");
    }

    function testLpSyncExcludesDeadAndRewardVaultBalances() public {
        RewardAsset lp = new RewardAsset();
        LpRewardVault vault = new LpRewardVault(address(reward), address(lp), 1 ether);
        lp.mint(DEAD, 100 ether);
        lp.mint(address(vault), 100 ether);
        lp.mint(address(vault.rewardAccounting()), 100 ether);

        vault.syncWeight(DEAD);
        vault.syncWeight(address(vault));
        vault.syncWeight(address(vault.rewardAccounting()));

        require(vault.totalWeight() == 0, "unclaimable LP balance diluted live providers");
    }

    function testLpTokenCannotAlsoBeTheRewardAsset() public {
        RewardAsset lp = new RewardAsset();

        VM.expectRevert(abi.encodeWithSelector(LpRewardVault.SelfReferentialRewardToken.selector, address(lp)));
        new LpRewardVault(address(lp), address(lp), 1 ether);
    }

    function testLpStaleTransferAccruesAtLastSynchronizedBalanceUntilResync() public {
        RewardAsset lp = new RewardAsset();
        lp.mint(ALICE, 10 ether);
        LpRewardVault vault = new LpRewardVault(address(reward), address(lp), 1 ether);
        vault.syncWeight(ALICE);
        _fundLp(vault, 10 ether);

        VM.prank(ALICE);
        require(lp.transfer(BOB, 10 ether), "LP transfer failed");
        _fundLp(vault, 10 ether);

        require(vault.pendingRewards(ALICE) == 20 ether, "stale synchronized weight changed implicitly");
        vault.syncWeight(ALICE);
        require(vault.weightOf(ALICE) == 0, "resync did not remove transferred LP weight");
        require(vault.pendingRewards(ALICE) == 20 ether, "resync rewrote historical accrual");
        require(vault.lastSyncedBalance(ALICE) == 0, "sync balance not recorded");
        // forge-lint: disable-next-line(block-timestamp)
        require(vault.lastSyncedAt(ALICE) == block.timestamp, "sync timestamp not recorded");
    }

    function testLpClaimForcesCallerSyncBeforePayout() public {
        RewardAsset lp = new RewardAsset();
        lp.mint(ALICE, 10 ether);
        LpRewardVault vault = new LpRewardVault(address(reward), address(lp), 1 ether);
        vault.syncWeight(ALICE);
        _fundLp(vault, 10 ether);

        VM.prank(ALICE);
        require(lp.transfer(BOB, 10 ether), "LP transfer failed");
        VM.prank(ALICE);
        require(vault.claimRewards() == 10 ether, "LP claim mismatch");

        require(vault.weightOf(ALICE) == 0, "claim did not force sync");
        require(reward.balanceOf(ALICE) == 10 ether, "claim recipient mismatch");
    }

    function testLpSyncRejectsCanonicalTokenRuntimeReplacement() public {
        RewardAsset lp = new RewardAsset();
        LpRewardVault vault = new LpRewardVault(address(reward), address(lp), 1 ether);
        ReplacementLpToken replacement = new ReplacementLpToken();
        bytes32 expectedCodehash = address(lp).codehash;
        bytes32 replacementCodehash = address(replacement).codehash;
        VM.etch(address(lp), address(replacement).code);

        VM.expectRevert(
            abi.encodeWithSelector(
                LpRewardVault.UnexpectedLpTokenCodehash.selector, expectedCodehash, replacementCodehash
            )
        );
        vault.syncWeight(ALICE);
    }

    function testHolderDeadFundingConservesSplitAndDeadShareCannotBeClaimed() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        HolderDeadRewardVault vault =
            new HolderDeadRewardVault(address(reward), address(project), address(project), ALICE, 7_000, 3_000);
        project.setObserver(address(vault));
        project.observedTransfer(ALICE, BOB, 40 ether);
        _fundHolderDead(vault, 100 ether);

        require(reward.balanceOf(DEAD) == 30 ether, "dead share not transferred directly");
        require(vault.pendingRewards(ALICE) == 42 ether, "alice holder share mismatch");
        require(vault.pendingRewards(BOB) == 28 ether, "bob holder share mismatch");
        require(vault.totalFunded() == 100 ether, "funding total mismatch");
        require(vault.totalDeadDistributed() + vault.totalHolderFunded() == 100 ether, "split not conserved");

        VM.prank(DEAD);
        VM.expectRevert(abi.encodeWithSelector(HolderDeadRewardVault.NothingToClaim.selector));
        vault.claimRewards();
    }

    function testHolderTransfersUpdateWeightsWithoutEnumeratingHolders() public {
        ObservedToken project = new ObservedToken();
        project.mint(ALICE, 100 ether);
        HolderDeadRewardVault vault =
            new HolderDeadRewardVault(address(reward), address(project), address(project), ALICE, 10_000, 0);
        project.setObserver(address(vault));
        project.observedTransfer(ALICE, BOB, 25 ether);

        require(vault.weightOf(ALICE) == 75 ether, "sender holder weight stale");
        require(vault.weightOf(BOB) == 25 ether, "recipient holder weight stale");
        require(vault.totalWeight() == 100 ether, "holder weight not conserved");
    }

    function testHolderPairBecomesAtomicallyExcludedWithoutDilutiveWeight() public {
        RewardAsset project = new RewardAsset();
        RewardTransferController launch = new RewardTransferController();
        RewardPair pair = new RewardPair();
        project.mint(ALICE, 100 ether);
        HolderDeadRewardVault vault =
            new HolderDeadRewardVault(address(reward), address(project), address(launch), ALICE, 10_000, 0);

        VM.prank(ALICE);
        require(project.transfer(address(pair), 40 ether), "project transfer failed");
        launch.notifyTransfer(address(vault), ALICE, address(pair), 40 ether);
        require(vault.weightOf(address(pair)) == 40 ether, "pre-discovery pair setup mismatch");

        launch.activateLiquidityToken(address(vault), address(pair));
        require(vault.weightOf(address(pair)) == 0, "finalized pair retained holder weight");
        require(vault.totalWeight() == 60 ether, "pair exclusion diluted live holder weight");
        _fundHolderDead(vault, 60 ether);
        require(vault.pendingRewards(ALICE) == 60 ether, "excluded pair stranded holder funding");
    }

    function _fundTime(TimeWeightedRewardVault vault, uint256 amount) private {
        reward.mint(address(this), amount);
        reward.approve(address(vault), amount);
        vault.fundRewards(amount);
    }

    function _fundLp(LpRewardVault vault, uint256 amount) private {
        reward.mint(address(this), amount);
        reward.approve(address(vault), amount);
        vault.fundRewards(amount);
    }

    function _fundHolderDead(HolderDeadRewardVault vault, uint256 amount) private {
        reward.mint(address(this), amount);
        reward.approve(address(vault), amount);
        vault.fundRewards(amount);
    }
}

contract RewardTemplateDeploymentTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint96 private constant FEE = 0.005 ether;
    address private constant CREATOR = address(0xC0FFEE);
    address private constant REVENUE = address(0x7000);

    RewardAsset private reward;
    RewardLaunchExecutor private executor;
    PlatformConfig private platformConfig;
    TemplateRegistry private registry;
    LaunchFactory private factory;

    function setUp() public {
        reward = new RewardAsset();
        executor = new RewardLaunchExecutor();
        platformConfig = new PlatformConfig(address(this), REVENUE);
        registry = new TemplateRegistry(address(this));
        factory = new LaunchFactory(address(this), registry, platformConfig);
        VM.deal(CREATOR, 1 ether);
    }

    function testTimeWeightedTemplateIsFactoryCompatibleAndKeepsSupplyInMintVault() public {
        TimeWeightedTemplateV1 template = new TimeWeightedTemplateV1(address(factory), address(executor));
        registry.register(template.TEMPLATE_ID(), template.VERSION(), address(template), keccak256("time-v1"));
        TimeWeightedTemplateV1.TimeWeightedConfig memory rewards =
            TimeWeightedTemplateV1.TimeWeightedConfig({maxMultiplierBps: 25_000, growthDuration: 7 days});
        bytes memory templateConfig = abi.encode(_standardConfig(), rewards);

        VM.prank(CREATOR);
        (address tokenAddress, address mintVaultAddress) = factory.deploy{value: FEE}(
            template.TEMPLATE_ID(), template.VERSION(), abi.encode(_commonConfig()), templateConfig
        );

        MintVault mintVault = MintVault(payable(mintVaultAddress));
        address companion = template.rewardVaultOf(mintVaultAddress);
        require(address(mintVault.token()) == tokenAddress, "template token mismatch");
        require(LaunchToken(tokenAddress).balanceOf(mintVaultAddress) == 1_000_000 ether, "supply escaped mint vault");
        require(LaunchToken(tokenAddress).balanceOf(CREATOR) == 0, "creator received inventory");
        require(TimeWeightedRewardVault(companion).maxMultiplierBps() == 25_000, "specialized config missing");
        require(TimeWeightedRewardVault(companion).controller() == mintVaultAddress, "untrusted transfer controller");
        require(TimeWeightedRewardVault(companion).totalWeight() == 0, "pre-launch mint inventory became eligible");
    }

    function testHolderDeadTemplateRejectsNonCanonicalOrNonConservingSpecializedTuple() public {
        HolderDeadTemplateV1 template = new HolderDeadTemplateV1(address(factory), address(executor));
        HolderDeadTemplateV1.HolderDeadConfig memory rewards =
            HolderDeadTemplateV1.HolderDeadConfig({holderBps: 7_000, deadBps: 2_999});
        bytes memory invalid = abi.encode(_standardConfig(), rewards);

        VM.prank(address(factory));
        VM.expectRevert(abi.encodeWithSelector(HolderDeadTemplateV1.InvalidRewardSplit.selector, uint256(9_999)));
        template.deploy(CREATOR, abi.encode(_commonConfig()), invalid);

        rewards.deadBps = 3_000;
        bytes memory nonCanonical = bytes.concat(abi.encode(_standardConfig(), rewards), hex"00");
        VM.prank(address(factory));
        VM.expectRevert(abi.encodeWithSelector(HolderDeadTemplateV1.InvalidTemplateConfigEncoding.selector));
        template.deploy(CREATOR, abi.encode(_commonConfig()), nonCanonical);
    }

    function testHolderDeadTemplateDeploysMintCustodyAndDiscoverableCompanion() public {
        HolderDeadTemplateV1 template = new HolderDeadTemplateV1(address(factory), address(executor));
        registry.register(template.TEMPLATE_ID(), template.VERSION(), address(template), keccak256("holder-v1"));
        HolderDeadTemplateV1.HolderDeadConfig memory rewards =
            HolderDeadTemplateV1.HolderDeadConfig({holderBps: 7_000, deadBps: 3_000});

        VM.prank(CREATOR);
        (address tokenAddress, address mintVaultAddress) = factory.deploy{value: FEE}(
            template.TEMPLATE_ID(),
            template.VERSION(),
            abi.encode(_commonConfig()),
            abi.encode(_standardConfig(), rewards)
        );
        address companion = template.rewardVaultOf(mintVaultAddress);

        require(companion.code.length != 0, "holder companion not recorded");
        require(LaunchToken(tokenAddress).balanceOf(mintVaultAddress) == 1_000_000 ether, "holder supply escaped");
        require(HolderDeadRewardVault(companion).weightOf(mintVaultAddress) == 0, "mint inventory became eligible");
    }

    function testFinalizationAtomicallyExcludesPairThenClaimsCreateLiveWeight() public {
        RewardPairExecutor pairExecutor = new RewardPairExecutor();
        TimeWeightedTemplateV1 template = new TimeWeightedTemplateV1(address(factory), address(pairExecutor));
        registry.register(template.TEMPLATE_ID(), template.VERSION(), address(template), keccak256("time-pair-v1"));
        TimeWeightedTemplateV1.TimeWeightedConfig memory rewards =
            TimeWeightedTemplateV1.TimeWeightedConfig({maxMultiplierBps: 30_000, growthDuration: 1 days});
        VM.deal(CREATOR, 2 ether);

        VM.prank(CREATOR);
        (, address mintVaultAddress) = factory.deploy{value: FEE}(
            template.TEMPLATE_ID(),
            template.VERSION(),
            abi.encode(_commonConfig()),
            abi.encode(_standardConfig(), rewards)
        );
        MintVault mintVault = MintVault(payable(mintVaultAddress));
        TimeWeightedRewardVault companion = TimeWeightedRewardVault(template.rewardVaultOf(mintVaultAddress));
        VM.prank(CREATOR);
        mintVault.mint{value: 1 ether}(100);
        mintVault.finalize(MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp + 1 hours}));

        address pair = address(pairExecutor.pair());
        require(mintVault.liquidityToken() == pair, "pair not finalized");
        require(companion.weightedBalanceOf(pair) == 0, "finalized pair became reward eligible");
        require(companion.totalWeight() == 0, "unclaimed vault or pair inventory diluted rewards");

        VM.prank(CREATOR);
        mintVault.claim();
        require(companion.weightedBalanceOf(CREATOR) == 800_000 ether, "claimed holder weight missing");
        require(companion.totalWeight() == 800_000 ether, "non-holder inventory remained weighted");
    }

    function testLpTemplateCreatesAndPinsCanonicalProjectWbnbPair() public {
        CanonicalFactory pancakeFactory = new CanonicalFactory();
        RewardAsset wbnb = new RewardAsset();
        LpLaunchExecutor lpExecutor = new LpLaunchExecutor(address(pancakeFactory), address(wbnb));
        LpRewardsTemplateV1 template = new LpRewardsTemplateV1(address(this), address(lpExecutor));
        address predictedVault = VM.computeCreateAddress(address(template), 2);
        address predictedToken = VM.computeCreateAddress(predictedVault, 1);
        address predictedPair = pancakeFactory.predictPair(predictedToken, address(wbnb));
        LpRewardsTemplateV1.LpRewardsConfig memory rewards =
            LpRewardsTemplateV1.LpRewardsConfig({lpToken: predictedPair, minimumEligibleBalance: 1 ether});

        (address tokenAddress, address mintVaultAddress) =
            template.deploy(CREATOR, abi.encode(_commonConfig()), abi.encode(_standardConfig(), rewards));
        address companion = template.rewardVaultOf(mintVaultAddress);

        require(tokenAddress == predictedToken, "unexpected token deployment address");
        require(pancakeFactory.getPair(tokenAddress, address(wbnb)) == predictedPair, "canonical pair not created");
        require(address(LpRewardVault(companion).lpToken()) == predictedPair, "companion accepted another LP token");
        require(LaunchToken(tokenAddress).balanceOf(mintVaultAddress) == 1_000_000 ether, "LP template leaked supply");
    }

    function testLpTemplateRejectsExecutorWhosePinnedRouteChanges() public {
        CanonicalFactory firstFactory = new CanonicalFactory();
        CanonicalFactory secondFactory = new CanonicalFactory();
        RewardAsset firstWbnb = new RewardAsset();
        RewardAsset secondWbnb = new RewardAsset();
        MutableLpLaunchExecutor mutableExecutor = new MutableLpLaunchExecutor(address(firstFactory), address(firstWbnb));
        LpRewardsTemplateV1 template = new LpRewardsTemplateV1(address(this), address(mutableExecutor));
        mutableExecutor.setRoute(address(secondFactory), address(secondWbnb));
        LpRewardsTemplateV1.LpRewardsConfig memory rewards =
            LpRewardsTemplateV1.LpRewardsConfig({lpToken: address(0x1234), minimumEligibleBalance: 1 ether});

        VM.expectRevert(
            abi.encodeWithSelector(
                LpRewardsTemplateV1.UnexpectedExecutorRoute.selector,
                address(firstFactory),
                address(secondFactory),
                address(firstWbnb),
                address(secondWbnb)
            )
        );
        template.deploy(CREATOR, abi.encode(_commonConfig()), abi.encode(_standardConfig(), rewards));
    }

    function testTemplatesExposeImmutableVersionedIds() public {
        TimeWeightedTemplateV1 timeTemplate = new TimeWeightedTemplateV1(address(this), address(executor));
        HolderDeadTemplateV1 holderTemplate = new HolderDeadTemplateV1(address(this), address(executor));
        CanonicalFactory pancakeFactory = new CanonicalFactory();
        RewardAsset wbnb = new RewardAsset();
        LpLaunchExecutor lpExecutor = new LpLaunchExecutor(address(pancakeFactory), address(wbnb));
        LpRewardsTemplateV1 lpTemplate = new LpRewardsTemplateV1(address(this), address(lpExecutor));

        require(timeTemplate.TEMPLATE_ID() == "TIME_WEIGHTED", "time ID mismatch");
        require(lpTemplate.TEMPLATE_ID() == "LP_REWARDS", "LP ID mismatch");
        require(holderTemplate.TEMPLATE_ID() == "HOLDER_DEAD", "holder/dead ID mismatch");
        require(
            timeTemplate.VERSION() == 1 && lpTemplate.VERSION() == 1 && holderTemplate.VERSION() == 1,
            "version mismatch"
        );
    }

    function _standardConfig() private pure returns (TimeWeightedTemplateV1.StandardConfig memory config) {
        config = TimeWeightedTemplateV1.StandardConfig({
            totalShares: 100, pricePerShare: 0.01 ether, claimTokenBps: 8_000, minimumLiquidityOutput: 1
        });
    }

    function _commonConfig() private view returns (LaunchTypes.CommonConfig memory config) {
        config.name = "Reward Launch";
        config.symbol = "RWD";
        config.supply = 1_000_000;
        config.buyTaxBps = 0;
        config.sellTaxBps = 0;
        config.receiver = CREATOR;
        config.rewardToken = address(reward);
        config.rewardThreshold = 1 ether;
        config.lpMode = 0;
        config.metadataHash = keccak256("reward-launch");
    }
}
