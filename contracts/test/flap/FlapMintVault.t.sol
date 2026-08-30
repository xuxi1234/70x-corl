// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFlapAdapter} from "../../src/interfaces/IFlapAdapter.sol";
import {FlapMintVault} from "../../src/vaults/FlapMintVault.sol";
import {FlapTemplateV1} from "../../src/templates/FlapTemplateV1.sol";
import {LaunchTypes} from "../../src/core/LaunchTypes.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function expectRevert() external;
    function prank(address sender) external;
    function warp(uint256 newTimestamp) external;
}

contract FlapTestPair {}

contract FlapTestToken {
    mapping(address => uint256) public balanceOf;
    uint256 public sellProtectedUntil;

    constructor(uint256 protectedUntil_) {
        sellProtectedUntil = protectedUntil_;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract FlapTestAdapter is IFlapAdapter {
    bool public shouldFail;
    bool public preDex;
    FlapTestPair public immutable pair = new FlapTestPair();

    function setShouldFail(bool value) external {
        shouldFail = value;
    }

    function setPreDex(bool value) external {
        preDex = value;
    }

    function execute(LaunchRequest calldata request) external payable returns (LaunchResult memory result) {
        if (shouldFail) revert("flap failed");
        FlapTestToken token = new FlapTestToken(block.timestamp + request.protectionDuration);
        token.mint(msg.sender, 1_000 ether);
        result = LaunchResult(address(token), preDex ? address(0) : address(pair), 1_000 ether, msg.value);
    }
}

contract FlapMintVaultTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function _vault(FlapTestAdapter adapter, uint64 protection) private returns (FlapMintVault) {
        return new FlapMintVault(address(this), address(adapter), 2 ether, 2, bytes32(0), 0, protection);
    }

    function testLaunchFailurePreservesPrincipalAndPermissionlessRetrySucceeds() external {
        FlapTestAdapter adapter = new FlapTestAdapter();
        adapter.setShouldFail(true);
        FlapMintVault vault = _vault(adapter, 10 minutes);
        VM.deal(ALICE, 2 ether);
        VM.prank(ALICE);
        vault.mint{value: 2 ether}(2);
        bool success = vault.executeLaunch(
            IFlapAdapter.LaunchRequest(0, address(0), bytes32(uint256(1)), 1, block.timestamp + 1 hours, 10 minutes)
        );
        require(!success && address(vault).balance == 2 ether, "failed path leaked principal");
        adapter.setShouldFail(false);
        success = vault.retryLaunch(
            IFlapAdapter.LaunchRequest(0, address(0), bytes32(uint256(1)), 1, block.timestamp + 1 hours, 10 minutes)
        );
        require(success && address(vault).balance == 0, "retry did not launch");
        VM.prank(ALICE);
        require(vault.claim() == 1_000 ether, "claim mismatch");
    }

    function testLaunchAcceptsTokenBeforeDexPoolGraduation() external {
        FlapTestAdapter adapter = new FlapTestAdapter();
        adapter.setPreDex(true);
        FlapMintVault vault = _vault(adapter, 0);
        VM.deal(ALICE, 2 ether);
        VM.prank(ALICE);
        vault.mint{value: 2 ether}(2);

        bool success = vault.executeLaunch(
            IFlapAdapter.LaunchRequest(0, address(0), bytes32(uint256(1)), 1, block.timestamp + 1 hours, 0)
        );

        require(success && vault.pair() == address(0), "bonding-curve launch must not require a DEX pool");
    }

    function testUnfilledVaultRefundsExactlyAfterTwentyFourHours() external {
        FlapMintVault vault = _vault(new FlapTestAdapter(), 0);
        VM.deal(ALICE, 1 ether);
        VM.prank(ALICE);
        vault.mint{value: 1 ether}(1);
        VM.warp(block.timestamp + 24 hours);
        vault.enableRefunds();
        uint256 before = ALICE.balance;
        VM.prank(ALICE);
        vault.refund();
        require(ALICE.balance - before == 1 ether && address(vault).balance == 0, "refund mismatch");
    }

    function testFilledVaultRefundsAfterFailedLaunchAndTwentyFourHours() external {
        FlapTestAdapter adapter = new FlapTestAdapter();
        adapter.setShouldFail(true);
        FlapMintVault vault = _vault(adapter, 0);
        VM.deal(ALICE, 2 ether);
        VM.prank(ALICE);
        vault.mint{value: 2 ether}(2);

        uint256 adapterBefore = address(adapter).balance;
        uint256 creatorBefore = address(this).balance;
        bool success = vault.executeLaunch(
            IFlapAdapter.LaunchRequest(0, address(0), bytes32(uint256(1)), 1, block.timestamp + 2 days, 0)
        );
        require(!success, "failure expected");
        require(
            address(adapter).balance == adapterBefore && address(this).balance == creatorBefore, "principal escaped"
        );

        VM.warp(block.timestamp + 24 hours);
        vault.enableRefunds();
        uint256 before = ALICE.balance;
        VM.prank(ALICE);
        vault.refund();
        require(ALICE.balance - before == 2 ether && address(vault).balance == 0, "filled refund mismatch");
    }

    function testWhitelistProofIsRequiredUntilDeadline() external {
        FlapTestAdapter adapter = new FlapTestAdapter();
        bytes32 root = keccak256(abi.encodePacked(ALICE));
        FlapMintVault vault =
            new FlapMintVault(address(this), address(adapter), 2 ether, 2, root, uint64(block.timestamp + 1 hours), 0);
        VM.deal(ALICE, 2 ether);
        VM.prank(ALICE);
        VM.expectRevert();
        vault.mint{value: 1 ether}(1);

        bytes32[] memory proof = new bytes32[](0);
        VM.prank(ALICE);
        vault.mintWithProof{value: 1 ether}(1, 0, proof);
        require(vault.sharesOf(ALICE) == 1, "whitelist mint failed");
    }

    function testClaimsStayProportionalToPaidShares() external {
        FlapMintVault vault = _vault(new FlapTestAdapter(), 0);
        VM.deal(ALICE, 1 ether);
        VM.deal(BOB, 1 ether);
        VM.prank(ALICE);
        vault.mint{value: 1 ether}(1);
        VM.prank(BOB);
        vault.mint{value: 1 ether}(1);
        vault.executeLaunch(
            IFlapAdapter.LaunchRequest(0, address(0), bytes32(uint256(1)), 1, block.timestamp + 1 hours, 0)
        );
        VM.prank(ALICE);
        require(vault.claim() == 500 ether, "alice share");
        VM.prank(BOB);
        require(vault.claim() == 500 ether, "bob share");
    }

    function testRejectsGoalAndProtectionOutsideApprovedBounds() external {
        FlapTestAdapter adapter = new FlapTestAdapter();
        VM.expectRevert();
        new FlapMintVault(address(this), address(adapter), 1 ether, 1, bytes32(0), 0, 0);
        VM.expectRevert();
        new FlapMintVault(address(this), address(adapter), 17 ether, 17, bytes32(0), 0, 0);
        VM.expectRevert();
        new FlapMintVault(address(this), address(adapter), 2 ether, 2, bytes32(0), 0, 11 minutes);
    }

    function testFlapTemplateDeploysFactoryBoundVault() external {
        FlapTestAdapter adapter = new FlapTestAdapter();
        FlapTemplateV1 template = new FlapTemplateV1(address(this), address(adapter));
        LaunchTypes.CommonConfig memory common;
        common.name = "Flap";
        common.symbol = "FLAP";
        common.supply = 1_000_000;
        common.receiver = address(0x1234);
        FlapTemplateV1.Config memory config = FlapTemplateV1.Config({
            goal: 2 ether, totalShares: 2, initialRoot: bytes32(0), whitelistDeadline: 0, protectionDuration: 5 minutes
        });
        (address token, address vault) = template.deploy(ALICE, abi.encode(common), abi.encode(config));
        require(token == address(0) && FlapMintVault(payable(vault)).goal() == 2 ether, "template result mismatch");
    }
}
