// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchToken} from "../tokens/LaunchToken.sol";

interface ILaunchExecutor {
    struct ExecutionResult {
        bytes4 magic;
        address liquidityToken;
        uint256 liquidityAmount;
        uint256 nativeSpent;
        uint256 tokenSpent;
    }

    function execute(address token, uint256 tokenAmount, uint256 minOutput, uint256 deadline)
        external
        payable
        returns (ExecutionResult memory result);
}

contract MintVault {
    enum State {
        Funding,
        Filled,
        Executing,
        Launched,
        Refundable,
        Closed
    }

    struct FinalizeParams {
        uint256 minOutput;
        uint256 deadline;
    }

    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error DirectPaymentUnsupported();
    error ExecutionWindowExpired(uint256 deadline, uint256 currentTime);
    error FundingExpired(uint256 deadline, uint256 currentTime);
    error IncorrectPayment(uint256 required, uint256 provided);
    error InvalidCreator();
    error InvalidExecutionResult();
    error InvalidExecutor(address executor);
    error InvalidPricePerShare();
    error InvalidRefundRecipient();
    error InvalidState(State current, State required);
    error InvalidTokenAllocation();
    error InvalidTotalShares();
    error MinimumOutputTooLow(uint256 required, uint256 provided);
    error NothingToClaim();
    error NothingToRefund();
    error RefundDelayActive(uint256 availableAt, uint256 currentTime);
    error RefundTransferFailed(address recipient, uint256 amount);
    error ShareCapacityExceeded(uint32 remaining, uint32 requested);
    error TokenTransferFailed(address recipient, uint256 amount);
    error UnauthorizedSelfCall(address caller);
    error UnauthorizedTokenCallback(address caller);
    error ZeroShares();

    event MintPurchased(address indexed buyer, uint32 shares, uint256 paid, uint32 totalSharesSold);
    event Filled(uint256 totalPaid);
    event ExecutionAttempt(
        address indexed caller,
        uint256 nativeAmount,
        uint256 tokenAmount,
        uint256 minOutput,
        uint256 deadline,
        bool success,
        bytes32 resultHash
    );
    event Launched(
        address indexed executor,
        uint256 nativeSpent,
        uint256 tokenSpent,
        address liquidityToken,
        uint256 liquidityAmount
    );
    event RefundsEnabled(uint256 enabledAt);
    event Refunded(address indexed account, address indexed recipient, uint32 shares, uint256 nativeAmount);
    event Claimed(address indexed account, uint32 shares, uint256 tokenAmount);

    bytes4 public constant EXECUTION_SUCCESS = bytes4(keccak256("MINT_VAULT_EXECUTION_SUCCESS"));
    uint256 public constant EXECUTION_GAS_LIMIT = 2_000_000;
    uint256 public constant MAX_FAILURE_DATA = 256;
    uint256 public constant REFUND_DELAY = 24 hours;

    address public immutable creator;
    address public immutable executor;
    LaunchToken public immutable token;
    uint32 public immutable totalShares;
    uint96 public immutable pricePerShare;
    uint256 public immutable createdAt;
    uint256 public immutable fundingDeadline;
    uint256 public immutable claimTokenAllocation;
    uint256 public immutable launchTokenAllocation;
    uint256 public immutable minimumLiquidityOutput;

    State public state;
    uint32 public totalSharesSold;
    uint32 public totalClaimedShares;
    uint32 public totalRefundedShares;
    uint256 public totalPaid;
    uint256 public accountedPrincipalBalance;
    uint256 public finalizedSpend;
    uint256 public finalizedTokenSpend;
    uint256 public totalRefunded;
    uint256 public totalTokensClaimed;
    uint256 public launchedAt;
    uint256 public filledAt;
    uint256 public lastFailureAt;
    bytes32 public lastFailureHash;
    address public liquidityToken;
    uint256 public liquidityAmount;

    mapping(address account => uint32 shares) public sharesOf;

    constructor(
        address creator_,
        address executor_,
        string memory name_,
        string memory symbol_,
        uint256 claimTokenAllocation_,
        uint256 launchTokenAllocation_,
        uint256 minimumLiquidityOutput_,
        uint32 totalShares_,
        uint96 pricePerShare_
    ) {
        if (creator_ == address(0)) revert InvalidCreator();
        if (executor_.code.length == 0) revert InvalidExecutor(executor_);
        if (claimTokenAllocation_ == 0 || launchTokenAllocation_ == 0) revert InvalidTokenAllocation();
        if (minimumLiquidityOutput_ == 0) revert MinimumOutputTooLow(1, 0);
        if (totalShares_ == 0) revert InvalidTotalShares();
        if (pricePerShare_ == 0) revert InvalidPricePerShare();

        creator = creator_;
        executor = executor_;
        totalShares = totalShares_;
        pricePerShare = pricePerShare_;
        createdAt = block.timestamp;
        fundingDeadline = block.timestamp + REFUND_DELAY;
        claimTokenAllocation = claimTokenAllocation_;
        launchTokenAllocation = launchTokenAllocation_;
        minimumLiquidityOutput = minimumLiquidityOutput_;
        token = new LaunchToken(name_, symbol_, claimTokenAllocation_ + launchTokenAllocation_, address(this));
    }

    receive() external payable {
        revert DirectPaymentUnsupported();
    }

    function onTokenTransfer(address from, address to, uint256 amount) external {
        if (msg.sender != address(token)) revert UnauthorizedTokenCallback(msg.sender);
        _onTokenTransfer(from, to, amount);
    }

    function onTaxCollected(uint256 amount) external {
        if (msg.sender != address(token)) revert UnauthorizedTokenCallback(msg.sender);
        _onTaxCollected(amount);
    }

    function _onTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    function _onTaxCollected(uint256 amount) internal virtual {}

    function _onLiquidityTokenSet(address liquidityToken_) internal virtual {}

    function mint(uint32 shares) public payable virtual {
        _requireState(State.Funding);
        // Funding closes exactly at the immutable deadline so a late mint cannot race refunds.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= fundingDeadline) revert FundingExpired(fundingDeadline, block.timestamp);
        if (shares == 0) revert ZeroShares();

        uint32 remaining = totalShares - totalSharesSold;
        if (shares > remaining) revert ShareCapacityExceeded(remaining, shares);

        uint256 requiredPayment = uint256(shares) * pricePerShare;
        if (msg.value != requiredPayment) revert IncorrectPayment(requiredPayment, msg.value);

        sharesOf[msg.sender] += shares;
        totalSharesSold += shares;
        totalPaid += msg.value;
        accountedPrincipalBalance += msg.value;

        emit MintPurchased(msg.sender, shares, msg.value, totalSharesSold);
        if (totalSharesSold == totalShares) {
            state = State.Filled;
            filledAt = block.timestamp;
            emit Filled(totalPaid);
        }
    }

    function finalize(FinalizeParams calldata params) external returns (bool success) {
        _requireState(State.Filled);
        uint256 executionDeadline = filledAt + REFUND_DELAY;
        // An unlaunched filled vault becomes irrevocably refundable at this exact boundary.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= executionDeadline) {
            revert ExecutionWindowExpired(executionDeadline, block.timestamp);
        }
        // The permissionless caller may tighten slippage and time, but cannot select route or recipient.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > params.deadline) revert DeadlineExpired(params.deadline, block.timestamp);
        if (params.minOutput < minimumLiquidityOutput) {
            revert MinimumOutputTooLow(minimumLiquidityOutput, params.minOutput);
        }

        state = State.Executing;
        finalizedSpend = totalPaid;
        finalizedTokenSpend = launchTokenAllocation;

        bytes memory executionCall = abi.encodeCall(this.executeFinalization, (params));
        bytes32 resultHash;
        (success, resultHash) = _boundedSelfCall(executionCall);

        emit ExecutionAttempt(
            msg.sender, totalPaid, launchTokenAllocation, params.minOutput, params.deadline, success, resultHash
        );

        if (!success) {
            finalizedSpend = 0;
            finalizedTokenSpend = 0;
            state = State.Filled;
            lastFailureAt = block.timestamp;
            lastFailureHash = resultHash;
            return false;
        }

        state = State.Launched;
        launchedAt = block.timestamp;
        emit Launched(executor, finalizedSpend, finalizedTokenSpend, liquidityToken, liquidityAmount);
    }

    function executeFinalization(FinalizeParams calldata params) external {
        if (msg.sender != address(this)) revert UnauthorizedSelfCall(msg.sender);

        uint256 principalToSpend = accountedPrincipalBalance;
        uint256 nativeBalanceBefore = address(this).balance;
        if (principalToSpend != totalPaid || nativeBalanceBefore < principalToSpend) revert InvalidExecutionResult();
        uint256 tokenBalanceBefore = token.balanceOf(address(this));
        if (tokenBalanceBefore != claimTokenAllocation + launchTokenAllocation) revert InvalidExecutionResult();
        if (!token.approve(executor, launchTokenAllocation)) revert InvalidExecutionResult();

        // Mark only buyer principal as in flight. A revert restores this accounting atomically.
        accountedPrincipalBalance = 0;
        ILaunchExecutor.ExecutionResult memory result = ILaunchExecutor(executor).execute{value: principalToSpend}(
            address(token), launchTokenAllocation, params.minOutput, params.deadline
        );

        uint256 tokenBalanceAfter = token.balanceOf(address(this));
        if (result.magic != EXECUTION_SUCCESS) revert InvalidExecutionResult();
        if (result.nativeSpent != principalToSpend || result.tokenSpent != launchTokenAllocation) {
            revert InvalidExecutionResult();
        }
        if (tokenBalanceAfter != claimTokenAllocation) revert InvalidExecutionResult();
        if (token.allowance(address(this), executor) != 0) revert InvalidExecutionResult();
        if (address(this).balance != nativeBalanceBefore - principalToSpend) revert InvalidExecutionResult();
        if (
            result.liquidityToken.code.length == 0 || result.liquidityAmount == 0
                || result.liquidityAmount < params.minOutput
        ) {
            revert InvalidExecutionResult();
        }

        liquidityToken = result.liquidityToken;
        _onLiquidityTokenSet(result.liquidityToken);
        liquidityAmount = result.liquidityAmount;
    }

    function claim() external returns (uint256 tokenAmount) {
        _requireState(State.Launched);

        uint32 shares = sharesOf[msg.sender];
        if (shares == 0) revert NothingToClaim();
        uint32 claimedSharesAfter = totalClaimedShares + shares;
        tokenAmount = claimedSharesAfter == totalShares
            ? claimTokenAllocation - totalTokensClaimed
            : claimTokenAllocation * shares / totalShares;

        sharesOf[msg.sender] = 0;
        totalClaimedShares = claimedSharesAfter;
        totalTokensClaimed += tokenAmount;
        if (claimedSharesAfter == totalShares) state = State.Closed;

        if (!token.transfer(msg.sender, tokenAmount)) revert TokenTransferFailed(msg.sender, tokenAmount);
        emit Claimed(msg.sender, shares, tokenAmount);
    }

    function enableRefunds() external {
        uint256 availableAt;
        if (state == State.Funding) {
            availableAt = fundingDeadline;
        } else if (state == State.Filled) {
            availableAt = filledAt + REFUND_DELAY;
        } else {
            revert InvalidState(state, State.Funding);
        }
        // Refund availability is intentionally enforced against immutable on-chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < availableAt) revert RefundDelayActive(availableAt, block.timestamp);

        state = State.Refundable;
        emit RefundsEnabled(block.timestamp);
    }

    function refund() external returns (uint256 nativeAmount) {
        return _refundTo(payable(msg.sender));
    }

    function refundTo(address payable recipient) external returns (uint256 nativeAmount) {
        if (recipient == address(0)) revert InvalidRefundRecipient();
        return _refundTo(recipient);
    }

    function _refundTo(address payable recipient) private returns (uint256 nativeAmount) {
        _requireState(State.Refundable);

        uint32 shares = sharesOf[msg.sender];
        if (shares == 0) revert NothingToRefund();
        nativeAmount = uint256(shares) * pricePerShare;

        sharesOf[msg.sender] = 0;
        totalRefundedShares += shares;
        totalRefunded += nativeAmount;
        accountedPrincipalBalance -= nativeAmount;
        if (totalRefundedShares == totalSharesSold) state = State.Closed;

        (bool success,) = recipient.call{value: nativeAmount}("");
        if (!success) revert RefundTransferFailed(recipient, nativeAmount);
        emit Refunded(msg.sender, recipient, shares, nativeAmount);
    }

    /// @notice Native value that was not paid by minters and is excluded from launch/refund accounting.
    /// @dev There is intentionally no creator or owner recovery path; unsolicited dust remains isolated here.
    function unsolicitedNativeBalance() external view returns (uint256) {
        return address(this).balance - accountedPrincipalBalance;
    }

    function _boundedSelfCall(bytes memory callData) private returns (bool success, bytes32 resultHash) {
        uint256 executionGasLimit = EXECUTION_GAS_LIMIT;
        uint256 maxFailureData = MAX_FAILURE_DATA;
        assembly ("memory-safe") {
            success := call(executionGasLimit, address(), 0, add(callData, 0x20), mload(callData), 0, 0)

            let returnSize := returndatasize()
            let copySize := returnSize
            if gt(copySize, maxFailureData) { copySize := maxFailureData }

            let resultData := mload(0x40)
            returndatacopy(resultData, 0, copySize)
            mstore(add(resultData, copySize), returnSize)
            resultHash := keccak256(resultData, add(copySize, 0x20))
            mstore(0x40, and(add(add(resultData, copySize), 0x3f), not(0x1f)))
        }
    }

    function _requireState(State required) private view {
        if (state != required) revert InvalidState(state, required);
    }
}
