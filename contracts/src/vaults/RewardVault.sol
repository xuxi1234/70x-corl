// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IRewardToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);
}

contract RewardVault {
    enum AccessMode {
        Public,
        ControllerOnly
    }

    error DirectClaimDisabled();
    error InvalidController();
    error InvalidRewardToken(address token);
    error NoRewardWeight();
    error NothingToClaim();
    error ReentrantCall();
    error RewardAmountMismatch(uint256 expected, uint256 actual);
    error RewardDeliveryMismatch(uint256 expected, uint256 vaultSpent, uint256 recipientReceived);
    error TokenOperationFailed();
    error UnauthorizedController(address caller);

    event RewardFunded(address indexed funder, uint256 amount, uint256 rewardPerWeight);
    event RewardClaimed(address indexed account, uint256 amount);
    event WeightChanged(address indexed account, uint256 oldWeight, uint256 newWeight, uint256 totalWeight);

    uint256 public constant REWARD_SCALE = 1e36;

    IRewardToken public immutable rewardToken;
    address public immutable controller;
    AccessMode public immutable accessMode;

    uint256 public totalWeight;
    uint256 public rewardPerWeight;
    uint256 public scaledRemainder;
    uint256 public totalFunded;
    uint256 public totalClaimed;

    mapping(address account => uint256 amount) public weightOf;
    mapping(address account => uint256 value) public rewardPerWeightPaid;
    mapping(address account => uint256 value) public accruedRewardsScaled;

    bool private entered;

    constructor(address rewardToken_, address controller_, AccessMode accessMode_) {
        if (rewardToken_.code.length == 0) revert InvalidRewardToken(rewardToken_);
        if (controller_ == address(0)) revert InvalidController();
        rewardToken = IRewardToken(rewardToken_);
        controller = controller_;
        accessMode = accessMode_;
    }

    function setWeight(address account, uint256 newWeight) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        _settle(account);

        uint256 oldWeight = weightOf[account];
        totalWeight = totalWeight - oldWeight + newWeight;
        weightOf[account] = newWeight;
        emit WeightChanged(account, oldWeight, newWeight, totalWeight);
    }

    function fundRewards(uint256 amount) external {
        if (accessMode == AccessMode.ControllerOnly && msg.sender != controller) {
            revert UnauthorizedController(msg.sender);
        }
        if (entered) revert ReentrantCall();
        if (totalWeight == 0) revert NoRewardWeight();
        entered = true;

        uint256 balanceBefore = rewardToken.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert RewardAmountMismatch(amount, received);

        uint256 scaledFunding = amount * REWARD_SCALE + scaledRemainder;
        rewardPerWeight += scaledFunding / totalWeight;
        scaledRemainder = scaledFunding % totalWeight;
        totalFunded += amount;

        emit RewardFunded(msg.sender, amount, rewardPerWeight);
        entered = false;
    }

    function claimRewards() external returns (uint256 amount) {
        if (accessMode == AccessMode.ControllerOnly) revert DirectClaimDisabled();
        return _claimRewards(msg.sender);
    }

    function claimRewardsFor(address account) external returns (uint256 amount) {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        return _claimRewards(account);
    }

    function _claimRewards(address account) private returns (uint256 amount) {
        if (entered) revert ReentrantCall();
        entered = true;
        _settle(account);

        uint256 accruedScaled = accruedRewardsScaled[account];
        amount = accruedScaled / REWARD_SCALE;
        if (amount == 0) revert NothingToClaim();

        accruedRewardsScaled[account] = accruedScaled - amount * REWARD_SCALE;
        totalClaimed += amount;
        uint256 vaultBalanceBefore = rewardToken.balanceOf(address(this));
        uint256 recipientBalanceBefore = rewardToken.balanceOf(account);
        _safeTransfer(account, amount);
        uint256 vaultBalanceAfter = rewardToken.balanceOf(address(this));
        uint256 recipientBalanceAfter = rewardToken.balanceOf(account);
        uint256 vaultSpent = vaultBalanceBefore >= vaultBalanceAfter ? vaultBalanceBefore - vaultBalanceAfter : 0;
        uint256 recipientReceived =
            recipientBalanceAfter >= recipientBalanceBefore ? recipientBalanceAfter - recipientBalanceBefore : 0;
        if (vaultSpent != amount || recipientReceived != amount) {
            revert RewardDeliveryMismatch(amount, vaultSpent, recipientReceived);
        }

        emit RewardClaimed(account, amount);
        entered = false;
    }

    function pendingRewards(address account) external view returns (uint256) {
        uint256 scaled =
            accruedRewardsScaled[account] + weightOf[account] * (rewardPerWeight - rewardPerWeightPaid[account]);
        return scaled / REWARD_SCALE;
    }

    function _settle(address account) private {
        uint256 currentRewardPerWeight = rewardPerWeight;
        uint256 paid = rewardPerWeightPaid[account];
        if (currentRewardPerWeight != paid) {
            accruedRewardsScaled[account] += weightOf[account] * (currentRewardPerWeight - paid);
            rewardPerWeightPaid[account] = currentRewardPerWeight;
        }
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
}
