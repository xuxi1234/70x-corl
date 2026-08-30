// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {MintVault} from "../vaults/MintVault.sol";
import {TimeWeightedRewardVault} from "../vaults/TimeWeightedRewardVault.sol";
import {RewardTemplateTypes} from "./RewardTemplateTypes.sol";

contract TimeWeightedCompanionDeployer {
    function deploy(
        address rewardToken,
        address projectToken,
        address controller,
        uint16 maxMultiplierBps,
        uint32 growthDuration
    ) external returns (TimeWeightedRewardVault vault) {
        vault = new TimeWeightedRewardVault(
            rewardToken, projectToken, controller, controller, maxMultiplierBps, growthDuration
        );
    }
}

contract TimeWeightedRewardMintVault is MintVault {
    TimeWeightedRewardVault public immutable rewardVault;

    constructor(
        RewardTemplateTypes.MintDeploymentConfig memory config,
        TimeWeightedCompanionDeployer companionDeployer,
        address rewardToken,
        uint16 maxMultiplierBps,
        uint32 growthDuration
    )
        MintVault(
            config.creator,
            config.executor,
            config.name,
            config.symbol,
            config.claimTokenAllocation,
            config.launchTokenAllocation,
            config.minimumLiquidityOutput,
            config.totalShares,
            config.pricePerShare
        )
    {
        rewardVault = companionDeployer.deploy(
            rewardToken, address(token), address(this), maxMultiplierBps, growthDuration
        );
    }

    function _onTokenTransfer(address from, address to, uint256 amount) internal override {
        rewardVault.onTokenTransfer(from, to, amount);
    }

    function _onLiquidityTokenSet(address liquidityToken_) internal override {
        rewardVault.onLiquidityTokenSet(liquidityToken_);
    }
}

contract TimeWeightedTemplateV1 is ITemplate {
    struct StandardConfig {
        uint32 totalShares;
        uint96 pricePerShare;
        uint16 claimTokenBps;
        uint256 minimumLiquidityOutput;
    }

    struct TimeWeightedConfig {
        uint16 maxMultiplierBps;
        uint32 growthDuration;
    }

    error InvalidClaimTokenBps(uint16 claimTokenBps);
    error InvalidCommonConfigEncoding();
    error InvalidGrowthDuration(uint32 duration);
    error InvalidMaximumMultiplier(uint16 multiplierBps);
    error InvalidMinimumLiquidityOutput();
    error InvalidPricePerShare();
    error InvalidRewardToken(address token);
    error InvalidTemplateConfigEncoding();
    error InvalidTotalShares();
    error UnauthorizedFactory(address caller);
    error ZeroFactory();
    error ZeroFinalizationExecutor();

    event RewardCompanionDeployed(
        bytes32 indexed templateId,
        uint32 indexed version,
        address indexed token,
        address mintVault,
        address rewardVault,
        bytes32 configHash
    );

    bytes32 public constant TEMPLATE_ID = "TIME_WEIGHTED";
    uint32 public constant VERSION = 1;

    address public immutable factory;
    address public immutable finalizationExecutor;
    TimeWeightedCompanionDeployer public immutable companionDeployer;
    mapping(address mintVault => address companion) public rewardVaultOf;

    constructor(address factory_, address finalizationExecutor_) {
        if (factory_ == address(0)) revert ZeroFactory();
        if (finalizationExecutor_.code.length == 0) revert ZeroFinalizationExecutor();
        factory = factory_;
        finalizationExecutor = finalizationExecutor_;
        companionDeployer = new TimeWeightedCompanionDeployer();
    }

    function deploy(address creator, bytes calldata commonConfig, bytes calldata templateConfig)
        external
        returns (address token, address vault)
    {
        if (msg.sender != factory) revert UnauthorizedFactory(msg.sender);
        LaunchTypes.CommonConfig memory common = abi.decode(commonConfig, (LaunchTypes.CommonConfig));
        if (keccak256(commonConfig) != keccak256(abi.encode(common))) revert InvalidCommonConfigEncoding();
        (StandardConfig memory launch, TimeWeightedConfig memory rewards) =
            abi.decode(templateConfig, (StandardConfig, TimeWeightedConfig));
        if (keccak256(templateConfig) != keccak256(abi.encode(launch, rewards))) {
            revert InvalidTemplateConfigEncoding();
        }
        _validateLaunch(launch);
        if (common.rewardToken.code.length == 0) revert InvalidRewardToken(common.rewardToken);
        if (rewards.maxMultiplierBps < 10_000 || rewards.maxMultiplierBps > 30_000) {
            revert InvalidMaximumMultiplier(rewards.maxMultiplierBps);
        }
        if (rewards.growthDuration < 1 days || rewards.growthDuration > 30 days) {
            revert InvalidGrowthDuration(rewards.growthDuration);
        }

        uint256 scaledSupply = common.supply * 1 ether;
        uint256 claimAllocation = scaledSupply * launch.claimTokenBps / 10_000;
        RewardTemplateTypes.MintDeploymentConfig memory mintConfig = RewardTemplateTypes.MintDeploymentConfig({
            creator: creator,
            executor: finalizationExecutor,
            name: common.name,
            symbol: common.symbol,
            claimTokenAllocation: claimAllocation,
            launchTokenAllocation: scaledSupply - claimAllocation,
            minimumLiquidityOutput: launch.minimumLiquidityOutput,
            totalShares: launch.totalShares,
            pricePerShare: launch.pricePerShare
        });
        TimeWeightedRewardMintVault deployed = new TimeWeightedRewardMintVault(
            mintConfig, companionDeployer, common.rewardToken, rewards.maxMultiplierBps, rewards.growthDuration
        );
        token = address(deployed.token());
        vault = address(deployed);
        address companion = address(deployed.rewardVault());
        rewardVaultOf[vault] = companion;
        emit RewardCompanionDeployed(
            TEMPLATE_ID, VERSION, token, vault, companion, keccak256(abi.encode(common, launch, rewards))
        );
    }

    function _validateLaunch(StandardConfig memory launch) private pure {
        if (launch.totalShares == 0) revert InvalidTotalShares();
        if (launch.pricePerShare == 0) revert InvalidPricePerShare();
        if (launch.claimTokenBps == 0 || launch.claimTokenBps >= 10_000) {
            revert InvalidClaimTokenBps(launch.claimTokenBps);
        }
        if (launch.minimumLiquidityOutput == 0) revert InvalidMinimumLiquidityOutput();
    }
}
