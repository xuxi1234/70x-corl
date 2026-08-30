// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ConfigHash} from "../../src/core/ConfigHash.sol";
import {LaunchFactory} from "../../src/core/LaunchFactory.sol";
import {LaunchTypes} from "../../src/core/LaunchTypes.sol";
import {Ownable2Step} from "../../src/core/Ownable2Step.sol";
import {PlatformConfig} from "../../src/core/PlatformConfig.sol";
import {TemplateRegistry} from "../../src/core/TemplateRegistry.sol";
import {ITemplate} from "../../src/interfaces/ITemplate.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes calldata revertData) external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function prank(address sender) external;
    function recordLogs() external;
}

contract RecordingTemplate is ITemplate {
    error InvalidTemplateConfig();

    address public constant TOKEN = address(0x70000001);
    address public constant VAULT = address(0x70000002);
    bytes32 private constant VALID_TEMPLATE_CONFIG = keccak256("valid-template-config");

    address public lastCreator;
    bytes32 public lastCommonConfigHash;
    bytes32 public lastTemplateConfigHash;

    function deploy(address creator, bytes calldata commonConfig, bytes calldata templateConfig)
        external
        returns (address token, address vault)
    {
        if (keccak256(templateConfig) != VALID_TEMPLATE_CONFIG) revert InvalidTemplateConfig();

        lastCreator = creator;
        lastCommonConfigHash = keccak256(commonConfig);
        lastTemplateConfigHash = keccak256(templateConfig);
        return (TOKEN, VAULT);
    }
}

contract ReentrantTemplate is ITemplate {
    LaunchFactory private immutable _factory;
    bytes32 private immutable _templateId;
    uint32 private immutable _version;
    bytes private _commonConfig;
    bytes private _templateConfig;

    constructor(
        LaunchFactory factory,
        bytes32 templateId,
        uint32 version,
        bytes memory commonConfig,
        bytes memory templateConfig
    ) {
        _factory = factory;
        _templateId = templateId;
        _version = version;
        _commonConfig = commonConfig;
        _templateConfig = templateConfig;
    }

    function deploy(address, bytes calldata, bytes calldata) external returns (address token, address vault) {
        return
            _factory.deploy{value: _factory.platformConfig().fee()}(
                _templateId, _version, _commonConfig, _templateConfig
            );
    }

    receive() external payable {}
}

