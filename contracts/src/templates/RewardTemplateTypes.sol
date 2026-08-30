// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library RewardTemplateTypes {
    struct MintDeploymentConfig {
        address creator;
        address executor;
        string name;
        string symbol;
        uint256 claimTokenAllocation;
        uint256 launchTokenAllocation;
        uint256 minimumLiquidityOutput;
        uint32 totalShares;
        uint96 pricePerShare;
    }

    struct LpPairConfig {
        address expectedLpToken;
        uint256 minimumEligibleBalance;
        address pancakeFactory;
        address wbnb;
        bytes32 factoryCodehash;
        bytes32 wbnbCodehash;
    }
}
