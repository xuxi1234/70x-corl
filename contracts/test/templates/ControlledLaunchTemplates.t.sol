// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FinanceVault} from "../../src/vaults/FinanceVault.sol";
import {LaunchLimits} from "../../src/modules/LaunchLimits.sol";
import {WhitelistMint} from "../../src/modules/WhitelistMint.sol";
import {LaunchTypes} from "../../src/core/LaunchTypes.sol";
import {FinanceExitTemplateV1} from "../../src/templates/FinanceExitTemplateV1.sol";
import {LaunchLimitTemplateV1, LaunchLimitMintVault} from "../../src/templates/LaunchLimitTemplateV1.sol";
import {WhitelistTemplateV1, WhitelistMintVault} from "../../src/templates/WhitelistTemplateV1.sol";
import {StandardTemplateV1} from "../../src/templates/StandardTemplateV1.sol";
import {ILaunchExecutor} from "../../src/vaults/MintVault.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function expectRevert() external;
    function prank(address sender) external;
    function warp(uint256 newTimestamp) external;
}

contract ControlledToken {
    uint256 public totalSupply = 1_000_000 ether;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        require(allowance[owner][msg.sender] >= amount && balanceOf[owner] >= amount, "funding");
        allowance[owner][msg.sender] -= amount;
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract ControlledExecutor is ILaunchExecutor {
    function execute(address, uint256, uint256, uint256) external payable returns (ExecutionResult memory) {
        revert("unused");
    }
}

contract ControlledLaunchTemplatesTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant USER = address(0xA11CE);
    address private constant OTHER = address(0xB0B);

    function _common() private pure returns (LaunchTypes.CommonConfig memory config) {
        config.name = "Controlled";
        config.symbol = "CTRL";
        config.supply = 1_000_000;
        config.receiver = address(0x1234);
    }

    function _standard() private pure returns (StandardTemplateV1.StandardConfig memory config) {
        config = StandardTemplateV1.StandardConfig({
            totalShares: 10, pricePerShare: 0.1 ether, claimTokenBps: 7_000, minimumLiquidityOutput: 1
        });
    }

    function testControlledTemplatesDeployDiscoverableCompanions() external {
        ControlledToken usdt = new ControlledToken();
        ControlledExecutor executor = new ControlledExecutor();
        FinanceExitTemplateV1 finance = new FinanceExitTemplateV1(address(this), address(executor));
        (, address financeMint) = finance.deploy(
            USER, abi.encode(_common()), abi.encode(FinanceExitTemplateV1.Config(_standard(), address(usdt)))
        );
        require(finance.financeVaultOf(financeMint) != address(0), "finance companion missing");

        uint32[] memory durations = new uint32[](1);
        durations[0] = 10;
        uint16[] memory limits = new uint16[](1);
        limits[0] = 100;
        LaunchLimitTemplateV1 limited = new LaunchLimitTemplateV1(address(this), address(executor));
        (, address limitMint) = limited.deploy(
            USER, abi.encode(_common()), abi.encode(LaunchLimitTemplateV1.Config(_standard(), durations, limits))
        );
        require(address(LaunchLimitMintVault(payable(limitMint)).limits()) != address(0), "limit module missing");

        WhitelistTemplateV1 whitelist = new WhitelistTemplateV1(address(this), address(executor));
        bytes32 root = keccak256(abi.encodePacked(USER));
        (, address whitelistMint) = whitelist.deploy(
            USER,
            abi.encode(_common()),
            abi.encode(WhitelistTemplateV1.Config(_standard(), root, uint64(block.timestamp + 1 hours)))
        );
        require(
            address(WhitelistMintVault(payable(whitelistMint)).whitelist()) != address(0), "whitelist module missing"
        );
    }

    function testNativeFinanceClaimsStopAtImmutableLifetimeMultiple() external {
        ControlledToken usdt = new ControlledToken();
        FinanceVault vault = new FinanceVault(address(usdt));
        VM.deal(USER, 2 ether);
        VM.prank(USER);
        uint256 position = vault.openNative{value: 1 ether}(20_000);
        vault.fundNative{value: 1 ether}();
        VM.prank(USER);
        uint256 paid = vault.claim(position, type(uint256).max);
        require(paid == 2 ether, "wrong payout");
        (,,,,, bool closed) = vault.positions(position);
        require(closed, "cap did not close");
        VM.prank(USER);
        VM.expectRevert();
        vault.claim(position, 1);
    }

    function testTokenFundingShortfallPreservesRemainingClaim() external {
        ControlledToken usdt = new ControlledToken();
        FinanceVault vault = new FinanceVault(address(usdt));
        usdt.mint(USER, 100 ether);
        VM.prank(USER);
        usdt.approve(address(vault), 100 ether);
        VM.prank(USER);
        uint256 position = vault.openToken(100 ether, 30_000);
        VM.prank(USER);
        require(vault.claim(position, type(uint256).max) == 100 ether, "principal payout");
        usdt.mint(address(this), 50 ether);
        usdt.approve(address(vault), 50 ether);
        vault.fundToken(50 ether);
        VM.prank(USER);
        require(vault.claim(position, type(uint256).max) == 50 ether, "later funding payout");
        (,,, uint256 claimed,, bool closed) = vault.positions(position);
        require(claimed == 150 ether && !closed, "remaining claim lost");
    }

    function testLaunchLimitsEnforceNonDecreasingWindowsAndExpire() external {
        ControlledToken token = new ControlledToken();
        uint32[] memory durations = new uint32[](2);
        durations[0] = 10;
        durations[1] = 20;
        uint16[] memory limits = new uint16[](2);
        limits[0] = 100;
        limits[1] = 200;
        LaunchLimits guard = new LaunchLimits(address(this), address(token), address(0xE), durations, limits);
        guard.activate(address(0xCAFE));
        token.mint(USER, 10_001 ether);
        VM.expectRevert();
        guard.validateTransfer(address(0), USER);
        VM.warp(block.timestamp + 10 minutes);
        guard.validateTransfer(address(0), USER);
        token.mint(USER, 10_000 ether);
        VM.expectRevert();
        guard.validateTransfer(address(0), USER);
        VM.warp(block.timestamp + 20 minutes);
        guard.validateTransfer(address(0), USER);

        limits[1] = 50;
        VM.expectRevert();
        new LaunchLimits(address(this), address(token), address(0xE), durations, limits);
    }

    function testWhitelistEpochsAreAppendOnlyAndMintBecomesPublic() external {
        bytes32 leaf = keccak256(abi.encodePacked(USER));
        WhitelistMint list = new WhitelistMint(address(this), leaf, uint64(block.timestamp + 1 hours));
        bytes32[] memory proof = new bytes32[](0);
        require(list.isAllowed(0, USER, proof), "initial proof rejected");
        require(!list.isAllowed(0, OTHER, proof), "invalid proof accepted");
        list.appendEpoch(keccak256(abi.encodePacked(OTHER)));
        require(list.epochCount() == 2, "epoch not appended");
        VM.warp(block.timestamp + 1 hours);
        require(list.isPublic(), "did not become public");
        VM.expectRevert();
        list.appendEpoch(bytes32(uint256(1)));
    }
}
