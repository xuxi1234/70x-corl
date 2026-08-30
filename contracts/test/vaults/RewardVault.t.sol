// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RewardVault} from "../../src/vaults/RewardVault.sol";

interface Vm {
    function expectRevert(bytes calldata revertData) external;
    function prank(address sender) external;
}

contract RewardTestToken {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    address public taxedSender;
    uint16 public senderTaxBps;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function setSenderTax(address sender, uint16 taxBps) external {
        taxedSender = sender;
        senderTaxBps = taxBps;
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
        uint256 fee = owner == taxedSender ? amount * senderTaxBps / 10_000 : 0;
        balanceOf[recipient] += amount - fee;
        balanceOf[address(0xdead)] += fee;
    }
}

contract RewardVaultTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SCALE = 1e36;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant OUTSIDER = address(0xBAD);

    RewardTestToken private token;
    RewardVault private vault;

    function setUp() public {
        token = new RewardTestToken();
        vault = new RewardVault(address(token), address(this), RewardVault.AccessMode.Public);
    }

    function testCumulativeRewardPerWeightCarriesPrecisionAcrossFundings() public {
        vault.setWeight(ALICE, 1);
        vault.setWeight(BOB, 2);
        _fund(3 ether + 1);

        uint256 firstIncrement = ((3 ether + 1) * SCALE) / 3;
        require(vault.rewardPerWeight() == firstIncrement, "first reward-per-weight mismatch");
        require(vault.scaledRemainder() == 1, "first precision remainder missing");

        _fund(2);

        require(vault.rewardPerWeight() == (1 ether + 1) * SCALE, "cumulative precision was discarded");
        require(vault.scaledRemainder() == 0, "combined precision remainder not consumed");
        require(vault.pendingRewards(ALICE) == 1 ether + 1, "alice pending mismatch");
        require(vault.pendingRewards(BOB) == 2 ether + 2, "bob pending mismatch");
    }

    function testClaimsArePullBasedAndDoNotEnumerateOtherAccounts() public {
        vault.setWeight(ALICE, 1);
        vault.setWeight(BOB, 3);
        _fund(40 ether);

        VM.prank(ALICE);
        uint256 aliceClaim = vault.claimRewards();

        require(aliceClaim == 10 ether, "alice claim mismatch");
        require(token.balanceOf(ALICE) == 10 ether, "alice reward not transferred");
        require(token.balanceOf(BOB) == 0, "bob was pushed a reward");
        require(vault.pendingRewards(BOB) == 30 ether, "bob pending reward changed");

        VM.prank(BOB);
        require(vault.claimRewards() == 30 ether, "bob claim mismatch");
        require(vault.totalClaimed() == 40 ether, "claimed accounting mismatch");
        require(token.balanceOf(address(vault)) == 0, "fully allocated rewards stranded");
    }

    function testWeightChangesSettleOldEntitlementBeforeNewWeightApplies() public {
        vault.setWeight(ALICE, 1);
        vault.setWeight(BOB, 1);
        _fund(20 ether);

        vault.setWeight(ALICE, 3);
        _fund(20 ether);

        require(vault.pendingRewards(ALICE) == 25 ether, "alice historical weight rewritten");
        require(vault.pendingRewards(BOB) == 15 ether, "bob entitlement mismatch");
    }

    function testOnlyImmutableControllerCanChangeWeights() public {
        VM.prank(OUTSIDER);
        VM.expectRevert(abi.encodeWithSelector(RewardVault.UnauthorizedController.selector, OUTSIDER));
        vault.setWeight(ALICE, 1);
    }

    function testOnlyControllerCanTriggerClaimForAndPaymentStillGoesToAccount() public {
        vault.setWeight(ALICE, 1);
        _fund(10 ether);

        VM.prank(OUTSIDER);
        VM.expectRevert(abi.encodeWithSelector(RewardVault.UnauthorizedController.selector, OUTSIDER));
        vault.claimRewardsFor(ALICE);

        require(vault.claimRewardsFor(ALICE) == 10 ether, "controller-triggered claim mismatch");
        require(token.balanceOf(ALICE) == 10 ether, "controller redirected account claim");
        require(token.balanceOf(address(this)) == 0, "controller received account reward");
    }

    function testFundingWithoutWeightRevertsWithoutTakingTokens() public {
        token.mint(address(this), 1 ether);
        token.approve(address(vault), 1 ether);

        VM.expectRevert(abi.encodeWithSelector(RewardVault.NoRewardWeight.selector));
        vault.fundRewards(1 ether);

        require(token.balanceOf(address(this)) == 1 ether, "failed funding took tokens");
        require(vault.totalFunded() == 0, "failed funding changed accounting");
    }

    function testClaimRejectsVaultOriginTransferTaxWithoutReducingEntitlement() public {
        vault.setWeight(ALICE, 1);
        _fund(10 ether);
        token.setSenderTax(address(vault), 1_000);

        VM.prank(ALICE);
        VM.expectRevert(
            abi.encodeWithSelector(RewardVault.RewardDeliveryMismatch.selector, 10 ether, 10 ether, 9 ether)
        );
        vault.claimRewards();

        require(vault.pendingRewards(ALICE) == 10 ether, "failed delivery reduced entitlement");
        require(vault.totalClaimed() == 0, "failed delivery increased claimed accounting");
        require(token.balanceOf(address(vault)) == 10 ether, "failed delivery reduced vault rewards");
        require(token.balanceOf(ALICE) == 0, "failed delivery paid a partial reward");
    }

    function _fund(uint256 amount) private {
        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        vault.fundRewards(amount);
    }
}
