// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {MintVault} from "../vaults/MintVault.sol";

contract StandardTemplateV1 is ITemplate {
    struct StandardConfig {
        uint32 totalShares;
        uint96 pricePerShare;
        uint16 claimTokenBps;
        uint256 minimumLiquidityOutput;
    }

    error InvalidCommonConfigEncoding();
    error InvalidStandardConfigEncoding();
    error InvalidTotalShares();
    error InvalidPricePerShare();
    error InvalidClaimTokenBps(uint16 claimTokenBps);
    error InvalidMinimumLiquidityOutput();
    error UnauthorizedFactory(address caller);
    error ZeroFactory();
    error ZeroFinalizationExecutor();

    address public immutable factory;
    address public immutable finalizationExecutor;

    constructor(address factory_, address finalizationExecutor_) {
        if (factory_ == address(0)) revert ZeroFactory();
        if (finalizationExecutor_ == address(0)) revert ZeroFinalizationExecutor();
        factory = factory_;
        finalizationExecutor = finalizationExecutor_;
    }

    function deploy(address creator, bytes calldata commonConfig, bytes calldata templateConfig)
        external
        returns (address token, address vault)
    {
        if (msg.sender != factory) revert UnauthorizedFactory(msg.sender);

        LaunchTypes.CommonConfig memory common = abi.decode(commonConfig, (LaunchTypes.CommonConfig));
        if (keccak256(commonConfig) != keccak256(abi.encode(common))) revert InvalidCommonConfigEncoding();

        StandardConfig memory standard = abi.decode(templateConfig, (StandardConfig));
        if (keccak256(templateConfig) != keccak256(abi.encode(standard))) revert InvalidStandardConfigEncoding();
        if (standard.totalShares == 0) revert InvalidTotalShares();
        if (standard.pricePerShare == 0) revert InvalidPricePerShare();
        if (standard.claimTokenBps == 0 || standard.claimTokenBps >= 10_000) {
            revert InvalidClaimTokenBps(standard.claimTokenBps);
        }
        if (standard.minimumLiquidityOutput == 0) revert InvalidMinimumLiquidityOutput();

        uint256 scaledSupply = common.supply * 1 ether;
        uint256 claimTokenAllocation = scaledSupply * standard.claimTokenBps / 10_000;
        uint256 launchTokenAllocation = scaledSupply - claimTokenAllocation;
        MintVault deployedVault = new MintVault(
            creator,
            finalizationExecutor,
            common.name,
            common.symbol,
            claimTokenAllocation,
            launchTokenAllocation,
            standard.minimumLiquidityOutput,
            standard.totalShares,
            standard.pricePerShare
        );
        token = address(deployedVault.token());
        vault = address(deployedVault);
    }
}
