// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILimitedToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract LaunchLimits {
    error InvalidController();
    error InvalidLimit(uint256 index, uint16 limitBps);
    error InvalidWindowCount(uint256 count);
    error InvalidWindowDuration(uint256 index, uint32 durationMinutes);
    error LimitsAlreadyActivated();
    error UnauthorizedController(address caller);
    error WalletLimitExceeded(address account, uint256 balance, uint256 maximum);

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public immutable controller;
    address public immutable token;
    address public immutable executor;
    uint64 public activatedAt;
    address public pair;
    uint32[] private durations;
    uint16[] private maximumWalletBps;

    constructor(
        address controller_,
        address token_,
        address executor_,
        uint32[] memory durations_,
        uint16[] memory limits_
    ) {
        if (controller_ == address(0) || token_.code.length == 0) {
            revert InvalidController();
        }
        if (durations_.length == 0 || durations_.length > 5 || durations_.length != limits_.length) {
            revert InvalidWindowCount(durations_.length);
        }
        uint16 previous;
        for (uint256 index; index < durations_.length; ++index) {
            if (durations_[index] == 0 || durations_[index] > 1_440) {
                revert InvalidWindowDuration(index, durations_[index]);
            }
            if (limits_[index] == 0 || limits_[index] > 10_000 || limits_[index] < previous) {
                revert InvalidLimit(index, limits_[index]);
            }
            previous = limits_[index];
            durations.push(durations_[index]);
            maximumWalletBps.push(limits_[index]);
        }
        controller = controller_;
        token = token_;
        executor = executor_;
    }

    function activate(address pair_) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (activatedAt != 0) revert LimitsAlreadyActivated();
        pair = pair_;
        activatedAt = uint64(block.timestamp);
    }

    function validateTransfer(address, address recipient) external view {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (activatedAt == 0 || _isExempt(recipient)) return;
        uint256 elapsed = block.timestamp - activatedAt;
        uint256 boundary;
        for (uint256 index; index < durations.length; ++index) {
            boundary += uint256(durations[index]) * 1 minutes;
            if (elapsed < boundary) {
                uint256 maximum = ILimitedToken(token).totalSupply() * maximumWalletBps[index] / 10_000;
                uint256 balance = ILimitedToken(token).balanceOf(recipient);
                if (balance > maximum) revert WalletLimitExceeded(recipient, balance, maximum);
                return;
            }
        }
    }

    function windowCount() external view returns (uint256) {
        return durations.length;
    }

    function window(uint256 index) external view returns (uint32 durationMinutes, uint16 limitBps) {
        return (durations[index], maximumWalletBps[index]);
    }

    function _isExempt(address account) private view returns (bool) {
        return
            account == address(0) || account == DEAD || account == controller || account == executor || account == pair;
    }
}
