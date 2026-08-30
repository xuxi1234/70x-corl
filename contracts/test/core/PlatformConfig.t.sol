// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PlatformConfig} from "../../src/core/PlatformConfig.sol";
import {Ownable2Step} from "../../src/core/Ownable2Step.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectRevert(bytes calldata revertData) external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function prank(address sender) external;
    function recordLogs() external;
}

contract DeploymentSnapshot {
    uint96 public immutable fee;
    address public immutable revenueRecipient;

    constructor(PlatformConfig config) {
        fee = config.fee();
        revenueRecipient = config.revenueRecipient();
    }
}

contract PlatformConfigTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant INITIAL_RECIPIENT = address(0x7000);
    address private constant NEXT_RECIPIENT = address(0x7001);
    address private constant NON_OWNER = address(0xBAD);
    uint96 private constant NEXT_FEE = 0.01 ether;

    PlatformConfig private config;

    function setUp() public {
        config = new PlatformConfig(address(this), INITIAL_RECIPIENT);
    }

    function testInitialConfigurationUsesPlatformFee() public view {
        require(config.fee() == 0.005 ether, "initial fee mismatch");
        require(config.revenueRecipient() == INITIAL_RECIPIENT, "initial recipient mismatch");
    }

    function testNonOwnerCannotChangeFee() public {
        VM.prank(NON_OWNER);
        VM.expectRevert(abi.encodeWithSelector(Ownable2Step.UnauthorizedAccount.selector, NON_OWNER));
        config.setFee(NEXT_FEE);
    }

    function testNonOwnerCannotChangeRevenueRecipient() public {
        VM.prank(NON_OWNER);
        VM.expectRevert(abi.encodeWithSelector(Ownable2Step.UnauthorizedAccount.selector, NON_OWNER));
        config.setRevenueRecipient(NEXT_RECIPIENT);
    }

    function testFeeAboveMaximumReverts() public {
        uint96 excessiveFee = 0.05 ether + 1;

        VM.expectRevert(abi.encodeWithSelector(PlatformConfig.FeeExceedsMaximum.selector, excessiveFee));
        config.setFee(excessiveFee);
    }

    function testZeroRevenueRecipientReverts() public {
        VM.expectRevert(abi.encodeWithSelector(PlatformConfig.InvalidRevenueRecipient.selector));
        config.setRevenueRecipient(address(0));
    }

    function testZeroInitialRevenueRecipientReverts() public {
        VM.expectRevert(abi.encodeWithSelector(PlatformConfig.InvalidRevenueRecipient.selector));
        new PlatformConfig(address(this), address(0));
    }

    function testPastDeploymentSnapshotDoesNotChangeWithPlatformConfiguration() public {
        DeploymentSnapshot snapshot = new DeploymentSnapshot(config);

        config.setFee(NEXT_FEE);
        config.setRevenueRecipient(NEXT_RECIPIENT);

        require(snapshot.fee() == 0.005 ether, "past fee snapshot changed");
        require(snapshot.revenueRecipient() == INITIAL_RECIPIENT, "past recipient snapshot changed");
        require(config.fee() == NEXT_FEE, "current fee not changed");
        require(config.revenueRecipient() == NEXT_RECIPIENT, "current recipient not changed");
    }

    function testFeeChangeEventContainsOldAndNewValues() public {
        VM.recordLogs();
        config.setFee(NEXT_FEE);
        Vm.Log[] memory logs = VM.getRecordedLogs();

        require(logs.length == 1, "unexpected log count");
        require(logs[0].emitter == address(config), "unexpected emitter");
        require(logs[0].topics.length == 1, "unexpected indexed fields");
        require(logs[0].topics[0] == keccak256("FeeChanged(uint96,uint96)"), "unexpected event signature");
        (uint96 oldFee, uint96 newFee) = abi.decode(logs[0].data, (uint96, uint96));
        require(oldFee == 0.005 ether, "old fee missing");
        require(newFee == NEXT_FEE, "new fee missing");
    }

    function testRevenueRecipientChangeEventContainsOldAndNewValues() public {
        VM.recordLogs();
        config.setRevenueRecipient(NEXT_RECIPIENT);
        Vm.Log[] memory logs = VM.getRecordedLogs();

        require(logs.length == 1, "unexpected log count");
        require(logs[0].emitter == address(config), "unexpected emitter");
        require(logs[0].topics.length == 1, "unexpected indexed fields");
        require(
            logs[0].topics[0] == keccak256("RevenueRecipientChanged(address,address)"), "unexpected event signature"
        );
        (address oldRecipient, address newRecipient) = abi.decode(logs[0].data, (address, address));
        require(oldRecipient == INITIAL_RECIPIENT, "old recipient missing");
        require(newRecipient == NEXT_RECIPIENT, "new recipient missing");
    }
}
