// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {BuybackTemplateBaseV1, TrustedCompanionDeployers} from "./AutoBuybackTemplateV1.sol";
import {BuybackVault} from "../vaults/BuybackVault.sol";

contract TimedBuybackTemplateV1 is BuybackTemplateBaseV1 {
    struct StandardConfig {
        uint32 totalShares;
        uint96 pricePerShare;
        uint16 claimTokenBps;
        uint256 minimumLiquidityOutput;
    }

    struct TimedBuybackConfig {
        uint256 threshold;
        uint256 maxSpend;
        uint32 interval;
        uint16 maxSlippageBps;
    }

    error InvalidInterval(uint32 interval);
    error InvalidTemplateConfigEncoding();

    bytes32 public constant TEMPLATE_ID = "TIMED_BUYBACK";
    uint32 private constant MINIMUM_INTERVAL = 5 minutes;
    uint32 private constant MAXIMUM_INTERVAL = 30 days;

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
        (StandardConfig memory launch, TimedBuybackConfig memory buyback) =
            abi.decode(templateConfig, (StandardConfig, TimedBuybackConfig));
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
        if (buyback.interval < MINIMUM_INTERVAL || buyback.interval > MAXIMUM_INTERVAL) {
            revert InvalidInterval(buyback.interval);
        }
        BuybackVault.Config memory vaultConfig = BuybackVault.Config({
            targetToken: address(0),
            threshold: buyback.threshold,
            maxSpend: buyback.maxSpend,
            interval: buyback.interval,
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
