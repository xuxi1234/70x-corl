// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {PancakeV2Adapter} from "../adapters/PancakeV2Adapter.sol";
import {BuybackTaxProcessor} from "../modules/BuybackTaxProcessor.sol";
import {RewardTemplateTypes} from "./RewardTemplateTypes.sol";
import {BuybackVault, IBuybackRouter} from "../vaults/BuybackVault.sol";
import {HolderDeadRewardVault} from "../vaults/HolderDeadRewardVault.sol";
import {MintVault} from "../vaults/MintVault.sol";

contract BuybackCompanionDeployer {
    function deploy(
        address router,
        address wbnb,
        BuybackVault.Config memory config,
        BuybackVault.TrustedDexConfig memory trusted
    ) external returns (BuybackVault vault) {
        vault = new BuybackVault(router, wbnb, config, trusted);
    }
}

contract BuybackRewardDeployer {
    function deploy(address rewardToken, address projectToken, address controller)
        external
        returns (HolderDeadRewardVault vault)
    {
        vault = new HolderDeadRewardVault(rewardToken, projectToken, controller, controller, 10_000, 0);
    }
}

contract BuybackLiquidityDeployer {
    error InvalidInfrastructure(address dependency);
    error InvalidLpMode(uint8 mode);

    address public immutable router;
    address public immutable wbnb;
    address public immutable lpAdapter;
    address public immutable locker;
    address public immutable factory;
    bytes32 public immutable routerCodehash;
    bytes32 public immutable factoryCodehash;
    bytes32 public immutable wbnbCodehash;
    bytes32 public immutable pairCodehash;
    bytes32 public immutable lpAdapterCodehash;

    constructor(
        address router_,
        address wbnb_,
        address lpAdapter_,
        address locker_,
        PancakeV2Adapter.TrustedDependencies memory trusted
    ) {
        router = router_;
        wbnb = wbnb_;
        lpAdapter = lpAdapter_;
        locker = locker_;
        factory = trusted.factory;
        routerCodehash = trusted.routerCodehash;
        factoryCodehash = trusted.factoryCodehash;
        wbnbCodehash = trusted.wbnbCodehash;
        pairCodehash = trusted.pairCodehash;
        lpAdapterCodehash = trusted.lpAdapterCodehash;
    }

    function deploy(uint8 mode, address beneficiary) external returns (PancakeV2Adapter adapter) {
        if (mode > uint8(PancakeV2Adapter.LpMode.Lock)) revert InvalidLpMode(mode);
        PancakeV2Adapter.LpMode lpMode = PancakeV2Adapter.LpMode(mode);
        bool burn = lpMode == PancakeV2Adapter.LpMode.Burn;
        PancakeV2Adapter.TrustedDependencies memory trusted = PancakeV2Adapter.TrustedDependencies({
            router: router,
            factory: factory,
            wbnb: wbnb,
            lpAdapter: lpAdapter,
            routerCodehash: routerCodehash,
            factoryCodehash: factoryCodehash,
            wbnbCodehash: wbnbCodehash,
            pairCodehash: pairCodehash,
            lpAdapterCodehash: lpAdapterCodehash
        });
        adapter = new PancakeV2Adapter(
            router,
            wbnb,
            lpAdapter,
            lpMode,
            burn ? address(0) : locker,
            burn ? address(0) : beneficiary,
            burn ? 0 : type(uint64).max,
            trusted
        );
    }
}

contract BuybackTaxProcessorDeployer {
    error InvalidInfrastructure(address dependency);

    BuybackRewardDeployer public immutable rewardDeployer;
    BuybackLiquidityDeployer public immutable liquidityDeployer;

    constructor(BuybackRewardDeployer rewardDeployer_, BuybackLiquidityDeployer liquidityDeployer_) {
        if (address(rewardDeployer_).code.length == 0) revert InvalidInfrastructure(address(rewardDeployer_));
        if (address(liquidityDeployer_).code.length == 0) revert InvalidInfrastructure(address(liquidityDeployer_));
        rewardDeployer = rewardDeployer_;
        liquidityDeployer = liquidityDeployer_;
    }

    function deploy(
        address token,
        address router_,
        address wbnb_,
        BuybackVault buybackVault,
        BuybackTaxProcessor.Config memory config,
        BuybackTaxProcessor.TrustedDexConfig memory trusted
    ) external returns (BuybackTaxProcessor processor) {
        processor = new BuybackTaxProcessor(token, router_, wbnb_, buybackVault, config, trusted);
    }

    function deployReward(address rewardToken, address projectToken, address controller)
        external
        returns (HolderDeadRewardVault vault)
    {
        vault = rewardDeployer.deploy(rewardToken, projectToken, controller);
    }

    function deployLiquidityAdapter(uint8 mode, address beneficiary) external returns (PancakeV2Adapter adapter) {
        adapter = liquidityDeployer.deploy(mode, beneficiary);
    }
}

