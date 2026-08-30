// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFlapAdapter {
    struct LaunchRequest {
        uint8 poolKind;
        address poolAsset;
        bytes32 metadataHash;
        uint256 minimumPurchased;
        uint256 deadline;
        uint64 protectionDuration;
    }

    struct LaunchResult {
        address token;
        address pair;
        uint256 purchasedAmount;
        uint256 nativeSpent;
    }
    function execute(LaunchRequest calldata request) external payable returns (LaunchResult memory result);
}

interface IFlapProtocol {
    function launch(IFlapAdapter.LaunchRequest calldata request, address recipient)
        external
        payable
        returns (address token, address pair, uint256 purchasedAmount);
}
