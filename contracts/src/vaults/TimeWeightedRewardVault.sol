// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRewardToken} from "./RewardVault.sol";

interface ITimeWeightedToken {
    function balanceOf(address account) external view returns (uint256);
}

contract TimeWeightedRewardVault {
    struct Tranche {
        uint256 amount;
        uint64 receivedAt;
        uint256 paidRewardIndex;
        uint256 paidTimeRewardIndex;
    }

    struct ExpiryNode {
        uint64 expiry;
        address account;
    }

    error ExpiryCheckpointRequired(uint256 nextExpiry);
    error InvalidController();
    error InvalidGrowthDuration(uint32 duration);
    error InvalidInitialAccount();
    error InvalidMaximumMultiplier(uint16 multiplierBps);
    error InvalidLiquidityToken(address token);
    error InvalidProjectToken(address token);
    error NoRewardWeight();
    error NothingToClaim();
    error ReentrantCall();
    error RewardAmountMismatch(uint256 expected, uint256 actual);
    error RewardDeliveryMismatch(uint256 expected, uint256 vaultSpent, uint256 recipientReceived);
    error TokenOperationFailed();
    error TrackedBalanceInsufficient(address account, uint256 tracked, uint256 required);
    error UnauthorizedController(address caller);

    event ExpiryCheckpoint(uint256 indexed throughTimestamp, uint256 processedExpiries, bool caughtUp);
    event RewardClaimed(address indexed account, uint256 amount);
    event RewardFunded(address indexed funder, uint256 amount, uint256 rewardIndex);
    event LiquidityTokenExcluded(address indexed liquidityToken, uint256 removedWeight);
    event TranchesChanged(address indexed account, uint256 trackedBalance, uint256 weightedBalance);

    uint16 public constant BASE_MULTIPLIER_BPS = 10_000;
    uint16 public constant MAX_MULTIPLIER_BPS = 30_000;
    uint32 public constant MIN_GROWTH_DURATION = 1 days;
    uint32 public constant MAX_GROWTH_DURATION = 30 days;
    uint256 public constant MAX_ACTION_EXPIRIES = 64;
    uint256 public constant MAX_CHECKPOINT_EXPIRIES = 256;
    uint256 public constant MAX_CLAIM_TRANCHES = 256;
    uint256 public constant REWARD_SCALE = 1e36;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IRewardToken public immutable rewardToken;
    ITimeWeightedToken public immutable projectToken;
    address public immutable controller;
    uint16 public immutable maxMultiplierBps;
    uint32 public immutable growthDuration;
    uint256 public immutable growthBps;

    uint256 public totalWeightNumerator;
    uint256 public activeSlope;
    uint256 public lastCheckpoint;
    uint256 public rewardIndex;
    uint256 public timeRewardIndex;
    uint256 public scaledRemainder;
    uint256 public totalFunded;
    uint256 public totalClaimed;
    uint256 public processedExpiryCount;
    address public liquidityToken;

    ExpiryNode[] private _expiryHeap;
    mapping(address account => mapping(uint256 expiry => uint256 indexPlusOne)) private _expiryHeapIndex;
    mapping(address account => mapping(uint256 expiry => uint256 slope)) private _accountExpiringSlope;
    mapping(uint256 expiry => uint256 count) private _scheduledAtExpiry;
    mapping(uint256 expiry => uint256 slope) public expiringSlope;
    mapping(uint256 expiry => uint256 index) public rewardIndexAtExpiry;
    mapping(uint256 expiry => uint256 index) public timeRewardIndexAtExpiry;
    mapping(uint256 expiry => bool processed) public expiryProcessed;
    mapping(uint256 expiry => bool scheduled) public expiryScheduled;
    mapping(address account => mapping(uint256 expiry => bool processed)) private _accountExpiryProcessed;

    mapping(address account => mapping(uint256 index => Tranche tranche)) private _tranches;
    mapping(address account => uint256 index) private _trancheHead;
    mapping(address account => uint256 index) private _trancheTail;
    mapping(address account => uint256 index) private _claimCursor;

    mapping(address account => uint256 balance) public cappedBalance;
    mapping(address account => uint256 index) public cappedPaidRewardIndex;
    mapping(address account => uint256 amount) public accruedRewardsScaled;
    mapping(address account => uint256 balance) private _trackedBalance;
    mapping(address account => uint256 numerator) private _accountWeightNumerator;
    mapping(address account => uint256 slope) private _accountActiveSlope;
    mapping(address account => uint256 timestamp) private _accountLastCheckpoint;

    bool private entered;

    constructor(
        address rewardToken_,
        address projectToken_,
        address controller_,
        address initialAccount,
        uint16 maxMultiplierBps_,
        uint32 growthDuration_
    ) {
        if (projectToken_.code.length == 0) revert InvalidProjectToken(projectToken_);
        if (controller_ == address(0)) revert InvalidController();
        if (initialAccount == address(0)) revert InvalidInitialAccount();
        if (maxMultiplierBps_ < BASE_MULTIPLIER_BPS || maxMultiplierBps_ > MAX_MULTIPLIER_BPS) {
            revert InvalidMaximumMultiplier(maxMultiplierBps_);
        }
        if (growthDuration_ < MIN_GROWTH_DURATION || growthDuration_ > MAX_GROWTH_DURATION) {
            revert InvalidGrowthDuration(growthDuration_);
        }
        rewardToken = IRewardToken(rewardToken_);
        projectToken = ITimeWeightedToken(projectToken_);
        controller = controller_;
        maxMultiplierBps = maxMultiplierBps_;
        growthDuration = growthDuration_;
        growthBps = maxMultiplierBps_ - BASE_MULTIPLIER_BPS;
        lastCheckpoint = block.timestamp;

        uint256 initialBalance = projectToken.balanceOf(initialAccount);
        if (initialBalance != 0 && _eligible(initialAccount)) _addIncoming(initialAccount, initialBalance);
    }

    function checkpoint(uint256 maxExpiries) external returns (bool caughtUp) {
        uint256 bounded = maxExpiries > MAX_CHECKPOINT_EXPIRIES ? MAX_CHECKPOINT_EXPIRIES : maxExpiries;
        uint256 processed;
        (caughtUp, processed) = _checkpoint(bounded);
        emit ExpiryCheckpoint(lastCheckpoint, processed, caughtUp);
    }

    function onTokenTransfer(address from, address to, uint256 amount) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (entered) revert ReentrantCall();
        if (from == to || amount == 0) return;
        if (_launchTransfersInFlight()) return;
        _requireCurrentCheckpoint();
        if (_eligible(from)) _removeNewest(from, amount);
        if (_eligible(to)) _addIncoming(to, amount);
        emit TranchesChanged(from, trackedBalanceOf(from), weightedBalanceOf(from));
        emit TranchesChanged(to, trackedBalanceOf(to), weightedBalanceOf(to));
    }

    function onLiquidityTokenSet(address liquidityToken_) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (
            liquidityToken != address(0) || liquidityToken_.code.length == 0 || liquidityToken_ == controller
                || liquidityToken_ == DEAD || _contextLiquidityToken() != liquidityToken_
        ) revert InvalidLiquidityToken(liquidityToken_);
        _requireCurrentCheckpoint();
        uint256 removedWeight = weightedBalanceOf(liquidityToken_);
        uint256 tracked = trackedBalanceOf(liquidityToken_);
        if (tracked != 0) _removeNewest(liquidityToken_, tracked);
        liquidityToken = liquidityToken_;
        emit LiquidityTokenExcluded(liquidityToken_, removedWeight);
    }

    function fundRewards(uint256 amount) external {
        if (entered) revert ReentrantCall();
        entered = true;
        _requireCurrentCheckpoint();
        uint256 currentTotalWeight = totalWeightNumerator;
        if (currentTotalWeight == 0) revert NoRewardWeight();

        uint256 balanceBefore = rewardToken.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert RewardAmountMismatch(amount, received);

        uint256 scaledFunding = amount * REWARD_SCALE + scaledRemainder;
        uint256 increment = scaledFunding / currentTotalWeight;
        rewardIndex += increment;
        timeRewardIndex += block.timestamp * increment;
        scaledRemainder = scaledFunding % currentTotalWeight;
        totalFunded += amount;
        emit RewardFunded(msg.sender, amount, rewardIndex);
        entered = false;
    }

    function claimRewards() external returns (uint256 amount) {
        if (entered) revert ReentrantCall();
        entered = true;
        _requireCurrentCheckpoint();
        bool fullySettled = _settleAccountForClaim(msg.sender);
        uint256 accruedScaled = accruedRewardsScaled[msg.sender];
        amount = accruedScaled / REWARD_SCALE;
        if (amount == 0) {
            entered = false;
            if (!fullySettled) return 0;
            revert NothingToClaim();
        }
        accruedRewardsScaled[msg.sender] = accruedScaled - amount * REWARD_SCALE;
        totalClaimed += amount;

        uint256 vaultBefore = rewardToken.balanceOf(address(this));
        uint256 recipientBefore = rewardToken.balanceOf(msg.sender);
        _safeTransfer(msg.sender, amount);
        uint256 vaultSpent = vaultBefore - rewardToken.balanceOf(address(this));
        uint256 recipientReceived = rewardToken.balanceOf(msg.sender) - recipientBefore;
        if (vaultSpent != amount || recipientReceived != amount) {
            revert RewardDeliveryMismatch(amount, vaultSpent, recipientReceived);
        }
        emit RewardClaimed(msg.sender, amount);
        entered = false;
    }

    function pendingRewards(address account) external view returns (uint256) {
        uint256 currentIndex = rewardIndex;
        uint256 currentTimeIndex = timeRewardIndex;
        uint256 scaled = accruedRewardsScaled[account];
        uint256 capped = cappedBalance[account];
        if (capped != 0) {
            scaled += _cappedRewardScaled(capped, currentIndex - cappedPaidRewardIndex[account]);
        }
        uint256 tail = _trancheTail[account];
        for (uint256 index = _trancheHead[account]; index < tail; ++index) {
            scaled += _pendingTrancheScaled(account, _tranches[account][index], currentIndex, currentTimeIndex);
        }
        return scaled / REWARD_SCALE;
    }

    function weightedBalanceOf(address account) public view returns (uint256 weight) {
        uint256 numerator = _accountWeightNumerator[account];
        uint256 checkpointedAt = _accountLastCheckpoint[account];
        if (checkpointedAt != 0 && block.timestamp > checkpointedAt) {
            numerator += _accountActiveSlope[account] * (block.timestamp - checkpointedAt);
        }
        return numerator / (uint256(BASE_MULTIPLIER_BPS) * growthDuration);
    }

    function trackedBalanceOf(address account) public view returns (uint256) {
        return _trackedBalance[account];
    }

    function totalWeight() external view returns (uint256) {
        return totalWeightNumerator / (uint256(BASE_MULTIPLIER_BPS) * growthDuration);
    }

    function trancheCount(address account) public view returns (uint256) {
        return _trancheTail[account] - _trancheHead[account];
    }

    function trancheAt(address account, uint256 index)
        external
        view
        returns (uint256 amount, uint256 receivedAt, uint256 expiry)
    {
        if (index >= trancheCount(account)) revert();
        Tranche storage tranche = _tranches[account][_trancheHead[account] + index];
        return (tranche.amount, tranche.receivedAt, uint256(tranche.receivedAt) + growthDuration);
    }

    function expiryCount() external view returns (uint256) {
        return _expiryHeap.length;
    }

    function nextExpiry() external view returns (uint256) {
        return _expiryHeap.length == 0 ? 0 : _expiryHeap[0].expiry;
    }

    function _requireCurrentCheckpoint() private {
        (bool caughtUp,) = _checkpoint(MAX_ACTION_EXPIRIES);
        if (!caughtUp) revert ExpiryCheckpointRequired(_expiryHeap[0].expiry);
    }

    function _checkpoint(uint256 maxExpiries) private returns (bool caughtUp, uint256 processed) {
        uint256 currentTime = block.timestamp;
        while (_expiryHeap.length != 0 && _expiryHeap[0].expiry <= currentTime && processed < maxExpiries) {
            ExpiryNode memory node = _expiryHeap[0];
            uint256 expiry = node.expiry;
            address account = node.account;
            uint256 endingSlope = _accountExpiringSlope[account][expiry];

            _advanceGlobalWeight(expiry);
            _advanceAccountWeight(account, expiry);
            activeSlope -= endingSlope;
            _accountActiveSlope[account] -= endingSlope;
            expiringSlope[expiry] -= endingSlope;
            rewardIndexAtExpiry[expiry] = rewardIndex;
            timeRewardIndexAtExpiry[expiry] = timeRewardIndex;
            expiryProcessed[expiry] = true;
            _accountExpiryProcessed[account][expiry] = true;
            delete _accountExpiringSlope[account][expiry];
            _unscheduleExpiry(account, expiry);
            unchecked {
                ++processed;
                ++processedExpiryCount;
            }
        }
        caughtUp = _expiryHeap.length == 0 || _expiryHeap[0].expiry > currentTime;
        if (caughtUp) _advanceGlobalWeight(currentTime);
    }

    function _advanceGlobalWeight(uint256 timestamp) private {
        uint256 elapsed = timestamp - lastCheckpoint;
        if (elapsed != 0) {
            totalWeightNumerator += activeSlope * elapsed;
            lastCheckpoint = timestamp;
        }
    }

    function _advanceAccountWeight(address account, uint256 timestamp) private {
        uint256 checkpointedAt = _accountLastCheckpoint[account];
        if (checkpointedAt == 0) {
            _accountLastCheckpoint[account] = timestamp;
            return;
        }
        uint256 elapsed = timestamp - checkpointedAt;
        if (elapsed != 0) {
            _accountWeightNumerator[account] += _accountActiveSlope[account] * elapsed;
            _accountLastCheckpoint[account] = timestamp;
        }
    }

    function _settleAccountForClaim(address account) private returns (bool fullySettled) {
        uint256 currentIndex = rewardIndex;
        uint256 currentTimeIndex = timeRewardIndex;
        uint256 accrued = accruedRewardsScaled[account];
        uint256 capped = cappedBalance[account];
        if (capped != 0) {
            accrued += _cappedRewardScaled(capped, currentIndex - cappedPaidRewardIndex[account]);
            cappedPaidRewardIndex[account] = currentIndex;
        }

        uint256 head = _trancheHead[account];
        uint256 tail = _trancheTail[account];
        uint256 initialCount = tail - head;
        uint256 remainingWork = MAX_CLAIM_TRANCHES;
        while (head < tail && remainingWork != 0) {
            Tranche storage tranche = _tranches[account][head];
            uint256 expiry = uint256(tranche.receivedAt) + growthDuration;
            if (!_accountExpiryProcessed[account][expiry]) break;
            accrued += _pendingTrancheScaled(account, tranche, currentIndex, currentTimeIndex);
            capped += tranche.amount;
            delete _tranches[account][head];
            unchecked {
                ++head;
                --remainingWork;
            }
        }
        _trancheHead[account] = head;
        cappedBalance[account] = capped;
        if (capped != 0) cappedPaidRewardIndex[account] = currentIndex;

        if (head == tail) {
            _trancheHead[account] = 0;
            _trancheTail[account] = 0;
            _claimCursor[account] = 0;
            accruedRewardsScaled[account] = accrued;
            return initialCount <= MAX_CLAIM_TRANCHES;
        }

        uint256 cursor = initialCount <= MAX_CLAIM_TRANCHES ? head : _claimCursor[account];
        if (cursor < head || cursor >= tail) cursor = head;
        while (cursor < tail && remainingWork != 0) {
            Tranche storage tranche = _tranches[account][cursor];
            accrued += _pendingTrancheScaled(account, tranche, currentIndex, currentTimeIndex);
            tranche.paidRewardIndex = currentIndex;
            tranche.paidTimeRewardIndex = currentTimeIndex;
            unchecked {
                ++cursor;
                --remainingWork;
            }
        }
        accruedRewardsScaled[account] = accrued;
        _claimCursor[account] = cursor == tail ? head : cursor;
        return initialCount <= MAX_CLAIM_TRANCHES;
    }

    function _pendingTrancheScaled(
        address account,
        Tranche storage tranche,
        uint256 currentIndex,
        uint256 currentTimeIndex
    ) private view returns (uint256) {
        return _pendingTrancheAmountScaled(account, tranche, tranche.amount, currentIndex, currentTimeIndex);
    }

    function _pendingTrancheAmountScaled(
        address account,
        Tranche storage tranche,
        uint256 amount,
        uint256 currentIndex,
        uint256 currentTimeIndex
    ) private view returns (uint256 scaled) {
        uint256 expiry = uint256(tranche.receivedAt) + growthDuration;
        bool processed = _accountExpiryProcessed[account][expiry];
        uint256 activeEndIndex = processed ? rewardIndexAtExpiry[expiry] : currentIndex;
        uint256 activeEndTimeIndex = processed ? timeRewardIndexAtExpiry[expiry] : currentTimeIndex;
        uint256 indexDelta = activeEndIndex - tranche.paidRewardIndex;
        uint256 timeIndexDelta = activeEndTimeIndex - tranche.paidTimeRewardIndex;
        scaled = amount * uint256(BASE_MULTIPLIER_BPS) * growthDuration * indexDelta;
        if (growthBps != 0 && indexDelta != 0) {
            scaled += amount * growthBps * (timeIndexDelta - uint256(tranche.receivedAt) * indexDelta);
        }
        if (processed) scaled += _cappedRewardScaled(amount, currentIndex - activeEndIndex);
    }

    function _cappedRewardScaled(uint256 amount, uint256 indexDelta) private view returns (uint256) {
        return amount * uint256(maxMultiplierBps) * growthDuration * indexDelta;
    }

    function _removeNewest(address account, uint256 amount) private {
        uint256 tracked = _trackedBalance[account];
        if (tracked < amount) revert TrackedBalanceInsufficient(account, tracked, amount);
        _advanceAccountWeight(account, block.timestamp);

        uint256 remaining = amount;
        uint256 head = _trancheHead[account];
        uint256 tail = _trancheTail[account];
        uint256 currentIndex = rewardIndex;
        uint256 currentTimeIndex = timeRewardIndex;
        uint256 accrued = accruedRewardsScaled[account];
        while (remaining != 0 && tail > head) {
            uint256 index = tail - 1;
            Tranche storage tranche = _tranches[account][index];
            uint256 consumed = remaining < tranche.amount ? remaining : tranche.amount;
            accrued += _consumeTranche(account, tranche, consumed, currentIndex, currentTimeIndex);
            tracked -= consumed;
            remaining -= consumed;
            if (tranche.amount == 0) {
                delete _tranches[account][index];
                tail = index;
            }
        }

        if (remaining != 0) {
            uint256 capped = cappedBalance[account];
            accrued += _cappedRewardScaled(capped, currentIndex - cappedPaidRewardIndex[account]);
            cappedPaidRewardIndex[account] = currentIndex;
            cappedBalance[account] = capped - remaining;
            uint256 weightRemoved = remaining * uint256(maxMultiplierBps) * growthDuration;
            totalWeightNumerator -= weightRemoved;
            _accountWeightNumerator[account] -= weightRemoved;
            tracked -= remaining;
        }

        _trackedBalance[account] = tracked;
        accruedRewardsScaled[account] = accrued;
        _trancheTail[account] = tail;
        if (tail == head) {
            _trancheHead[account] = 0;
            _trancheTail[account] = 0;
            _claimCursor[account] = 0;
        } else if (_claimCursor[account] >= tail) {
            _claimCursor[account] = head;
        }
    }

    function _consumeTranche(
        address account,
        Tranche storage tranche,
        uint256 consumed,
        uint256 currentIndex,
        uint256 currentTimeIndex
    ) private returns (uint256 accrued) {
        uint256 expiry = uint256(tranche.receivedAt) + growthDuration;
        uint256 weightRemoved = _trancheWeightNumeratorAmount(consumed, tranche.receivedAt, block.timestamp);
        accrued = _pendingTrancheAmountScaled(account, tranche, consumed, currentIndex, currentTimeIndex);
        totalWeightNumerator -= weightRemoved;
        _accountWeightNumerator[account] -= weightRemoved;
        if (!_accountExpiryProcessed[account][expiry]) {
            uint256 slopeRemoved = consumed * growthBps;
            activeSlope -= slopeRemoved;
            _accountActiveSlope[account] -= slopeRemoved;
            expiringSlope[expiry] -= slopeRemoved;
            uint256 accountSlope = _accountExpiringSlope[account][expiry] - slopeRemoved;
            _accountExpiringSlope[account][expiry] = accountSlope;
            if (accountSlope == 0) _unscheduleExpiry(account, expiry);
        }
        tranche.amount -= consumed;
    }

    function _addIncoming(address account, uint256 amount) private {
        if (account == address(0) || amount == 0) return;
        _advanceAccountWeight(account, block.timestamp);

        uint256 baseWeight = amount * uint256(BASE_MULTIPLIER_BPS) * growthDuration;
        totalWeightNumerator += baseWeight;
        _accountWeightNumerator[account] += baseWeight;
        _trackedBalance[account] += amount;

        if (growthBps == 0) {
            uint256 capped = cappedBalance[account];
            if (capped != 0) {
                accruedRewardsScaled[
                    account
                ] += _cappedRewardScaled(capped, rewardIndex - cappedPaidRewardIndex[account]);
            }
            cappedBalance[account] = capped + amount;
            cappedPaidRewardIndex[account] = rewardIndex;
            return;
        }

        uint64 receivedAt = uint64(block.timestamp);
        uint256 expiry = block.timestamp + growthDuration;
        uint256 slopeAdded = amount * growthBps;
        activeSlope += slopeAdded;
        _accountActiveSlope[account] += slopeAdded;
        expiringSlope[expiry] += slopeAdded;
        _accountExpiringSlope[account][expiry] += slopeAdded;
        if (_expiryHeapIndex[account][expiry] == 0) _scheduleExpiry(account, expiry);

        uint256 head = _trancheHead[account];
        uint256 tail = _trancheTail[account];
        if (tail > head) {
            Tranche storage latest = _tranches[account][tail - 1];
            if (latest.receivedAt == receivedAt) {
                accruedRewardsScaled[account] += _pendingTrancheScaled(account, latest, rewardIndex, timeRewardIndex);
                latest.paidRewardIndex = rewardIndex;
                latest.paidTimeRewardIndex = timeRewardIndex;
                latest.amount += amount;
                return;
            }
        }
        _tranches[account][tail] = Tranche({
            amount: amount, receivedAt: receivedAt, paidRewardIndex: rewardIndex, paidTimeRewardIndex: timeRewardIndex
        });
        _trancheTail[account] = tail + 1;
    }

    function _trancheWeightNumeratorAmount(uint256 amount, uint256 receivedAt, uint256 timestamp)
        private
        view
        returns (uint256)
    {
        uint256 age = timestamp - receivedAt;
        if (age > growthDuration) age = growthDuration;
        return amount * (uint256(BASE_MULTIPLIER_BPS) * growthDuration + growthBps * age);
    }

    function _scheduleExpiry(address account, uint256 expiry) private {
        _expiryHeap.push(ExpiryNode({expiry: uint64(expiry), account: account}));
        uint256 index = _expiryHeap.length - 1;
        _expiryHeapIndex[account][expiry] = index + 1;
        unchecked {
            ++_scheduledAtExpiry[expiry];
        }
        expiryScheduled[expiry] = true;
        expiryProcessed[expiry] = false;
        _accountExpiryProcessed[account][expiry] = false;
        _siftExpiryUp(index);
    }

    function _unscheduleExpiry(address account, uint256 expiry) private {
        uint256 indexPlusOne = _expiryHeapIndex[account][expiry];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 last = _expiryHeap.length - 1;
        if (index != last) _swapExpiries(index, last);
        _expiryHeap.pop();
        delete _expiryHeapIndex[account][expiry];
        uint256 scheduledCount = _scheduledAtExpiry[expiry] - 1;
        _scheduledAtExpiry[expiry] = scheduledCount;
        if (scheduledCount == 0) expiryScheduled[expiry] = false;
        if (index == last) return;
        uint256 settledIndex = _siftExpiryDown(index);
        _siftExpiryUp(settledIndex);
    }

    function _siftExpiryUp(uint256 index) private {
        while (index != 0) {
            uint256 parent = (index - 1) / 2;
            if (!_expiryLess(_expiryHeap[index], _expiryHeap[parent])) return;
            _swapExpiries(parent, index);
            index = parent;
        }
    }

    function _siftExpiryDown(uint256 index) private returns (uint256) {
        uint256 length = _expiryHeap.length;
        while (true) {
            uint256 left = index * 2 + 1;
            if (left >= length) return index;
            uint256 right = left + 1;
            uint256 child = right < length && _expiryLess(_expiryHeap[right], _expiryHeap[left]) ? right : left;
            if (!_expiryLess(_expiryHeap[child], _expiryHeap[index])) return index;
            _swapExpiries(index, child);
            index = child;
        }
        return index;
    }

    function _expiryLess(ExpiryNode storage first, ExpiryNode storage second) private view returns (bool) {
        if (first.expiry != second.expiry) return first.expiry < second.expiry;
        return uint160(first.account) < uint160(second.account);
    }

    function _swapExpiries(uint256 first, uint256 second) private {
        ExpiryNode memory firstNode = _expiryHeap[first];
        ExpiryNode memory secondNode = _expiryHeap[second];
        _expiryHeap[first] = secondNode;
        _expiryHeap[second] = firstNode;
        _expiryHeapIndex[firstNode.account][firstNode.expiry] = second + 1;
        _expiryHeapIndex[secondNode.account][secondNode.expiry] = first + 1;
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

    function _eligible(address account) private view returns (bool) {
        return account != address(0) && account != DEAD && account != controller && account != address(this)
            && account != liquidityToken;
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