struct TrustedCompanionDeployers {
    address buybackVaultDeployer;
    address taxProcessorDeployer;
    address projectDeployer;
    bytes32 buybackVaultDeployerCodehash;
    bytes32 taxProcessorDeployerCodehash;
    bytes32 projectDeployerCodehash;
}

struct BuybackProjectDeploymentConfig {
    address router;
    address wbnb;
    BuybackVault.Config buyback;
    BuybackVault.TrustedDexConfig trusted;
    LaunchTypes.CommonConfig common;
    bytes32 fullConfigHash;
}

contract BuybackMintVault is MintVault {
    BuybackVault public immutable buybackVault;
    BuybackTaxProcessor public immutable taxProcessor;
    HolderDeadRewardVault public immutable holderRewardVault;
    bytes32 public immutable fullConfigHash;

    constructor(
        RewardTemplateTypes.MintDeploymentConfig memory config,
        BuybackCompanionDeployer companionDeployer,
        BuybackTaxProcessorDeployer taxProcessorDeployer,
        BuybackProjectDeploymentConfig memory project
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
        if (project.buyback.targetToken == address(0)) {
            project.buyback.targetToken = address(token);
        }
        project.buyback.controller = address(this);
        project.buyback.fullConfigHash = project.fullConfigHash;
        buybackVault = companionDeployer.deploy(project.router, project.wbnb, project.buyback, project.trusted);
        address rewardVaultAsset =
            project.common.rewardToken.code.length == 0 ? address(token) : project.common.rewardToken;
        holderRewardVault = taxProcessorDeployer.deployReward(rewardVaultAsset, address(token), address(this));
        PancakeV2Adapter liquidityAdapter =
            taxProcessorDeployer.deployLiquidityAdapter(project.common.lpMode, project.common.receiver);
        BuybackTaxProcessor.Config memory taxConfig = BuybackTaxProcessor.Config({
            receiver: project.common.receiver,
            rewardAsset: project.common.rewardToken,
            rewardThreshold: project.common.rewardThreshold,
            allocationBps: project.common.allocationBps,
            maxSlippageBps: project.buyback.maxSlippageBps,
            controller: address(this),
            quoteController: project.buyback.quoteController,
            fullConfigHash: project.fullConfigHash,
            holderRewardVault: address(holderRewardVault),
            liquidityAdapter: address(liquidityAdapter)
        });
        BuybackTaxProcessor.TrustedDexConfig memory taxTrusted = BuybackTaxProcessor.TrustedDexConfig({
            router: project.trusted.router,
            factory: project.trusted.factory,
            wbnb: project.trusted.wbnb,
            routerCodehash: project.trusted.routerCodehash,
            factoryCodehash: project.trusted.factoryCodehash,
            wbnbCodehash: project.trusted.wbnbCodehash,
            pairCodehash: project.trusted.pairCodehash
        });
        taxProcessor = taxProcessorDeployer.deploy(
            address(token), project.router, project.wbnb, buybackVault, taxConfig, taxTrusted
        );
        holderRewardVault.excludeAccount(address(buybackVault));
        holderRewardVault.excludeAccount(address(taxProcessor));
        holderRewardVault.excludeAccount(address(liquidityAdapter));
        token.setTaxExempt(address(liquidityAdapter), true);
        buybackVault.setFunder(address(taxProcessor));
        token.setProjectConfigHash(project.fullConfigHash);
        token.configureTax(address(taxProcessor), project.common.buyTaxBps, project.common.sellTaxBps);
        fullConfigHash = project.fullConfigHash;
    }

    function _onLiquidityTokenSet(address liquidityToken_) internal override {
        taxProcessor.activatePair(liquidityToken_);
        token.activateTax(liquidityToken_);
        if (address(buybackVault.targetToken()) == address(token)) buybackVault.activatePair(liquidityToken_);
        holderRewardVault.onLiquidityTokenSet(liquidityToken_);
        if (buybackVault.interval() != 0) buybackVault.activateSchedule();
    }

    function _onTaxCollected(uint256 amount) internal override {
        taxProcessor.recordTax(amount);
    }

    function _onTokenTransfer(address from, address to, uint256 amount) internal override {
        holderRewardVault.onTokenTransfer(from, to, amount);
    }
}

