// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {FlapMintVault} from "../vaults/FlapMintVault.sol";

contract FlapTemplateV1 is ITemplate {
    struct Config {
        uint256 goal;
        uint32 totalShares;
        bytes32 initialRoot;
        uint64 whitelistDeadline;
        uint64 protectionDuration;
    }
    error InvalidAdapter();
    error InvalidEncoding();
    error UnauthorizedFactory(address caller);
    bytes32 public constant TEMPLATE_ID = keccak256("FLAP_JOINT");
    uint32 public constant VERSION = 1;
    address public immutable factory;
    address public immutable adapter;
    event FlapVaultDeployed(
        address indexed creator, address indexed vault, address indexed adapter, bytes32 configHash
    );

    constructor(address factory_, address adapter_) {
        if (factory_ == address(0) || adapter_.code.length == 0) revert InvalidAdapter();
        factory = factory_;
        adapter = adapter_;
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
        if (
            common.supply != 1_000_000_000 || common.buyTaxBps != common.sellTaxBps || !_supportedTax(common.sellTaxBps)
                || common.receiver == address(0) || common.rewardToken != address(0) || common.lpMode != 0
        ) revert InvalidEncoding();
        FlapMintVault deployed = new FlapMintVault(
            creator,
            adapter,
            common,
            config.goal,
            config.totalShares,
            config.initialRoot,
            config.whitelistDeadline,
            config.protectionDuration
        );
        token = address(0);
        vault = address(deployed);
        emit FlapVaultDeployed(creator, vault, adapter, keccak256(abi.encode(common, config)));
    }

    function _supportedTax(uint16 taxRate) private pure returns (bool) {
        return taxRate == 100 || taxRate == 300 || taxRate == 500 || taxRate == 1_000;
    }
}