contract LaunchFactoryTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant TEMPLATE_ID = keccak256("standard");
    bytes32 private constant UNKNOWN_TEMPLATE_ID = keccak256("unknown");
    uint32 private constant VERSION = 1;
    uint96 private constant FEE = 0.005 ether;
    address private constant CREATOR = address(0xC0FFEE);
    address private constant REVENUE_RECIPIENT = address(0x7000);
    address private constant NEXT_REVENUE_RECIPIENT = address(0x7001);
    address private constant NON_OWNER = address(0xBAD);

    PlatformConfig private platformConfig;
    TemplateRegistry private registry;
    LaunchFactory private factory;
    RecordingTemplate private template;
    bytes private commonConfig;
    bytes private templateConfig;

    function setUp() public {
        platformConfig = new PlatformConfig(address(this), REVENUE_RECIPIENT);
        registry = new TemplateRegistry(address(this));
        factory = new LaunchFactory(address(this), registry, platformConfig);
        template = new RecordingTemplate();
        registry.register(TEMPLATE_ID, VERSION, address(template), keccak256("schema"));

        commonConfig = abi.encode(_validCommonConfig());
        templateConfig = bytes("valid-template-config");
        VM.deal(CREATOR, 1 ether);
    }

    function testDeployRequiresExactCurrentFee() public {
        VM.prank(CREATOR);
        VM.expectRevert(abi.encodeWithSelector(LaunchFactory.IncorrectFee.selector, FEE, FEE - 1));
        factory.deploy{value: FEE - 1}(TEMPLATE_ID, VERSION, commonConfig, templateConfig);

        VM.prank(CREATOR);
        VM.expectRevert(abi.encodeWithSelector(LaunchFactory.IncorrectFee.selector, FEE, FEE + 1));
        factory.deploy{value: FEE + 1}(TEMPLATE_ID, VERSION, commonConfig, templateConfig);
    }

    function testUnknownTemplateRevertsBeforeFeeTransfer() public {
        uint256 recipientBalance = REVENUE_RECIPIENT.balance;

        VM.prank(CREATOR);
        VM.expectRevert(abi.encodeWithSelector(LaunchFactory.UnknownTemplate.selector, UNKNOWN_TEMPLATE_ID, VERSION));
        factory.deploy{value: FEE}(UNKNOWN_TEMPLATE_ID, VERSION, commonConfig, templateConfig);

        require(REVENUE_RECIPIENT.balance == recipientBalance, "unknown template transferred fee");
    }

    function testInvalidCommonConfigRevertsBeforeTemplateCallOrFeeTransfer() public {
        LaunchTypes.CommonConfig memory invalidConfig = _validCommonConfig();
        invalidConfig.receiver = address(0);
        uint256 recipientBalance = REVENUE_RECIPIENT.balance;

        VM.prank(CREATOR);
        VM.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidReceiver.selector));
        factory.deploy{value: FEE}(TEMPLATE_ID, VERSION, abi.encode(invalidConfig), templateConfig);

        require(template.lastCreator() == address(0), "template called with invalid common config");
        require(REVENUE_RECIPIENT.balance == recipientBalance, "invalid config transferred fee");
    }

    function testNonCanonicalCommonConfigEncodingReverts() public {
        bytes memory nonCanonicalConfig = bytes.concat(commonConfig, hex"00");

        VM.prank(CREATOR);
        VM.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidCommonConfigEncoding.selector));
        factory.deploy{value: FEE}(TEMPLATE_ID, VERSION, nonCanonicalConfig, templateConfig);
    }

    function testCommonConfigBoundsAndAllocationRulesAreAuthoritative() public {
        LaunchTypes.CommonConfig memory config = _validCommonConfig();
        config.supply = 100_000_000_001;
        _expectInvalidCommonConfig(config, abi.encodeWithSelector(LaunchFactory.InvalidSupply.selector, config.supply));

        config = _validCommonConfig();
        config.buyTaxBps = 1001;
        _expectInvalidCommonConfig(
            config, abi.encodeWithSelector(LaunchFactory.TaxExceedsMaximum.selector, config.buyTaxBps)
        );

        config = _validCommonConfig();
        config.allocationBps[3] = 2499;
        _expectInvalidCommonConfig(
            config, abi.encodeWithSelector(LaunchFactory.InvalidAllocationTotal.selector, 10_000, 9_999)
        );

        config = _validCommonConfig();
        config.buyTaxBps = 0;
        config.sellTaxBps = 0;
        _expectInvalidCommonConfig(
            config, abi.encodeWithSelector(LaunchFactory.InvalidAllocationTotal.selector, 0, 10_000)
        );
    }

    function testTemplateConfigRejectionRollsBackFeeTransfer() public {
        uint256 recipientBalance = REVENUE_RECIPIENT.balance;

        VM.prank(CREATOR);
        VM.expectRevert(abi.encodeWithSelector(RecordingTemplate.InvalidTemplateConfig.selector));
        factory.deploy{value: FEE}(TEMPLATE_ID, VERSION, commonConfig, hex"bad0");

        require(REVENUE_RECIPIENT.balance == recipientBalance, "rejected config transferred fee");
    }

    function testDeployCallsResolvedTemplateAndTransfersSnapshottedFee() public {
        platformConfig.setRevenueRecipient(NEXT_REVENUE_RECIPIENT);
        uint96 nextFee = 0.01 ether;
        platformConfig.setFee(nextFee);
        uint256 recipientBalance = NEXT_REVENUE_RECIPIENT.balance;

        VM.prank(CREATOR);
        (address token, address vault) =
            factory.deploy{value: nextFee}(TEMPLATE_ID, VERSION, commonConfig, templateConfig);

        require(token == template.TOKEN(), "token return mismatch");
        require(vault == template.VAULT(), "vault return mismatch");
        require(template.lastCreator() == CREATOR, "creator not forwarded");
        require(template.lastCommonConfigHash() == keccak256(commonConfig), "common config not forwarded");
        require(template.lastTemplateConfigHash() == keccak256(templateConfig), "template config not forwarded");
        require(NEXT_REVENUE_RECIPIENT.balance == recipientBalance + nextFee, "fee not transferred");
        require(REVENUE_RECIPIENT.balance == 0, "fee transferred to stale recipient");
    }

    function testPauseIsOwnerControlledAndOnlyBlocksNewDeployments() public {
        VM.prank(NON_OWNER);
        VM.expectRevert(abi.encodeWithSelector(Ownable2Step.UnauthorizedAccount.selector, NON_OWNER));
        factory.setPaused(true);

        factory.setPaused(true);
        require(factory.paused(), "factory not paused");
        (address implementation,) = registry.resolve(TEMPLATE_ID, VERSION);
        require(implementation == address(template), "pause changed registry resolution");

        VM.prank(CREATOR);
        VM.expectRevert(abi.encodeWithSelector(LaunchFactory.DeploymentsPaused.selector));
        factory.deploy{value: FEE}(TEMPLATE_ID, VERSION, commonConfig, templateConfig);

        factory.setPaused(false);
        VM.prank(CREATOR);
        (address token,) = factory.deploy{value: FEE}(TEMPLATE_ID, VERSION, commonConfig, templateConfig);
        require(token == template.TOKEN(), "deployment did not resume");
    }

    function testProjectDeployedEventContainsCanonicalSnapshot() public {
        bytes32 expectedCommonConfigHash = ConfigHash.hash(_validCommonConfig());

        VM.recordLogs();
        VM.prank(CREATOR);
        factory.deploy{value: FEE}(TEMPLATE_ID, VERSION, commonConfig, templateConfig);
        Vm.Log[] memory logs = VM.getRecordedLogs();
        Vm.Log memory deploymentLog = _factoryLog(logs);

        require(deploymentLog.topics.length == 4, "unexpected indexed fields");
        require(
            deploymentLog.topics[0]
                == keccak256("ProjectDeployed(bytes32,uint32,address,address,address,uint96,address,bytes32)"),
            "unexpected event signature"
        );
        require(deploymentLog.topics[1] == TEMPLATE_ID, "template id missing");
        require(deploymentLog.topics[2] == bytes32(uint256(VERSION)), "version missing");
        require(deploymentLog.topics[3] == bytes32(uint256(uint160(CREATOR))), "creator missing");

        (address token, address vault, uint96 fee, address recipient, bytes32 commonConfigHash) =
            abi.decode(deploymentLog.data, (address, address, uint96, address, bytes32));
        require(token == template.TOKEN(), "token missing");
        require(vault == template.VAULT(), "vault missing");
        require(fee == FEE, "fee missing");
        require(recipient == REVENUE_RECIPIENT, "recipient missing");
        require(commonConfigHash == expectedCommonConfigHash, "common config hash missing");
    }

    function testProjectConfigPersistsExactCalldataForDirectChainReads() public {
        VM.prank(CREATOR);
        (address token, address vault) = factory.deploy{value: FEE}(TEMPLATE_ID, VERSION, commonConfig, templateConfig);

        (bytes32 storedId, uint32 storedVersion, bytes memory storedCommon, bytes memory storedTemplate) =
            factory.projectConfig(vault);
        require(storedId == TEMPLATE_ID, "stored template id mismatch");
        require(storedVersion == VERSION, "stored version mismatch");
        require(keccak256(storedCommon) == keccak256(commonConfig), "stored common config mismatch");
        require(keccak256(storedTemplate) == keccak256(templateConfig), "stored template config mismatch");

        (storedId, storedVersion, storedCommon, storedTemplate) = factory.projectConfig(token);
        require(storedId == TEMPLATE_ID, "token template id mismatch");
        require(storedVersion == VERSION, "token version mismatch");
        require(keccak256(storedCommon) == keccak256(commonConfig), "token common config mismatch");
        require(keccak256(storedTemplate) == keccak256(templateConfig), "token template config mismatch");
    }

    function testTemplateCannotReenterDeployment() public {
        bytes32 reentrantId = keccak256("reentrant");
        ReentrantTemplate reentrant = new ReentrantTemplate(factory, reentrantId, VERSION, commonConfig, templateConfig);
        registry.register(reentrantId, VERSION, address(reentrant), keccak256("reentrant-schema"));
        VM.deal(address(reentrant), FEE);

        VM.prank(CREATOR);
        VM.expectRevert(abi.encodeWithSelector(LaunchFactory.ReentrantDeployment.selector));
        factory.deploy{value: FEE}(reentrantId, VERSION, commonConfig, templateConfig);
    }

    function _expectInvalidCommonConfig(LaunchTypes.CommonConfig memory config, bytes memory expectedRevert) private {
        VM.prank(CREATOR);
        VM.expectRevert(expectedRevert);
        factory.deploy{value: FEE}(TEMPLATE_ID, VERSION, abi.encode(config), templateConfig);
    }

    function _validCommonConfig() private pure returns (LaunchTypes.CommonConfig memory config) {
        config.name = "70X Launch";
        config.symbol = "CORLA";
        config.supply = 1_000_000_000;
        config.buyTaxBps = 300;
        config.sellTaxBps = 500;
        config.receiver = address(0x1111);
        config.rewardToken = address(0x2222);
        config.rewardThreshold = 0.5 ether;
        config.lpMode = 1;
        config.allocationBps = [uint16(2500), uint16(2500), uint16(2500), uint16(2500)];
        config.metadataHash = keccak256("metadata");
    }

    function _factoryLog(Vm.Log[] memory logs) private view returns (Vm.Log memory deploymentLog) {
        for (uint256 index; index < logs.length; ++index) {
            if (logs[index].emitter == address(factory)) return logs[index];
        }
        revert("factory log missing");
    }
}
