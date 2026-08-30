// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRewardToken, RewardVault} from "./RewardVault.sol";

contract LpRewardVault {
    error InvalidLpToken(address token);
    error InvalidMinimumEligibleBalance();
    error ReentrantCall();
    error RewardAmountMismatch(uint256 expected, uint256 actual);
    error SelfReferentialRewardToken(address token);
    error TokenOperationFailed();
    error UnexpectedLpTokenCodehash(bytes32 expected, bytes32 actual);

    event LpWeightSynced(
        address indexed account, uint256 lpBalance, uint256 oldWeight, uint256 newWeight, uint256 syncedAt
    );

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IRewardToken public immutable rewardToken;
    IRewardToken public immutable lpToken;
    uint256 public immutable minimumEligibleBalance;
    bytes32 public immutable lpTokenCodehash;
    RewardVault public immutable rewardAccounting;

    mapping(address account => uint256 balance) public lastSyncedBalance;
    mapping(address account => uint256 timestamp) public lastSyncedAt;

    bool private entered;

    constructor(address rewardToken_, address lpToken_, uint256 minimumEligibleBalance_) {
        if (lpToken_.code.length == 0) revert InvalidLpToken(lpToken_);
        if (rewardToken_ == lpToken_) revert SelfReferentialRewardToken(lpToken_);
        if (minimumEligibleBalance_ == 0) revert InvalidMinimumEligibleBalance();
        rewardToken = IRewardToken(rewardToken_);
        lpToken = IRewardToken(lpToken_);
        minimumEligibleBalance = minimumEligibleBalance_;
        lpTokenCodehash = lpToken_.codehash;
        rewardAccounting = new RewardVault(rewardToken_, address(this), RewardVault.AccessMode.ControllerOnly);
    }

    function syncWeight(address account) public returns (uint256 newWeight) {
        bytes32 currentCodehash = address(lpToken).codehash;
        if (currentCodehash != lpTokenCodehash) {
            revert UnexpectedLpTokenCodehash(lpTokenCodehash, currentCodehash);
        }
        uint256 balance = lpToken.balanceOf(account);
        bool eligibleAccount = account != address(0) && account != DEAD && account != address(this)
            && account != address(rewardAccounting);
        newWeight = eligibleAccount && balance >= minimumEligibleBalance ? balance : 0;
        uint256 oldWeight = rewardAccounting.weightOf(account);
        rewardAccounting.setWeight(account, newWeight);
        lastSyncedBalance[account] = balance;
        lastSyncedAt[account] = block.timestamp;
        emit LpWeightSynced(account, balance, oldWeight, newWeight, block.timestamp);
    }

    function fundRewards(uint256 amount) external {
        if (entered) revert ReentrantCall();
        entered = true;
        _pullExact(msg.sender, amount);
        _safeApprove(address(rewardAccounting), amount);
        rewardAccounting.fundRewards(amount);
        if (_allowance(address(this), address(rewardAccounting)) != 0) revert TokenOperationFailed();
        entered = false;
    }

    function claimRewards() external returns (uint256 amount) {
        syncWeight(msg.sender);
        return rewardAccounting.claimRewardsFor(msg.sender);
    }

    function pendingRewards(address account) external view returns (uint256) {
        return rewardAccounting.pendingRewards(account);
    }

    function weightOf(address account) external view returns (uint256) {
        return rewardAccounting.weightOf(account);
    }

    function totalWeight() external view returns (uint256) {
        return rewardAccounting.totalWeight();
    }

    function totalFunded() external view returns (uint256) {
        return rewardAccounting.totalFunded();
    }

    function totalClaimed() external view returns (uint256) {
        return rewardAccounting.totalClaimed();
    }

    function _pullExact(address funder, uint256 amount) private {
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        _safeTransferFrom(funder, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert RewardAmountMismatch(amount, received);
    }

    function _allowance(address owner, address spender) private view returns (uint256 amount) {
        (bool success, bytes memory result) =
            address(rewardToken).staticcall(abi.encodeWithSignature("allowance(address,address)", owner, spender));
        if (!success || result.length != 32) revert TokenOperationFailed();
        return abi.decode(result, (uint256));
    }

    function _safeApprove(address spender, uint256 amount) private {
        (bool success, bytes memory result) =
            address(rewardToken).call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) revert TokenOperationFailed();
    }

    function _safeTransferFrom(address owner, address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(rewardToken).call(abi.encodeCall(IRewardToken.transferFrom, (owner, recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) revert TokenOperationFailed();
    }
}
