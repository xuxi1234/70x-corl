// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {LpRewardVault} from "../vaults/LpRewardVault.sol";
import {MintVault} from "../vaults/MintVault.sol";
import {RewardTemplateTypes} from "./RewardTemplateTypes.sol";

interface ILpTemplateExecutor {
    function factory() external view returns (address);
    function wbnb() external view returns (address);
}

interface ILpTemplateFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface ILpTemplatePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract LpRewardCompanionDeployer {
    error InvalidCanonicalLpToken(address expected, address actual);
    error InvalidPairMembers(address pair, address token0, address token1);
    error UnexpectedDependencyCodehash(address dependency, bytes32 expected, bytes32 actual);

    function deploy(address projectToken, address rewardToken, RewardTemplateTypes.LpPairConfig memory pairConfig)
        external
        returns (LpRewardVault vault)
    {
        if (pairConfig.pancakeFactory.codehash != pairConfig.factoryCodehash) {
            revert UnexpectedDependencyCodehash(
                pairConfig.pancakeFactory, pairConfig.factoryCodehash, pairConfig.pancakeFactory.codehash
            );
        }
        if (pairConfig.wbnb.codehash != pairConfig.wbnbCodehash) {
            revert UnexpectedDependencyCodehash(pairConfig.wbnb, pairConfig.wbnbCodehash, pairConfig.wbnb.codehash);
        }
        ILpTemplateFactory canonicalFactory = ILpTemplateFactory(pairConfig.pancakeFactory);
        address pair = canonicalFactory.getPair(projectToken, pairConfig.wbnb);
        if (pair == address(0)) pair = canonicalFactory.createPair(projectToken, pairConfig.wbnb);
        if (pair != pairConfig.expectedLpToken) revert InvalidCanonicalLpToken(pairConfig.expectedLpToken, pair);
        address token0 = ILpTemplatePair(pair).token0();
        address token1 = ILpTemplatePair(pair).token1();
        if (!((token0 == projectToken && token1 == pairConfig.wbnb)
                    || (token0 == pairConfig.wbnb && token1 == projectToken))) {
            revert InvalidPairMembers(pair, token0, token1);
        }
        vault = new LpRewardVault(rewardToken, pair, pairConfig.minimumEligibleBalance);
    }
}

contract LpRewardMintVault is MintVault {
    LpRewardVault public immutable rewardVault;

    constructor(
        RewardTemplateTypes.MintDeploymentConfig memory config,
        LpRewardCompanionDeployer companionDeployer,
        address rewardToken,
        RewardTemplateTypes.LpPairConfig memory pairConfig
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
        rewardVault = companionDeployer.deploy(address(token), rewardToken, pairConfig);
    }
}

