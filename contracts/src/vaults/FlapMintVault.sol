// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFlapAdapter} from "../interfaces/IFlapAdapter.sol";
import {WhitelistMint} from "../modules/WhitelistMint.sol";

interface IFlapToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function sellProtectedUntil() external view returns (uint256);
}

contract FlapMintVault {
    enum State {
        Funding,
        Filled,
        Executing,
        Launched,
        Refundable,
        Closed
    }
    error DirectPaymentUnsupported();
    error IncorrectPayment();
    error InvalidAdapter();
    error InvalidGoal();
    error InvalidProof();
    error InvalidProtection();
    error InvalidResult();
    error InvalidShares();
    error InvalidState();
    error NothingToClaim();
    error NothingToRefund();
    error RefundDelayActive();
    error TransferFailed();
    error UnauthorizedSelfCall();
    error WhitelistProofRequired();
    event MintPurchased(address indexed buyer, uint32 shares, uint256 paid, uint32 totalSharesSold);
    event ExecutionAttempt(bool success, bytes32 resultHash);
    event Launched(address indexed token, address indexed pair, uint256 purchasedAmount);
    event Refunded(address indexed account, uint256 nativeAmount);
    event Claimed(address indexed account, uint256 tokenAmount);

    uint256 public constant REFUND_DELAY = 24 hours;
    uint256 private constant EXECUTION_GAS_LIMIT = 2_000_000;
    address public immutable creator;
    IFlapAdapter public immutable adapter;
    uint256 public immutable goal;
    uint32 public immutable totalShares;
    uint96 public immutable pricePerShare;
    uint64 public immutable protectionDuration;
    uint256 public immutable createdAt;
    WhitelistMint public immutable whitelist;
    State public state;
    uint32 public totalSharesSold;
    uint32 public totalClaimedShares;
    uint32 public totalRefundedShares;
    uint256 public totalPaid;
    uint256 public filledAt;
    uint256 public purchasedAmount;
    uint256 public totalClaimedTokens;
    uint256 public lastFailureAt;
    bytes32 public lastFailureHash;
    address public token;
    address public pair;
    mapping(address => uint32) public sharesOf;

    constructor(
        address creator_,
        address adapter_,
        uint256 goal_,
        uint32 shares_,
        bytes32 root_,
        uint64 whitelistDeadline_,
        uint64 protection_
    ) {
        if (creator_ == address(0) || adapter_.code.length == 0) revert InvalidAdapter();
        if (goal_ < 2 ether || goal_ > 16 ether || shares_ == 0 || goal_ % shares_ != 0) revert InvalidGoal();
        if (!_validProtection(protection_)) revert InvalidProtection();
        creator = creator_;
        adapter = IFlapAdapter(adapter_);
        goal = goal_;
        totalShares = shares_;
        // Safe because the validated goal is at most 16 ether, below uint96 max.
        // forge-lint: disable-next-line(unsafe-typecast)
        pricePerShare = uint96(goal_ / shares_);
        protectionDuration = protection_;
        createdAt = block.timestamp;
        whitelist =
            root_ == bytes32(0) ? WhitelistMint(address(0)) : new WhitelistMint(creator_, root_, whitelistDeadline_);
    }

    receive() external payable {
        revert DirectPaymentUnsupported();
    }

    function mint(uint32 shares) external payable {
        if (address(whitelist) != address(0) && !whitelist.isPublic()) revert WhitelistProofRequired();
        _mint(shares);
    }

    function mintWithProof(uint32 shares, uint256 epoch, bytes32[] calldata proof) external payable {
        if (address(whitelist) == address(0) || !whitelist.isAllowed(epoch, msg.sender, proof)) revert InvalidProof();
        _mint(shares);
    }

    function _mint(uint32 shares) private {
        if (state != State.Funding || shares == 0 || totalSharesSold + shares > totalShares) revert InvalidShares();
        uint256 payment = uint256(shares) * pricePerShare;
        if (msg.value != payment) revert IncorrectPayment();
        sharesOf[msg.sender] += shares;
        totalSharesSold += shares;
        totalPaid += payment;
        emit MintPurchased(msg.sender, shares, payment, totalSharesSold);
        if (totalSharesSold == totalShares) {
            state = State.Filled;
            filledAt = block.timestamp;
        }
    }

    function executeLaunch(IFlapAdapter.LaunchRequest calldata request) external returns (bool) {
        return _execute(request);
    }

    function retryLaunch(IFlapAdapter.LaunchRequest calldata request) external returns (bool) {
        return _execute(request);
    }

    function _execute(IFlapAdapter.LaunchRequest calldata request) private returns (bool success) {
        if (state != State.Filled || request.protectionDuration != protectionDuration) revert InvalidState();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= filledAt + REFUND_DELAY) revert RefundDelayActive();
        state = State.Executing;
        bytes memory data = abi.encodeCall(this.executeFinalization, (request));
        bytes32 resultHash;
        assembly ("memory-safe") {
            success := call(EXECUTION_GAS_LIMIT, address(), 0, add(data, 0x20), mload(data), 0, 0)
            let size := returndatasize()
            let ptr := mload(0x40)
            returndatacopy(ptr, 0, size)
            resultHash := keccak256(ptr, size)
        }
        emit ExecutionAttempt(success, resultHash);
        if (!success) {
            state = State.Filled;
            lastFailureAt = block.timestamp;
            lastFailureHash = resultHash;
            return false;
        }
        state = State.Launched;
        emit Launched(token, pair, purchasedAmount);
    }

    function executeFinalization(IFlapAdapter.LaunchRequest calldata request) external {
        if (msg.sender != address(this)) revert UnauthorizedSelfCall();
        uint256 beforeBalance = address(this).balance;
        IFlapAdapter.LaunchResult memory result = adapter.execute{value: totalPaid}(request);
        if (
            result.nativeSpent != totalPaid || address(this).balance != beforeBalance - totalPaid
                || result.token.code.length == 0 || result.pair.code.length == 0
                || result.purchasedAmount < request.minimumPurchased
                || IFlapToken(result.token).balanceOf(address(this)) != result.purchasedAmount
        ) revert InvalidResult();
        if (protectionDuration != 0) {
            // The protocol's timestamp must cover the immutable requested duration.
            // forge-lint: disable-next-line(block-timestamp)
            if (IFlapToken(result.token).sellProtectedUntil() < block.timestamp + protectionDuration) {
                revert InvalidProtection();
            }
        }
        token = result.token;
        pair = result.pair;
        purchasedAmount = result.purchasedAmount;
    }

    function claim() external returns (uint256 amount) {
        if (state != State.Launched) revert InvalidState();
        uint32 shares = sharesOf[msg.sender];
        if (shares == 0) revert NothingToClaim();
        uint32 afterShares = totalClaimedShares + shares;
        amount =
            afterShares == totalShares ? purchasedAmount - totalClaimedTokens : purchasedAmount * shares / totalShares;
        sharesOf[msg.sender] = 0;
        totalClaimedShares = afterShares;
        totalClaimedTokens += amount;
        if (afterShares == totalShares) state = State.Closed;
        uint256 beforeRecipient = IFlapToken(token).balanceOf(msg.sender);
        if (
            !IFlapToken(token).transfer(msg.sender, amount)
                || IFlapToken(token).balanceOf(msg.sender) - beforeRecipient != amount
        ) revert TransferFailed();
        emit Claimed(msg.sender, amount);
    }

    function enableRefunds() external {
        uint256 at =
            state == State.Funding ? createdAt + REFUND_DELAY : state == State.Filled ? filledAt + REFUND_DELAY : 0;
        // forge-lint: disable-next-line(block-timestamp)
        if (at == 0 || block.timestamp < at) revert RefundDelayActive();
        state = State.Refundable;
    }

    function refund() external returns (uint256 amount) {
        if (state != State.Refundable) revert InvalidState();
        uint32 shares = sharesOf[msg.sender];
        if (shares == 0) revert NothingToRefund();
        amount = uint256(shares) * pricePerShare;
        sharesOf[msg.sender] = 0;
        totalRefundedShares += shares;
        if (totalRefundedShares == totalSharesSold) state = State.Closed;
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Refunded(msg.sender, amount);
    }

    function _validProtection(uint64 duration) private pure returns (bool) {
        return duration == 0 || duration == 5 minutes || duration == 10 minutes || duration == 30 minutes
            || duration == 1 hours || duration == 24 hours;
    }
}
