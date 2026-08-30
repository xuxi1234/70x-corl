// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {HolderDeadRewardVault} from "../vaults/HolderDeadRewardVault.sol";
import {MintVault} from "../vaults/MintVault.sol";
import {RewardTemplateTypes} from "./RewardTemplateTypes.sol";

contract HolderDeadCompanionDeployer {
    function deploy(address rewardToken, address projectToken, address controller, uint16 holderBps, uint16 deadBps)
        external
        returns (HolderDeadRewardVault vault)
    {
        vault = new HolderDeadRewardVault(rewardToken, projectToken, controller, controller, holderBps, deadBps);
    }
}

contract HolderDeadRewardMintVault is MintVault {
    HolderDeadRewardVault public immutable rewardVault;

    constructor(
        RewardTemplateTypes.MintDeploymentConfig memory config,
        HolderDeadCompanionDeployer companionDeployer,
        address rewardToken,
        uint16 holderBps,
        uint16 deadBps
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
        rewardVault = companionDeployer.deploy(rewardToken, address(token), address(this), holderBps, deadBps);
    }

    function _onTokenTransfer(address from, address to, uint256 amount) internal override {
        rewardVault.onTokenTransfer(from, to, amount);
    }

    function _onLiquidityTokenSet(address liquidityToken_) internal override {
        rewardVault.onLiquidityTokenSet(liquidityToken_);
    }
}

contract HolderDeadTemplateV1 is ITemplate {
    struct StandardConfig {
        uint32 totalShares;
        uint96 pricePerShare;
        uint16 claimTokenBps;
        uint256 minimumLiquidityOutput;
    }

    struct HolderDeadConfig {
        uint16 holderBps;
        uint16 deadBps;
    }

    error InvalidClaimTokenBps(uint16 claimTokenBps);
    error InvalidCommonConfigEncoding();
    error InvalidMinimumLiquidityOutput();
    error InvalidPricePerShare();
    error InvalidRewardSplit(uint256 totalBps);
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

    bytes32 public constant TEMPLATE_ID = "HOLDER_DEAD";
    uint32 public constant VERSION = 1;

    address public immutable factory;
    address public immutable finalizationExecutor;
    HolderDeadCompanionDeployer public immutable companionDeployer;
    mapping(address mintVault => address companion) public rewardVaultOf;

    constructor(address factory_, address finalizationExecutor_) {
        if (factory_ == address(0)) revert ZeroFactory();
        if (finalizationExecutor_.code.length == 0) revert ZeroFinalizationExecutor();
        factory = factory_;
        finalizationExecutor = finalizationExecutor_;
        companionDeployer = new HolderDeadCompanionDeployer();
    }

    function deploy(address creator, bytes calldata commonConfig, bytes calldata templateConfig)
        external
        returns (address token, address vault)
    {
        if (msg.sender != factory) revert UnauthorizedFactory(msg.sender);
        LaunchTypes.CommonConfig memory common = abi.decode(commonConfig, (LaunchTypes.CommonConfig));
        if (keccak256(commonConfig) != keccak256(abi.encode(common))) revert InvalidCommonConfigEncoding();
        (StandardConfig memory launch, HolderDeadConfig memory rewards) =
            abi.decode(templateConfig, (StandardConfig, HolderDeadConfig));
        if (keccak256(templateConfig) != keccak256(abi.encode(launch, rewards))) {
            revert InvalidTemplateConfigEncoding();
        }
        _validateLaunch(launch);
        if (common.rewardToken.code.length == 0) revert InvalidRewardToken(common.rewardToken);
        uint256 totalBps = uint256(rewards.holderBps) + rewards.deadBps;
        if (totalBps != 10_000) revert InvalidRewardSplit(totalBps);

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
        HolderDeadRewardMintVault deployed = new HolderDeadRewardMintVault(
            mintConfig, companionDeployer, common.rewardToken, rewards.holderBps, rewards.deadBps
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
