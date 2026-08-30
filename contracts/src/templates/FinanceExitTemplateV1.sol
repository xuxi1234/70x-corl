// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {StandardTemplateV1} from "./StandardTemplateV1.sol";
import {MintVault} from "../vaults/MintVault.sol";
import {FinanceVault} from "../vaults/FinanceVault.sol";

contract FinanceExitTemplateV1 is ITemplate {
    struct Config {
        StandardTemplateV1.StandardConfig launch;
        address supportedToken;
    }
    error InvalidEncoding();
    error InvalidLaunchConfig();
    error UnauthorizedFactory(address caller);
    address public immutable factory;
    address public immutable finalizationExecutor;
    bytes32 public constant TEMPLATE_ID = keccak256("FINANCE_EXIT");
    uint32 public constant VERSION = 1;
    mapping(address mintVault => address financeVault) public financeVaultOf;
    event FinanceCompanionDeployed(
        address indexed token, address indexed mintVault, address indexed financeVault, bytes32 configHash
    );

    constructor(address factory_, address executor_) {
        require(factory_ != address(0) && executor_.code.length != 0, "dependency");
        factory = factory_;
        finalizationExecutor = executor_;
    }

    function deploy(address creator, bytes calldata commonBytes, bytes calldata configBytes)
        external
        returns (address token, address vault)
    {
        if (msg.sender != factory) revert UnauthorizedFactory(msg.sender);
        LaunchTypes.CommonConfig memory common = abi.decode(commonBytes, (LaunchTypes.CommonConfig));
        Config memory config = abi.decode(configBytes, (Config));
        if (
            keccak256(commonBytes) != keccak256(abi.encode(common))
                || keccak256(configBytes) != keccak256(abi.encode(config))
        ) revert InvalidEncoding();
        _validate(config.launch);
        uint256 supply = common.supply * 1 ether;
        uint256 claimAllocation = supply * config.launch.claimTokenBps / 10_000;
        MintVault mintVault = new MintVault(
            creator,
            finalizationExecutor,
            common.name,
            common.symbol,
            claimAllocation,
            supply - claimAllocation,
            config.launch.minimumLiquidityOutput,
            config.launch.totalShares,
            config.launch.pricePerShare
        );
        FinanceVault financeVault = new FinanceVault(config.supportedToken);
        token = address(mintVault.token());
        vault = address(mintVault);
        financeVaultOf[vault] = address(financeVault);
        emit FinanceCompanionDeployed(token, vault, address(financeVault), keccak256(abi.encode(common, config)));
    }

    function _validate(StandardTemplateV1.StandardConfig memory config) private pure {
        if (
            config.totalShares == 0 || config.pricePerShare == 0 || config.claimTokenBps == 0
                || config.claimTokenBps >= 10_000 || config.minimumLiquidityOutput == 0
        ) revert InvalidLaunchConfig();
    }
}