contract BuybackProjectDeployer {
    function deploy(
        RewardTemplateTypes.MintDeploymentConfig memory config,
        BuybackCompanionDeployer companionDeployer,
        BuybackTaxProcessorDeployer taxProcessorDeployer,
        BuybackProjectDeploymentConfig memory project
    ) external returns (BuybackMintVault vault) {
        vault = new BuybackMintVault(config, companionDeployer, taxProcessorDeployer, project);
    }
}

abstract contract BuybackTemplateBaseV1 is ITemplate {
    struct BaseStandardConfig {
        uint32 totalShares;
        uint96 pricePerShare;
        uint16 claimTokenBps;
        uint256 minimumLiquidityOutput;
    }

    error InvalidClaimTokenBps(uint16 claimTokenBps);
    error InvalidCommonConfigEncoding();
    error InvalidController();
    error InvalidMaximumSpend();
    error InvalidMinimumLiquidityOutput();
    error InvalidPricePerShare();
    error InvalidSlippage(uint16 slippageBps);
    error InvalidThreshold();
    error InvalidTotalShares();
    error UnauthorizedFactory(address caller);
    error UnexpectedDependencyCodehash(address dependency, bytes32 expected, bytes32 actual);
    error UnexpectedRouterRoute(
        address expectedFactory, address actualFactory, address expectedWbnb, address actualWbnb
    );
    error UntrustedDependency(address provided, address expected);
    error ZeroFactory();
    error ZeroFinalizationExecutor();

    event BuybackCompanionDeployed(
        bytes32 indexed templateId,
        uint32 indexed version,
        address indexed token,
        address mintVault,
        address buybackVault,
        bytes32 fullConfigHash
    );
    event BuybackTaxInfrastructureDeployed(
        address indexed token,
        address indexed mintVault,
        address indexed taxProcessor,
        address holderRewardVault,
        address liquidityAdapter,
        bytes32 fullConfigHash
    );

    uint32 public constant VERSION = 1;
    uint256 internal constant TOTAL_BPS = 10_000;

    address public immutable factory;
    address public immutable finalizationExecutor;
    address public immutable pancakeRouter;
    address public immutable pancakeFactory;
    address public immutable wbnb;
    address public immutable quoteController;
    address public immutable targetRegistry;
    bytes32 public immutable executorCodehash;
    bytes32 public immutable routerCodehash;
    bytes32 public immutable pancakeFactoryCodehash;
    bytes32 public immutable wbnbCodehash;
    bytes32 public immutable pairCodehash;
    bytes32 public immutable targetRegistryCodehash;
    BuybackCompanionDeployer public immutable companionDeployer;
    BuybackTaxProcessorDeployer public immutable taxProcessorDeployer;
    BuybackProjectDeployer public immutable projectDeployer;
    bytes32 public immutable companionDeployerCodehash;
    bytes32 public immutable taxProcessorDeployerCodehash;
    bytes32 public immutable projectDeployerCodehash;
    mapping(address mintVault => address companion) public buybackVaultOf;
    mapping(address mintVault => bytes32 fullConfigHash) public fullConfigHashOf;

    constructor(
        address factory_,
        address finalizationExecutor_,
        address router_,
        address wbnb_,
        address quoteController_,
        TrustedCompanionDeployers memory trustedDeployers,
        BuybackVault.TrustedDexConfig memory trusted
    ) {
        if (factory_ == address(0)) revert ZeroFactory();
        if (finalizationExecutor_.code.length == 0) revert ZeroFinalizationExecutor();
        if (quoteController_ == address(0)) revert InvalidController();
        _validateTrustedDependency(router_, trusted.router, trusted.routerCodehash);
        _validateTrustedDependency(wbnb_, trusted.wbnb, trusted.wbnbCodehash);
        IBuybackRouter routerContract = IBuybackRouter(router_);
        address actualFactory = routerContract.factory();
        address actualWbnb = routerContract.WETH();
        if (actualFactory != trusted.factory || actualWbnb != wbnb_) {
            revert UnexpectedRouterRoute(trusted.factory, actualFactory, wbnb_, actualWbnb);
        }
        _validateTrustedDependency(actualFactory, trusted.factory, trusted.factoryCodehash);
        _validateTrustedDependency(trusted.targetRegistry, trusted.targetRegistry, trusted.targetRegistryCodehash);
        _validateTrustedDependency(
            trustedDeployers.buybackVaultDeployer,
            trustedDeployers.buybackVaultDeployer,
            trustedDeployers.buybackVaultDeployerCodehash
        );
        _validateTrustedDependency(
            trustedDeployers.taxProcessorDeployer,
            trustedDeployers.taxProcessorDeployer,
            trustedDeployers.taxProcessorDeployerCodehash
        );
        _validateTrustedDependency(
            trustedDeployers.projectDeployer, trustedDeployers.projectDeployer, trustedDeployers.projectDeployerCodehash
        );
        if (trusted.pairCodehash == bytes32(0)) {
            revert UnexpectedDependencyCodehash(address(0), bytes32(uint256(1)), bytes32(0));
        }

        factory = factory_;
        finalizationExecutor = finalizationExecutor_;
        pancakeRouter = router_;
        pancakeFactory = actualFactory;
        wbnb = wbnb_;
        quoteController = quoteController_;
        targetRegistry = trusted.targetRegistry;
        executorCodehash = finalizationExecutor_.codehash;
        routerCodehash = trusted.routerCodehash;
        pancakeFactoryCodehash = trusted.factoryCodehash;
        wbnbCodehash = trusted.wbnbCodehash;
        pairCodehash = trusted.pairCodehash;
        targetRegistryCodehash = trusted.targetRegistryCodehash;
        companionDeployer = BuybackCompanionDeployer(trustedDeployers.buybackVaultDeployer);
        taxProcessorDeployer = BuybackTaxProcessorDeployer(trustedDeployers.taxProcessorDeployer);
        projectDeployer = BuybackProjectDeployer(trustedDeployers.projectDeployer);
        companionDeployerCodehash = trustedDeployers.buybackVaultDeployerCodehash;
        taxProcessorDeployerCodehash = trustedDeployers.taxProcessorDeployerCodehash;
        projectDeployerCodehash = trustedDeployers.projectDeployerCodehash;
    }

    function _decodeCommon(bytes calldata commonConfig) internal pure returns (LaunchTypes.CommonConfig memory common) {
        common = abi.decode(commonConfig, (LaunchTypes.CommonConfig));
        if (keccak256(commonConfig) != keccak256(abi.encode(common))) revert InvalidCommonConfigEncoding();
    }

    function _requireFactory() internal view {
        if (msg.sender != factory) revert UnauthorizedFactory(msg.sender);
    }

    function _validateDeployment(
        BaseStandardConfig memory launch,
        uint256 threshold_,
        uint256 maxSpend_,
        uint16 slippage
    ) internal view {
        _validateCurrentDependencies();
        if (launch.totalShares == 0) revert InvalidTotalShares();
        if (launch.pricePerShare == 0) revert InvalidPricePerShare();
        if (launch.claimTokenBps == 0 || launch.claimTokenBps >= TOTAL_BPS) {
            revert InvalidClaimTokenBps(launch.claimTokenBps);
        }
        if (launch.minimumLiquidityOutput == 0) revert InvalidMinimumLiquidityOutput();
        if (threshold_ == 0) revert InvalidThreshold();
        if (maxSpend_ == 0) revert InvalidMaximumSpend();
        if (slippage >= TOTAL_BPS) revert InvalidSlippage(slippage);
    }

    function _deployProject(
        address creator,
        LaunchTypes.CommonConfig memory common,
        BaseStandardConfig memory launch,
        BuybackVault.Config memory buybackConfig,
        bytes32 templateId,
        bytes32 fullConfigHash
    ) internal returns (address token, address vault) {
        uint256 scaledSupply = common.supply * 1 ether;
        uint256 claimAllocation = scaledSupply * launch.claimTokenBps / TOTAL_BPS;
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
        BuybackProjectDeploymentConfig memory project = BuybackProjectDeploymentConfig({
            router: pancakeRouter,
            wbnb: wbnb,
            buyback: buybackConfig,
            trusted: _trustedDexConfig(),
            common: common,
            fullConfigHash: fullConfigHash
        });
        BuybackMintVault deployed = projectDeployer.deploy(mintConfig, companionDeployer, taxProcessorDeployer, project);
        token = address(deployed.token());
        vault = address(deployed);
        address companion = address(deployed.buybackVault());
        buybackVaultOf[vault] = companion;
        fullConfigHashOf[vault] = fullConfigHash;
        emit BuybackCompanionDeployed(templateId, VERSION, token, vault, companion, fullConfigHash);
        BuybackTaxProcessor processor = deployed.taxProcessor();
        emit BuybackTaxInfrastructureDeployed(
            token,
            vault,
            address(processor),
            address(deployed.holderRewardVault()),
            address(processor.liquidityAdapter()),
            fullConfigHash
        );
    }

    function _trustedDexConfig() private view returns (BuybackVault.TrustedDexConfig memory trusted) {
        trusted = BuybackVault.TrustedDexConfig({
            router: pancakeRouter,
            factory: pancakeFactory,
            wbnb: wbnb,
            targetRegistry: targetRegistry,
            routerCodehash: routerCodehash,
            factoryCodehash: pancakeFactoryCodehash,
            wbnbCodehash: wbnbCodehash,
            pairCodehash: pairCodehash,
            targetRegistryCodehash: targetRegistryCodehash
        });
    }

    function _validateCurrentDependencies() private view {
        _validateCurrentDependency(finalizationExecutor, executorCodehash);
        _validateCurrentDependency(pancakeRouter, routerCodehash);
        _validateCurrentDependency(pancakeFactory, pancakeFactoryCodehash);
        _validateCurrentDependency(wbnb, wbnbCodehash);
        _validateCurrentDependency(targetRegistry, targetRegistryCodehash);
        _validateCurrentDependency(address(companionDeployer), companionDeployerCodehash);
        _validateCurrentDependency(address(taxProcessorDeployer), taxProcessorDeployerCodehash);
        _validateCurrentDependency(address(projectDeployer), projectDeployerCodehash);
        address actualFactory = IBuybackRouter(pancakeRouter).factory();
        address actualWbnb = IBuybackRouter(pancakeRouter).WETH();
        if (actualFactory != pancakeFactory || actualWbnb != wbnb) {
            revert UnexpectedRouterRoute(pancakeFactory, actualFactory, wbnb, actualWbnb);
        }
    }

    function _validateTrustedDependency(address provided, address expected, bytes32 expectedCodehash) private view {
        if (provided != expected) revert UntrustedDependency(provided, expected);
        _validateCurrentDependency(provided, expectedCodehash);
    }

    function _validateCurrentDependency(address dependency, bytes32 expectedCodehash) private view {
        bytes32 actual = dependency.codehash;
        if (actual != expectedCodehash) {
            revert UnexpectedDependencyCodehash(dependency, expectedCodehash, actual);
        }
    }
}

