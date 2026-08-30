// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "./LaunchTypes.sol";

library ConfigHash {
    function hash(LaunchTypes.CommonConfig memory config) internal pure returns (bytes32) {
        return keccak256(abi.encode(config));
    }
}
