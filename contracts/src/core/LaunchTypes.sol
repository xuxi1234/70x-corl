// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library LaunchTypes {
    struct CommonConfig {
        string name;
        string symbol;
        uint256 supply;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        address receiver;
        address rewardToken;
        uint256 rewardThreshold;
        uint8 lpMode;
        uint16[4] allocationBps;
        bytes32 metadataHash;
    }
}
