// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFlapAdapter, IFlapProtocol} from "../interfaces/IFlapAdapter.sol";

interface IFlapBalance {
    function balanceOf(address account) external view returns (uint256);
}

contract FlapAdapterV1 is IFlapAdapter {
    error DeadlineExpired();
    error InvalidPoolAsset();
    error InvalidProtocol();
    error InvalidResult();
    error ProtocolCodeChanged();
    address public immutable protocol;
    bytes32 public immutable protocolCodehash;
    mapping(address asset => bool allowed) public isPoolAssetAllowed;

    constructor(address protocol_, address[] memory allowedAssets) {
        if (protocol_.code.length == 0) revert InvalidProtocol();
        protocol = protocol_;
        protocolCodehash = protocol_.codehash;
        for (uint256 index; index < allowedAssets.length; ++index) {
            if (allowedAssets[index].code.length == 0) revert InvalidPoolAsset();
            isPoolAssetAllowed[allowedAssets[index]] = true;
        }
    }

    function execute(LaunchRequest calldata request) external payable returns (LaunchResult memory result) {
        // forge-lint: disable-next-line(block-timestamp)
        if (request.deadline < block.timestamp) revert DeadlineExpired();
        if (protocol.codehash != protocolCodehash) revert ProtocolCodeChanged();
        if (request.poolKind == 0) {
            if (request.poolAsset != address(0)) revert InvalidPoolAsset();
        } else {
            if (request.poolKind > 2 || !isPoolAssetAllowed[request.poolAsset]) revert InvalidPoolAsset();
        }
        (address token, address pair, uint256 purchased) =
            IFlapProtocol(protocol).launch{value: msg.value}(request, msg.sender);
        if (
            token.code.length == 0 || pair.code.length == 0 || purchased < request.minimumPurchased
                || IFlapBalance(token).balanceOf(msg.sender) < purchased
        ) revert InvalidResult();
        result = LaunchResult(token, pair, purchased, msg.value);
    }
}
