// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFlapAdapter {
    struct LaunchRequest {
        uint8 poolKind;
        address poolAsset;
        bytes32 salt;
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

interface IFlapLaunchConfig {
    function flapLaunchConfig()
        external
        view
        returns (
            string memory name,
            string memory symbol,
            bytes32 metadataHash,
            uint16 taxRate,
            address beneficiary,
            uint16[4] memory allocationBps,
            uint256 minimumShareBalance
        );
}

interface IFlapPortal {
    struct NewTokenV5Params {
        string name;
        string symbol;
        string meta;
        uint8 dexThresh;
        bytes32 salt;
        uint16 taxRate;
        uint8 migratorType;
        address quoteToken;
        uint256 quoteAmt;
        address beneficiary;
        bytes permitData;
        bytes32 extensionID;
        bytes extensionData;
        uint8 dexId;
        uint8 lpFeeProfile;
        uint64 taxDuration;
        uint64 antiFarmerDuration;
        uint16 mktBps;
        uint16 deflationBps;
        uint16 dividendBps;
        uint16 lpBps;
        uint256 minimumShareBalance;
    }

    function newTokenV5(NewTokenV5Params calldata params) external payable returns (address token);
}
