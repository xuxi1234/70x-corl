// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRewardToken, RewardVault} from "./RewardVault.sol";

interface IHolderToken {
    function balanceOf(address account) external view returns (uint256);
}

contract HolderDeadRewardVault {
    error InvalidController();
    error InvalidProjectToken(address token);
    error InvalidLiquidityToken(address token);
    error InvalidRewardSplit(uint256 totalBps);
    error NothingToClaim();
    error ReentrantCall();
    error RewardAmountMismatch(uint256 expected, uint256 actual);
    error RewardDeliveryMismatch(uint256 expected, uint256 vaultSpent, uint256 recipientReceived);
    error TokenOperationFailed();
    error UnauthorizedController(address caller);

    event HolderWeightSynced(address indexed account, uint256 oldWeight, uint256 newWeight);
    event AccountExcluded(address indexed account, uint256 removedWeight);
    event HolderDeadFunded(address indexed funder, uint256 amount, uint256 holderAmount, uint256 deadAmount);
    event LiquidityTokenExcluded(address indexed liquidityToken, uint256 removedWeight);

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 public constant TOTAL_BPS = 10_000;

    IRewardToken public immutable rewardToken;
    IHolderToken public immutable projectToken;
    address public immutable controller;
    uint16 public immutable holderBps;
    uint16 public immutable deadBps;
    RewardVault public immutable rewardAccounting;

    uint256 public totalFunded;
    uint256 public totalHolderFunded;
    uint256 public totalDeadDistributed;
    address public liquidityToken;
    mapping(address account => bool excluded) public isExcluded;

    bool private entered;

    constructor(
        address rewardToken_,
        address projectToken_,
        address controller_,
        address initialAccount,
        uint16 holderBps_,
        uint16 deadBps_
    ) {
        if (projectToken_.code.length == 0) revert InvalidProjectToken(projectToken_);
        if (controller_ == address(0)) revert InvalidController();
        uint256 totalBps = uint256(holderBps_) + deadBps_;
        if (totalBps != TOTAL_BPS) revert InvalidRewardSplit(totalBps);
        rewardToken = IRewardToken(rewardToken_);
        projectToken = IHolderToken(projectToken_);
        controller = controller_;
        holderBps = holderBps_;
        deadBps = deadBps_;
        RewardVault accounting = new RewardVault(rewardToken_, address(this), RewardVault.AccessMode.ControllerOnly);
        rewardAccounting = accounting;
        if (_eligible(initialAccount)) accounting.setWeight(initialAccount, projectToken.balanceOf(initialAccount));
    }

    function onTokenTransfer(address from, address to, uint256) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (from == to) return;
        if (_launchTransfersInFlight()) return;
        _syncHolder(from);
        _syncHolder(to);
    }

    function onLiquidityTokenSet(address liquidityToken_) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (
            liquidityToken != address(0) || liquidityToken_.code.length == 0 || liquidityToken_ == controller
                || liquidityToken_ == DEAD || _contextLiquidityToken() != liquidityToken_
        ) revert InvalidLiquidityToken(liquidityToken_);
        uint256 oldWeight = rewardAccounting.weightOf(liquidityToken_);
        liquidityToken = liquidityToken_;
        _syncHolder(liquidityToken_);
        emit LiquidityTokenExcluded(liquidityToken_, oldWeight);
    }

    function excludeAccount(address account) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (account == address(0) || isExcluded[account]) return;
        uint256 oldWeight = rewardAccounting.weightOf(account);
        isExcluded[account] = true;
        if (oldWeight != 0) rewardAccounting.setWeight(account, 0);
        emit AccountExcluded(account, oldWeight);
    }

    function fundRewards(uint256 amount) external {
        if (entered) revert ReentrantCall();
        entered = true;
        _pullExact(msg.sender, amount);

        uint256 deadAmount = amount * deadBps / TOTAL_BPS;
        uint256 holderAmount = amount - deadAmount;
        if (deadAmount != 0) _deliverExact(DEAD, deadAmount);
        if (holderAmount != 0) {
            _safeApprove(address(rewardAccounting), holderAmount);
            rewardAccounting.fundRewards(holderAmount);
            if (_allowance(address(this), address(rewardAccounting)) != 0) revert TokenOperationFailed();
        }

        totalFunded += amount;
        totalHolderFunded += holderAmount;
        totalDeadDistributed += deadAmount;
        emit HolderDeadFunded(msg.sender, amount, holderAmount, deadAmount);
        entered = false;
    }

    function claimRewards() external returns (uint256 amount) {
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

    function totalClaimed() external view returns (uint256) {
        return rewardAccounting.totalClaimed();
    }

    function _syncHolder(address account) private {
        uint256 newWeight = _eligible(account) ? projectToken.balanceOf(account) : 0;
        uint256 oldWeight = rewardAccounting.weightOf(account);
        rewardAccounting.setWeight(account, newWeight);
        emit HolderWeightSynced(account, oldWeight, newWeight);
    }

    function _eligible(address account) private view returns (bool) {
        return account != address(0) && account != DEAD && account != controller && account != address(this)
            && account != address(rewardAccounting) && account != liquidityToken && !isExcluded[account];
    }

    function _pullExact(address funder, uint256 amount) private {
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        _safeTransferFrom(funder, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert RewardAmountMismatch(amount, received);
    }

    function _deliverExact(address recipient, uint256 amount) private {
        uint256 vaultBefore = rewardToken.balanceOf(address(this));
        uint256 recipientBefore = rewardToken.balanceOf(recipient);
        _safeTransfer(recipient, amount);
        uint256 vaultSpent = vaultBefore - rewardToken.balanceOf(address(this));
        uint256 recipientReceived = rewardToken.balanceOf(recipient) - recipientBefore;
        if (vaultSpent != amount || recipientReceived != amount) {
            revert RewardDeliveryMismatch(amount, vaultSpent, recipientReceived);
        }
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

    function _safeTransfer(address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(rewardToken).call(abi.encodeCall(IRewardToken.transfer, (recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) revert TokenOperationFailed();
    }

    function _safeTransferFrom(address owner, address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(rewardToken).call(abi.encodeCall(IRewardToken.transferFrom, (owner, recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) revert TokenOperationFailed();
    }

    function _launchTransfersInFlight() private view returns (bool) {
        (bool success, bytes memory result) = controller.staticcall(abi.encodeWithSignature("state()"));
        return success && result.length == 32 && abi.decode(result, (uint256)) == 2;
    }

    function _contextLiquidityToken() private view returns (address token) {
        (bool success, bytes memory result) = controller.staticcall(abi.encodeWithSignature("liquidityToken()"));
        if (success && result.length == 32) token = abi.decode(result, (address));
    }
}
