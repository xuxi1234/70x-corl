// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

abstract contract Ownable2Step {
    error InvalidOwner(address owner);
    error UnauthorizedAccount(address account);

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    address private _owner;
    address private _pendingOwner;

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert InvalidOwner(initialOwner);
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert UnauthorizedAccount(msg.sender);
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    function acceptOwnership() external {
        address sender = msg.sender;
        if (sender != _pendingOwner) revert UnauthorizedAccount(sender);

        address previousOwner = _owner;
        _owner = sender;
        delete _pendingOwner;
        emit OwnershipTransferred(previousOwner, sender);
    }
}
