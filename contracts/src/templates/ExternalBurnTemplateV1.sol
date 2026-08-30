// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {BuybackTemplateBaseV1, TrustedCompanionDeployers} from "./AutoBuybackTemplateV1.sol";
import {BuybackVault} from "../vaults/BuybackVault.sol";

contract ExternalBurnTemplateV1 is BuybackTemplateBaseV1 {
    struct StandardConfig {
        uint32 totalShares;
        uint96 pricePerShare;
        uint16 claimTokenBps;
        uint256 minimumLiquidityOutput;
    }

    struct ExternalBurnConfig {
        address targetToken;
        uint256 threshold;
        uint256 maxSpend;
        uint16 maxSlippageBps;
    }

    error InvalidExternalTarget(address targetToken);
    error InvalidTemplateConfigEncoding();

    bytes32 public constant TEMPLATE_ID = "EXTERNAL_BURN";

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
        (StandardConfig memory launch, ExternalBurnConfig memory buyback) =
            abi.decode(templateConfig, (StandardConfig, ExternalBurnConfig));
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
        if (buyback.targetToken.code.length == 0 || buyback.targetToken == wbnb) {
            revert InvalidExternalTarget(buyback.targetToken);
        }
        BuybackVault.Config memory vaultConfig = BuybackVault.Config({
            targetToken: buyback.targetToken,
            threshold: buyback.threshold,
            maxSpend: buyback.maxSpend,
            interval: 0,
            maxSlippageBps: buyback.maxSlippageBps,
            requireRouteAtCreation: true,
            requireTargetApproval: true,
            controller: address(0),
            quoteController: quoteController,
            fullConfigHash: bytes32(0)
        });
        return _deployProject(
            creator, common, baseLaunch, vaultConfig, TEMPLATE_ID, keccak256(abi.encode(common, launch, buyback))
        );
    }
}
