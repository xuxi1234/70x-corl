// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HolderDeadRewardVault} from "../../src/vaults/HolderDeadRewardVault.sol";
import {LpRewardVault} from "../../src/vaults/LpRewardVault.sol";
import {TimeWeightedRewardVault} from "../../src/vaults/TimeWeightedRewardVault.sol";

interface Vm {
    function prank(address sender) external;
    function warp(uint256 newTimestamp) external;
}

interface IRewardObserver {
    function onTokenTransfer(address from, address to, uint256 amount) external;
}

contract FuzzToken {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    address public observer;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function setObserver(address observer_) external {
        require(observer == address(0), "observer set");
        observer = observer_;
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

    function observedTransfer(address owner, address recipient, uint256 amount) external {
        _transfer(owner, recipient, amount);
    }

    function _transfer(address owner, address recipient, uint256 amount) private {
        require(balanceOf[owner] >= amount, "balance");
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount;
        if (observer != address(0)) IRewardObserver(observer).onTokenTransfer(owner, recipient, amount);
    }
}

contract RewardAccountingFuzzTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA901);
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function testFuzzTimeWeightedTransfersNeverCreateRewards(uint256 seed, uint8 steps) public {
        FuzzToken reward = new FuzzToken();
        FuzzToken project = new FuzzToken();
        project.mint(ALICE, 1_000 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 30 days);
        project.setObserver(address(vault));
        address[3] memory accounts = [ALICE, BOB, CAROL];
        uint256 iterations = uint256(steps % 24) + 1;

        for (uint256 index; index < iterations; ++index) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, index)));
            address from = accounts[entropy % 3];
            address to = accounts[(entropy / 3) % 3];
            if (from != to) {
                uint256 balance = project.balanceOf(from);
                uint256 amount = balance == 0 ? 0 : (entropy / 9) % (balance + 1);
                project.observedTransfer(from, to, amount);
            }
            VM.warp(block.timestamp + (entropy % 6 hours));
            uint256 funding = (entropy % 100 ether) + 1;
            reward.mint(address(this), funding);
            reward.approve(address(vault), funding);
            vault.fundRewards(funding);
            address claimant = accounts[(entropy / 27) % 3];
            if (vault.pendingRewards(claimant) != 0) {
                VM.prank(claimant);
                vault.claimRewards();
            }
        }

        uint256 pending = vault.pendingRewards(ALICE) + vault.pendingRewards(BOB) + vault.pendingRewards(CAROL);
        require(vault.totalClaimed() + pending <= vault.totalFunded(), "time rewards exceeded funding");
        require(reward.balanceOf(address(vault)) + vault.totalClaimed() == vault.totalFunded(), "time assets escaped");
    }

    function testFuzzHolderDeadTransfersConserveFunding(uint256 seed, uint8 steps, uint16 deadBpsSeed) public {
        FuzzToken reward = new FuzzToken();
        FuzzToken project = new FuzzToken();
        project.mint(ALICE, 1_000 ether);
        uint16 deadBps = deadBpsSeed % 10_001;
        HolderDeadRewardVault vault = new HolderDeadRewardVault(
            address(reward), address(project), address(project), ALICE, uint16(10_000 - deadBps), deadBps
        );
        project.setObserver(address(vault));
        address[3] memory accounts = [ALICE, BOB, CAROL];
        uint256 iterations = uint256(steps % 32) + 1;
        uint256 totalFunding;

        for (uint256 index; index < iterations; ++index) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, index)));
            address from = accounts[entropy % 3];
            address to = accounts[(entropy / 3) % 3];
            if (from != to) {
                uint256 balance = project.balanceOf(from);
                uint256 amount = balance == 0 ? 0 : (entropy / 9) % (balance + 1);
                project.observedTransfer(from, to, amount);
            }
            uint256 funding = (entropy % 100 ether) + 1;
            reward.mint(address(this), funding);
            reward.approve(address(vault), funding);
            vault.fundRewards(funding);
            totalFunding += funding;
            address claimant = accounts[(entropy / 27) % 3];
            if (vault.pendingRewards(claimant) != 0) {
                VM.prank(claimant);
                vault.claimRewards();
            }
        }

        uint256 pending = vault.pendingRewards(ALICE) + vault.pendingRewards(BOB) + vault.pendingRewards(CAROL);
        require(vault.totalClaimed() + pending + vault.totalDeadDistributed() <= totalFunding, "split overallocated");
        require(
            reward.balanceOf(address(vault.rewardAccounting())) + reward.balanceOf(DEAD) + vault.totalClaimed()
                == totalFunding,
            "holder/dead assets not conserved"
        );
    }

    function testFuzzLpSyncSequencesNeverOverallocate(uint256 seed, uint8 steps) public {
        FuzzToken reward = new FuzzToken();
        FuzzToken lp = new FuzzToken();
        lp.mint(ALICE, 1_000 ether);
        LpRewardVault vault = new LpRewardVault(address(reward), address(lp), 1 ether);
        address[3] memory accounts = [ALICE, BOB, CAROL];
        vault.syncWeight(ALICE);
        uint256 iterations = uint256(steps % 32) + 1;

        for (uint256 index; index < iterations; ++index) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, index)));
            address from = accounts[entropy % 3];
            address to = accounts[(entropy / 3) % 3];
            if (from != to) {
                uint256 balance = lp.balanceOf(from);
                uint256 amount = balance == 0 ? 0 : (entropy / 9) % (balance + 1);
                VM.prank(from);
                require(lp.transfer(to, amount), "LP transfer failed");
            }
            vault.syncWeight(accounts[(entropy / 27) % 3]);
            if (vault.totalWeight() != 0) {
                uint256 funding = (entropy % 100 ether) + 1;
                reward.mint(address(this), funding);
                reward.approve(address(vault), funding);
                vault.fundRewards(funding);
            }
            address claimant = accounts[(entropy / 81) % 3];
            if (vault.pendingRewards(claimant) != 0) {
                VM.prank(claimant);
                vault.claimRewards();
            }
        }

        uint256 pending = vault.pendingRewards(ALICE) + vault.pendingRewards(BOB) + vault.pendingRewards(CAROL);
        require(vault.totalClaimed() + pending <= vault.totalFunded(), "LP rewards exceeded funding");
        require(
            reward.balanceOf(address(vault.rewardAccounting())) + vault.totalClaimed() == vault.totalFunded(),
            "LP reward assets escaped"
        );
    }

    function testFuzzComposedInnerCallsCannotBypassWrapperSemantics(uint96 amountSeed) public {
        uint256 amount = uint256(amountSeed) + 1;
        FuzzToken reward = new FuzzToken();
        FuzzToken lp = new FuzzToken();
        lp.mint(ALICE, 10 ether);
        LpRewardVault lpVault = new LpRewardVault(address(reward), address(lp), 1 ether);
        lpVault.syncWeight(ALICE);

        reward.mint(address(this), amount * 3);
        reward.approve(address(lpVault.rewardAccounting()), amount);
        (bool directLpFund,) =
            address(lpVault.rewardAccounting()).call(abi.encodeWithSignature("fundRewards(uint256)", amount));
        require(!directLpFund, "LP inner accepted direct funding");
        reward.approve(address(lpVault), amount);
        lpVault.fundRewards(amount);
        VM.prank(ALICE);
        (bool directLpClaim,) = address(lpVault.rewardAccounting()).call(abi.encodeWithSignature("claimRewards()"));
        require(!directLpClaim, "LP inner accepted direct claim");
        VM.prank(ALICE);
        require(lpVault.claimRewards() == amount, "LP wrapper claim lost rewards");

        FuzzToken project = new FuzzToken();
        project.mint(ALICE, 100 ether);
        HolderDeadRewardVault holderVault =
            new HolderDeadRewardVault(address(reward), address(project), address(project), ALICE, 7_000, 3_000);
        project.setObserver(address(holderVault));
        reward.approve(address(holderVault.rewardAccounting()), amount);
        (bool directHolderFund,) =
            address(holderVault.rewardAccounting()).call(abi.encodeWithSignature("fundRewards(uint256)", amount));
        require(!directHolderFund, "holder inner bypassed dead split");
        reward.approve(address(holderVault), amount);
        holderVault.fundRewards(amount);
        VM.prank(ALICE);
        (bool directHolderClaim,) =
            address(holderVault.rewardAccounting()).call(abi.encodeWithSignature("claimRewards()"));
        require(!directHolderClaim, "holder inner accepted direct claim");
        uint256 holderAmount = amount - amount * 3_000 / 10_000;
        VM.prank(ALICE);
        require(holderVault.claimRewards() == holderAmount, "holder wrapper claim lost split rewards");
        require(
            reward.balanceOf(DEAD) + reward.balanceOf(ALICE) == amount * 2, "wrapper payouts did not conserve funding"
        );
    }

    function testFuzzTimeWeightedCanceledChurnLeavesNoExpiryDebt(uint8 extraRounds) public {
        FuzzToken reward = new FuzzToken();
        FuzzToken project = new FuzzToken();
        project.mint(ALICE, 1);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 1 days);
        project.setObserver(address(vault));
        uint256 rounds = 100 + uint256(extraRounds % 16);

        for (uint256 index; index < rounds; ++index) {
            VM.warp(block.timestamp + 1);
            project.observedTransfer(ALICE, BOB, 1);
            project.observedTransfer(BOB, ALICE, 1);
        }
        require(vault.expiryCount() == 1, "canceled churn retained expiry debt");

        VM.warp(block.timestamp + 1 days);
        project.observedTransfer(ALICE, CAROL, 1);
        require(vault.trackedBalanceOf(CAROL) == 1, "churn blocked unrelated receipt");
    }

    function testFuzzTimeWeightedDustSaturationPreservesReceiptAndClaim(uint8 extraReceipts, uint96 fundingSeed)
        public
    {
        FuzzToken reward = new FuzzToken();
        FuzzToken project = new FuzzToken();
        project.mint(ALICE, 100 ether);
        TimeWeightedRewardVault vault =
            new TimeWeightedRewardVault(address(reward), address(project), address(project), ALICE, 30_000, 30 days);
        project.setObserver(address(vault));
        uint256 receipts = 65 + uint256(extraReceipts % 16);

        for (uint256 index; index < receipts; ++index) {
            VM.warp(block.timestamp + 1);
            project.observedTransfer(ALICE, BOB, 1);
        }
        uint256 funding = uint256(fundingSeed) + 1 ether;
        reward.mint(address(this), funding * 2);
        reward.approve(address(vault), funding);
        vault.fundRewards(funding);
        VM.warp(block.timestamp + 1);
        project.observedTransfer(ALICE, BOB, 1 ether);
        require(vault.trancheCount(BOB) == receipts + 1, "dust saturation lost exact receipt ages");

        reward.approve(address(vault), funding);
        vault.fundRewards(funding);
        uint256 pending = vault.pendingRewards(BOB);
        require(pending != 0, "legitimate saturated holder accrued nothing");
        VM.prank(BOB);
        require(vault.claimRewards() == pending, "saturated holder claim changed exact accrual");
        require(
            reward.balanceOf(address(vault)) + vault.totalClaimed() == funding * 2,
            "saturated holder accounting lost funding"
        );
    }

    function testFuzzCompanionBalancesNeverBecomeLiveWeight(uint96 balanceSeed) public {
        uint256 companionBalance = uint256(balanceSeed) % 40 ether + 1;
        FuzzToken reward = new FuzzToken();
        FuzzToken timeProject = new FuzzToken();
        timeProject.mint(ALICE, 100 ether);
        TimeWeightedRewardVault timeVault = new TimeWeightedRewardVault(
            address(reward), address(timeProject), address(timeProject), ALICE, 30_000, 1 days
        );
        timeProject.setObserver(address(timeVault));
        timeProject.observedTransfer(ALICE, address(timeVault), companionBalance);
        require(timeVault.weightedBalanceOf(address(timeVault)) == 0, "time companion gained live weight");
        require(timeVault.totalWeight() == 100 ether - companionBalance, "time companion diluted live weight");

        FuzzToken holderProject = new FuzzToken();
        holderProject.mint(ALICE, 100 ether);
        HolderDeadRewardVault holderVault = new HolderDeadRewardVault(
            address(reward), address(holderProject), address(holderProject), ALICE, 10_000, 0
        );
        holderProject.setObserver(address(holderVault));
        holderProject.observedTransfer(ALICE, address(holderVault), companionBalance);
        holderProject.observedTransfer(ALICE, address(holderVault.rewardAccounting()), companionBalance);
        require(holderVault.weightOf(address(holderVault)) == 0, "holder companion gained live weight");
        require(holderVault.weightOf(address(holderVault.rewardAccounting())) == 0, "holder inner gained live weight");
        require(holderVault.totalWeight() == 100 ether - companionBalance * 2, "holder companions diluted live weight");
    }
}
