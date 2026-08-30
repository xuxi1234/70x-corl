// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFlapAdapter, IFlapLaunchConfig, IFlapPortal} from "../interfaces/IFlapAdapter.sol";

interface IFlapBalance {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
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
        (
            string memory name,
            string memory symbol,
            string memory meta,
            uint16 taxRate,
            address beneficiary,
            uint16[4] memory allocationBps,
            uint256 minimumShareBalance
        ) = IFlapLaunchConfig(msg.sender).flapLaunchConfig();
        IFlapPortal.NewTokenV5Params memory params = IFlapPortal.NewTokenV5Params({
            name: name,
            symbol: symbol,
            meta: meta,
            dexThresh: 0,
            salt: request.salt,
            taxRate: taxRate,
            migratorType: taxRate == 0 ? 0 : 1,
            quoteToken: address(0),
            quoteAmt: msg.value,
            beneficiary: beneficiary,
            permitData: "",
            extensionID: bytes32(0),
            extensionData: "",
            dexId: 0,
            lpFeeProfile: 0,
            taxDuration: 0,
            antiFarmerDuration: request.protectionDuration,
            mktBps: allocationBps[1],
            deflationBps: allocationBps[3],
            dividendBps: allocationBps[2],
            lpBps: allocationBps[0],
            minimumShareBalance: minimumShareBalance
        });
        address token = IFlapPortal(protocol).newTokenV5{value: msg.value}(params);
        if (token.code.length == 0) revert InvalidResult();
        uint256 purchased = IFlapBalance(token).balanceOf(address(this));
        if (purchased < request.minimumPurchased) revert InvalidResult();
        uint256 beforeRecipient = IFlapBalance(token).balanceOf(msg.sender);
        if (!IFlapBalance(token).transfer(msg.sender, purchased)) revert InvalidResult();
        if (IFlapBalance(token).balanceOf(msg.sender) - beforeRecipient != purchased) revert InvalidResult();
        result = LaunchResult(token, address(0), purchased, msg.value);
    }
}
