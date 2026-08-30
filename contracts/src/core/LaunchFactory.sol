// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ConfigHash} from "./ConfigHash.sol";
import {LaunchTypes} from "./LaunchTypes.sol";
import {Ownable2Step} from "./Ownable2Step.sol";
import {PlatformConfig} from "./PlatformConfig.sol";
import {TemplateRegistry} from "./TemplateRegistry.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";

contract LaunchFactory is Ownable2Step {
    error DeploymentsPaused();
    error FeeTransferFailed(address recipient, uint256 amount);
    error IncorrectFee(uint256 requiredFee, uint256 providedFee);
    error InvalidAllocationTotal(uint256 requiredTotal, uint256 actualTotal);
    error InvalidCommonConfigEncoding();
    error InvalidReceiver();
    error InvalidSupply(uint256 supply);
    error ReentrantDeployment();
    error TaxExceedsMaximum(uint16 taxBps);
    error UnknownTemplate(bytes32 id, uint32 version);

    event DeploymentsPauseChanged(bool paused);
    event ProjectDeployed(
        bytes32 indexed id,
        uint32 indexed version,
        address indexed creator,
        address token,
        address vault,
        uint96 fee,
        address recipient,
        bytes32 commonConfigHash
    );

    uint256 public constant MAX_SUPPLY = 100_000_000_000;
    uint16 public constant MAX_TAX_BPS = 1_000;
    uint256 public constant TOTAL_ALLOCATION_BPS = 10_000;

    struct DeploymentContext {
        address implementation;
        address creator;
        address recipient;
        uint96 fee;
        bytes32 commonConfigHash;
    }

    TemplateRegistry public immutable registry;
    PlatformConfig public immutable platformConfig;
    bool public paused;

    bool private _deploying;

    constructor(address initialOwner, TemplateRegistry registry_, PlatformConfig platformConfig_)
        Ownable2Step(initialOwner)
    {
        registry = registry_;
        platformConfig = platformConfig_;
    }

    modifier nonReentrantDeployment() {
        if (_deploying) revert ReentrantDeployment();
        _deploying = true;
        _;
        _deploying = false;
    }

    function setPaused(bool newPaused) external onlyOwner {
        paused = newPaused;
        emit DeploymentsPauseChanged(newPaused);
    }

    function deploy(bytes32 id, uint32 version, bytes calldata commonConfig, bytes calldata templateConfig)
        external
        payable
        nonReentrantDeployment
        returns (address token, address vault)
    {
        if (paused) revert DeploymentsPaused();

        DeploymentContext memory context;
        context.fee = platformConfig.fee();
        if (msg.value != context.fee) revert IncorrectFee(context.fee, msg.value);

        (context.implementation,) = registry.resolve(id, version);
        if (context.implementation == address(0)) revert UnknownTemplate(id, version);

        LaunchTypes.CommonConfig memory decodedCommonConfig = abi.decode(commonConfig, (LaunchTypes.CommonConfig));
        if (keccak256(commonConfig) != keccak256(abi.encode(decodedCommonConfig))) {
            revert InvalidCommonConfigEncoding();
        }
        _validateCommonConfig(decodedCommonConfig);

        context.commonConfigHash = ConfigHash.hash(decodedCommonConfig);
        context.creator = msg.sender;
        context.recipient = platformConfig.revenueRecipient();

        (token, vault) = ITemplate(context.implementation).deploy(context.creator, commonConfig, templateConfig);

        (bool feeTransferred,) = payable(context.recipient).call{value: context.fee}("");
        if (!feeTransferred) revert FeeTransferFailed(context.recipient, context.fee);

        emit ProjectDeployed(
            id, version, context.creator, token, vault, context.fee, context.recipient, context.commonConfigHash
        );
    }

    function _validateCommonConfig(LaunchTypes.CommonConfig memory config) private pure {
        if (config.supply == 0 || config.supply > MAX_SUPPLY) revert InvalidSupply(config.supply);
        if (config.buyTaxBps > MAX_TAX_BPS) revert TaxExceedsMaximum(config.buyTaxBps);
        if (config.sellTaxBps > MAX_TAX_BPS) revert TaxExceedsMaximum(config.sellTaxBps);
        if (config.receiver == address(0)) revert InvalidReceiver();

        uint256 allocationTotal;
        for (uint256 index; index < config.allocationBps.length; ++index) {
            allocationTotal += config.allocationBps[index];
        }

        uint256 requiredTotal = config.buyTaxBps == 0 && config.sellTaxBps == 0 ? 0 : TOTAL_ALLOCATION_BPS;
        if (allocationTotal != requiredTotal) revert InvalidAllocationTotal(requiredTotal, allocationTotal);
    }
}
