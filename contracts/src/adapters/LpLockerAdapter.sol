// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILpToken {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);
}

interface IPinkLocker {
    function lock(
        address owner,
        address token,
        bool isLpToken,
        uint256 amount,
        uint256 unlockDate,
        string calldata description
    ) external returns (uint256 lockId);
}

contract LpLockerAdapter {
    struct LockerIdentity {
        address locker;
        bytes32 codehash;
    }

    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error InvalidAmount();
    error InvalidBeneficiary();
    error InvalidDependency(address dependency);
    error LockerNotAllowlisted(address locker);
    error InvalidLockResult(uint256 expectedAmount, uint256 lockerReceived, uint256 remainingAllowance);
    error ReentrantCall();
    error TokenAmountMismatch(uint256 expected, uint256 actual);
    error TokenOperationFailed(address token);
    error UnexpectedLockerCodehash(address locker, bytes32 expected, bytes32 actual);

    event LpBurned(address indexed caller, address indexed lpToken, uint256 amount, address deadAddress);
    event LpLocked(
        address indexed caller,
        address indexed lpToken,
        address indexed locker,
        address beneficiary,
        uint256 amount,
        uint256 unlockTime,
        uint256 lockId
    );

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    bytes4 public constant LOCK_INTERFACE_SELECTOR = IPinkLocker.lock.selector;

    mapping(address locker => bool allowed) public isLockerAllowed;
    mapping(address locker => bytes32 codehash) public lockerCodehash;
    bool private entered;

    constructor(LockerIdentity[] memory allowlistedLockers) {
        for (uint256 index; index < allowlistedLockers.length; ++index) {
            address locker = allowlistedLockers[index].locker;
            if (locker.code.length == 0) revert InvalidDependency(locker);
            bytes32 expectedCodehash = allowlistedLockers[index].codehash;
            bytes32 actualCodehash = locker.codehash;
            if (actualCodehash != expectedCodehash) {
                revert UnexpectedLockerCodehash(locker, expectedCodehash, actualCodehash);
            }
            isLockerAllowed[locker] = true;
            lockerCodehash[locker] = expectedCodehash;
        }
    }

    function burnLp(address lpToken, uint256 amount) external {
        if (entered) revert ReentrantCall();
        entered = true;
        ILpToken asset = _validatedToken(lpToken, amount);

        uint256 balanceBefore = asset.balanceOf(address(this));
        _safeTransferFrom(asset, msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TokenAmountMismatch(amount, received);

        uint256 deadBefore = asset.balanceOf(DEAD_ADDRESS);
        _safeTransfer(asset, DEAD_ADDRESS, amount);
        uint256 deadReceived = asset.balanceOf(DEAD_ADDRESS) - deadBefore;
        if (deadReceived != amount) revert TokenAmountMismatch(amount, deadReceived);

        emit LpBurned(msg.sender, lpToken, amount, DEAD_ADDRESS);
        entered = false;
    }

    function lockLp(address lpToken, uint256 amount, address locker, address beneficiary, uint256 unlockTime)
        external
        returns (uint256 lockId)
    {
        if (entered) revert ReentrantCall();
        if (!isLockerAllowed[locker]) revert LockerNotAllowlisted(locker);
        bytes32 expectedCodehash = lockerCodehash[locker];
        bytes32 actualCodehash = locker.codehash;
        if (actualCodehash != expectedCodehash) {
            revert UnexpectedLockerCodehash(locker, expectedCodehash, actualCodehash);
        }
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        // Locker expiry is intentionally enforced against chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (unlockTime <= block.timestamp) revert DeadlineExpired(unlockTime, block.timestamp);
        entered = true;
        {
            ILpToken asset = _validatedToken(lpToken, amount);

            uint256 balanceBefore = asset.balanceOf(address(this));
            _safeTransferFrom(asset, msg.sender, address(this), amount);
            uint256 received = asset.balanceOf(address(this)) - balanceBefore;
            if (received != amount) revert TokenAmountMismatch(amount, received);

            uint256 lockerBalanceBefore = asset.balanceOf(locker);
            _safeApprove(asset, locker, 0);
            _safeApprove(asset, locker, amount);
            lockId = IPinkLocker(locker).lock(beneficiary, lpToken, true, amount, unlockTime, "70X LP lock");
            _safeApprove(asset, locker, 0);
            uint256 lockerBalanceAfter = asset.balanceOf(locker);
            uint256 lockerReceived =
                lockerBalanceAfter >= lockerBalanceBefore ? lockerBalanceAfter - lockerBalanceBefore : 0;
            uint256 remainingAllowance = asset.allowance(address(this), locker);
            if (asset.balanceOf(address(this)) != balanceBefore || lockerReceived != amount || remainingAllowance != 0)
            {
                revert InvalidLockResult(amount, lockerReceived, remainingAllowance);
            }
        }

        emit LpLocked(msg.sender, lpToken, locker, beneficiary, amount, unlockTime, lockId);
        entered = false;
    }

    function _validatedToken(address token, uint256 amount) private view returns (ILpToken asset) {
        if (token.code.length == 0) revert InvalidDependency(token);
        if (amount == 0) revert InvalidAmount();
        asset = ILpToken(token);
    }

    function _safeApprove(ILpToken asset, address spender, uint256 amount) private {
        (bool success, bytes memory result) = address(asset).call(abi.encodeCall(ILpToken.approve, (spender, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }

    function _safeTransfer(ILpToken asset, address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(asset).call(abi.encodeCall(ILpToken.transfer, (recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }

    function _safeTransferFrom(ILpToken asset, address owner, address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(asset).call(abi.encodeCall(ILpToken.transferFrom, (owner, recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }
}
