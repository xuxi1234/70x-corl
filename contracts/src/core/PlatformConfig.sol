// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "./Ownable2Step.sol";

contract PlatformConfig is Ownable2Step {
    error FeeExceedsMaximum(uint96 fee);
    error InvalidRevenueRecipient();

    event FeeChanged(uint96 oldFee, uint96 newFee);
    event RevenueRecipientChanged(address oldRecipient, address newRecipient);

    uint96 public constant MAX_FEE = 0.05 ether;

    uint96 public fee = 0.005 ether;
    address public revenueRecipient;

    constructor(address initialOwner, address initialRevenueRecipient) Ownable2Step(initialOwner) {
        if (initialRevenueRecipient == address(0)) revert InvalidRevenueRecipient();
        revenueRecipient = initialRevenueRecipient;
    }

    function setFee(uint96 newFee) external onlyOwner {
        if (newFee > MAX_FEE) revert FeeExceedsMaximum(newFee);

        uint96 oldFee = fee;
        fee = newFee;
        emit FeeChanged(oldFee, newFee);
    }

    function setRevenueRecipient(address newRevenueRecipient) external onlyOwner {
        if (newRevenueRecipient == address(0)) revert InvalidRevenueRecipient();

        address oldRevenueRecipient = revenueRecipient;
        revenueRecipient = newRevenueRecipient;
        emit RevenueRecipientChanged(oldRevenueRecipient, newRevenueRecipient);
    }
}
