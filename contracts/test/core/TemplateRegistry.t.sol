// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TemplateRegistry} from "../../src/core/TemplateRegistry.sol";
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

contract TemplateRegistryTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant TEMPLATE_ID = keccak256("standard");
    uint32 private constant VERSION = 1;
    address private constant IMPLEMENTATION = address(0xBEEF);
    bytes32 private constant SCHEMA_HASH = keccak256("standard-v1-schema");
    address private constant NON_OWNER = address(0xBAD);
    address private constant NEXT_OWNER = address(0xA11CE);

    TemplateRegistry private registry;

    function setUp() public {
        registry = new TemplateRegistry(address(this));
    }

    function testRegistrationResolvesImplementationAndSchema() public {
        registry.register(TEMPLATE_ID, VERSION, IMPLEMENTATION, SCHEMA_HASH);

        (address implementation, bytes32 schemaHash) = registry.resolve(TEMPLATE_ID, VERSION);
        require(implementation == IMPLEMENTATION, "implementation mismatch");
        require(schemaHash == SCHEMA_HASH, "schema hash mismatch");
    }

    function testDuplicateRegistrationRevertsAndKeepsOriginalEntry() public {
        registry.register(TEMPLATE_ID, VERSION, IMPLEMENTATION, SCHEMA_HASH);

        VM.expectRevert(
            abi.encodeWithSelector(TemplateRegistry.TemplateAlreadyRegistered.selector, TEMPLATE_ID, VERSION)
        );
        registry.register(TEMPLATE_ID, VERSION, address(0xCAFE), keccak256("replacement"));

        (address implementation, bytes32 schemaHash) = registry.resolve(TEMPLATE_ID, VERSION);
        require(implementation == IMPLEMENTATION, "implementation replaced");
        require(schemaHash == SCHEMA_HASH, "schema hash replaced");
    }

    function testNonOwnerCannotRegister() public {
        VM.prank(NON_OWNER);
        VM.expectRevert(abi.encodeWithSelector(Ownable2Step.UnauthorizedAccount.selector, NON_OWNER));
        registry.register(TEMPLATE_ID, VERSION, IMPLEMENTATION, SCHEMA_HASH);
    }

    function testZeroImplementationReverts() public {
        VM.expectRevert(abi.encodeWithSelector(TemplateRegistry.InvalidImplementation.selector));
        registry.register(TEMPLATE_ID, VERSION, address(0), SCHEMA_HASH);
    }

    function testZeroInitialOwnerReverts() public {
        VM.expectRevert(abi.encodeWithSelector(Ownable2Step.InvalidOwner.selector, address(0)));
        new TemplateRegistry(address(0));
    }

    function testRegistrationEventContainsImmutableEntry() public {
        VM.recordLogs();
        registry.register(TEMPLATE_ID, VERSION, IMPLEMENTATION, SCHEMA_HASH);
        Vm.Log[] memory logs = VM.getRecordedLogs();

        require(logs.length == 1, "unexpected log count");
        require(logs[0].emitter == address(registry), "unexpected emitter");
        require(logs[0].topics.length == 4, "unexpected indexed fields");
        require(
            logs[0].topics[0] == keccak256("TemplateRegistered(bytes32,uint32,address,bytes32)"),
            "unexpected event signature"
        );
        require(logs[0].topics[1] == TEMPLATE_ID, "template id missing");
        require(logs[0].topics[2] == bytes32(uint256(VERSION)), "version missing");
        require(logs[0].topics[3] == bytes32(uint256(uint160(IMPLEMENTATION))), "implementation missing");
        require(abi.decode(logs[0].data, (bytes32)) == SCHEMA_HASH, "schema hash missing");
    }

    function testOwnershipTransferRequiresAcceptance() public {
        registry.transferOwnership(NEXT_OWNER);
        require(registry.owner() == address(this), "ownership changed before acceptance");
        require(registry.pendingOwner() == NEXT_OWNER, "pending owner mismatch");

        VM.prank(NEXT_OWNER);
        registry.acceptOwnership();

        require(registry.owner() == NEXT_OWNER, "ownership not accepted");
        require(registry.pendingOwner() == address(0), "pending owner not cleared");
    }
}
