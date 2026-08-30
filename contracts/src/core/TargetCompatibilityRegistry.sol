// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "./Ownable2Step.sol";

contract TargetCompatibilityRegistry is Ownable2Step {
    error UnapprovedTargetCodehash(bytes32 codehash);

    event TargetCodehashApprovalChanged(bytes32 indexed codehash, bool approved);

    mapping(bytes32 codehash => bool approved) public isApprovedCodehash;

    constructor(address initialOwner) Ownable2Step(initialOwner) {}

    function setApprovedCodehash(bytes32 codehash, bool approved) external onlyOwner {
        isApprovedCodehash[codehash] = approved;
        emit TargetCodehashApprovalChanged(codehash, approved);
    }

    function requireApproved(bytes32 codehash) external view {
        if (!isApprovedCodehash[codehash]) revert UnapprovedTargetCodehash(codehash);
    }
}
