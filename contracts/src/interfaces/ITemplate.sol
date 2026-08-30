// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITemplate {
    function deploy(address creator, bytes calldata commonConfig, bytes calldata templateConfig)
        external
        returns (address token, address vault);
}