contract LpRewardsTemplateV1 is ITemplate {
    struct StandardConfig {
        uint32 totalShares;
        uint96 pricePerShare;
        uint16 claimTokenBps;
        uint256 minimumLiquidityOutput;
    }

    struct LpRewardsConfig {
        address lpToken;
        uint256 minimumEligibleBalance;
    }

    error InvalidClaimTokenBps(uint16 claimTokenBps);
    error InvalidCommonConfigEncoding();
    error InvalidDependency(address dependency);
    error InvalidLpToken(address token);
    error InvalidMinimumEligibleBalance();
    error InvalidMinimumLiquidityOutput();
    error InvalidPricePerShare();
    error InvalidRewardToken(address token);
    error InvalidTemplateConfigEncoding();
    error InvalidTotalShares();
    error UnauthorizedFactory(address caller);
    error UnexpectedDependencyCodehash(address dependency, bytes32 expected, bytes32 actual);
    error UnexpectedExecutorRoute(
        address expectedFactory, address actualFactory, address expectedWbnb, address actualWbnb
    );
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

    bytes32 public constant TEMPLATE_ID = "LP_REWARDS";
    uint32 public constant VERSION = 1;

    address public immutable factory;
    address public immutable finalizationExecutor;
    address public immutable pancakeFactory;
    address public immutable wbnb;
    bytes32 public immutable executorCodehash;
    bytes32 public immutable pancakeFactoryCodehash;
    bytes32 public immutable wbnbCodehash;
    LpRewardCompanionDeployer public immutable companionDeployer;
    mapping(address mintVault => address companion) public rewardVaultOf;

    constructor(address factory_, address finalizationExecutor_) {
        if (factory_ == address(0)) revert ZeroFactory();
        if (finalizationExecutor_.code.length == 0) revert ZeroFinalizationExecutor();
        address pancakeFactory_ = ILpTemplateExecutor(finalizationExecutor_).factory();
        address wbnb_ = ILpTemplateExecutor(finalizationExecutor_).wbnb();
        if (pancakeFactory_.code.length == 0) revert InvalidDependency(pancakeFactory_);
        if (wbnb_.code.length == 0) revert InvalidDependency(wbnb_);
        factory = factory_;
        finalizationExecutor = finalizationExecutor_;
        pancakeFactory = pancakeFactory_;
        wbnb = wbnb_;
        executorCodehash = finalizationExecutor_.codehash;
        pancakeFactoryCodehash = pancakeFactory_.codehash;
        wbnbCodehash = wbnb_.codehash;
        companionDeployer = new LpRewardCompanionDeployer();
    }

    function deploy(address creator, bytes calldata commonConfig, bytes calldata templateConfig)
        external
        returns (address token, address vault)
    {
        if (msg.sender != factory) revert UnauthorizedFactory(msg.sender);
        _validateCurrentDependencies();
        LaunchTypes.CommonConfig memory common = abi.decode(commonConfig, (LaunchTypes.CommonConfig));
        if (keccak256(commonConfig) != keccak256(abi.encode(common))) revert InvalidCommonConfigEncoding();
        (StandardConfig memory launch, LpRewardsConfig memory rewards) =
            abi.decode(templateConfig, (StandardConfig, LpRewardsConfig));
        if (keccak256(templateConfig) != keccak256(abi.encode(launch, rewards))) {
            revert InvalidTemplateConfigEncoding();
        }
        _validateLaunch(launch);
        if (common.rewardToken.code.length == 0) revert InvalidRewardToken(common.rewardToken);
        if (rewards.lpToken == address(0)) revert InvalidLpToken(rewards.lpToken);
        if (rewards.minimumEligibleBalance == 0) revert InvalidMinimumEligibleBalance();

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
        RewardTemplateTypes.LpPairConfig memory pairConfig = RewardTemplateTypes.LpPairConfig({
            expectedLpToken: rewards.lpToken,
            minimumEligibleBalance: rewards.minimumEligibleBalance,
            pancakeFactory: pancakeFactory,
            wbnb: wbnb,
            factoryCodehash: pancakeFactoryCodehash,
            wbnbCodehash: wbnbCodehash
        });
        LpRewardMintVault deployed =
            new LpRewardMintVault(mintConfig, companionDeployer, common.rewardToken, pairConfig);
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

    function _checkCodehash(address dependency, bytes32 expected) private view {
        bytes32 actual = dependency.codehash;
        if (actual != expected) revert UnexpectedDependencyCodehash(dependency, expected, actual);
    }

    function _validateCurrentDependencies() private view {
        _checkCodehash(finalizationExecutor, executorCodehash);
        _checkCodehash(pancakeFactory, pancakeFactoryCodehash);
        _checkCodehash(wbnb, wbnbCodehash);
        address currentFactory = ILpTemplateExecutor(finalizationExecutor).factory();
        address currentWbnb = ILpTemplateExecutor(finalizationExecutor).wbnb();
        if (currentFactory != pancakeFactory || currentWbnb != wbnb) {
            revert UnexpectedExecutorRoute(pancakeFactory, currentFactory, wbnb, currentWbnb);
        }
    }
}