contract AutoBuybackTemplateV1 is BuybackTemplateBaseV1 {
    struct StandardConfig {
        uint32 totalShares;
        uint96 pricePerShare;
        uint16 claimTokenBps;
        uint256 minimumLiquidityOutput;
    }

    struct AutoBuybackConfig {
        uint256 threshold;
        uint256 maxSpend;
        uint16 maxSlippageBps;
    }

    error InvalidTemplateConfigEncoding();

    bytes32 public constant TEMPLATE_ID = "AUTO_BUYBACK";

    constructor(
        address factory_,
        address finalizationExecutor_,
        address router_,
        address wbnb_,
        address quoteController_,
        TrustedCompanionDeployers memory trustedDeployers,
        BuybackVault.TrustedDexConfig memory trusted
    )
        BuybackTemplateBaseV1(
            factory_, finalizationExecutor_, router_, wbnb_, quoteController_, trustedDeployers, trusted
        )
    {}

    function deploy(address creator, bytes calldata commonConfig, bytes calldata templateConfig)
        external
        returns (address token, address vault)
    {
        _requireFactory();
        LaunchTypes.CommonConfig memory common = _decodeCommon(commonConfig);
        (StandardConfig memory launch, AutoBuybackConfig memory buyback) =
            abi.decode(templateConfig, (StandardConfig, AutoBuybackConfig));
        if (keccak256(templateConfig) != keccak256(abi.encode(launch, buyback))) {
            revert InvalidTemplateConfigEncoding();
        }
        BaseStandardConfig memory baseLaunch = BaseStandardConfig({
            totalShares: launch.totalShares,
            pricePerShare: launch.pricePerShare,
            claimTokenBps: launch.claimTokenBps,
            minimumLiquidityOutput: launch.minimumLiquidityOutput
        });
        _validateDeployment(baseLaunch, buyback.threshold, buyback.maxSpend, buyback.maxSlippageBps);
        BuybackVault.Config memory vaultConfig = BuybackVault.Config({
            targetToken: address(0),
            threshold: buyback.threshold,
            maxSpend: buyback.maxSpend,
            interval: 0,
            maxSlippageBps: buyback.maxSlippageBps,
            requireRouteAtCreation: false,
            requireTargetApproval: false,
            controller: address(0),
            quoteController: quoteController,
            fullConfigHash: bytes32(0)
        });
        return _deployProject(
            creator, common, baseLaunch, vaultConfig, TEMPLATE_ID, keccak256(abi.encode(common, launch, buyback))
        );
    }
}
