// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBuybackToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IBuybackRouter {
    function WETH() external view returns (address);
    function factory() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address recipient, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
}

interface IBuybackFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IBuybackPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface ITargetCompatibilityRegistry {
    function requireApproved(bytes32 codehash) external view;
}

contract BuybackVault {
    struct Config {
        address targetToken;
        uint256 threshold;
        uint256 maxSpend;
        uint32 interval;
        uint16 maxSlippageBps;
        bool requireRouteAtCreation;
        bool requireTargetApproval;
        address controller;
        address quoteController;
        bytes32 fullConfigHash;
    }

    struct TrustedDexConfig {
        address router;
        address factory;
        address wbnb;
        address targetRegistry;
        bytes32 routerCodehash;
        bytes32 factoryCodehash;
        bytes32 wbnbCodehash;
        bytes32 pairCodehash;
        bytes32 targetRegistryCodehash;
    }

    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error ExecutionTooEarly(uint256 availableAt, uint256 currentTime);
    error InputAmountMismatch(uint256 expected, uint256 actual);
    error InsufficientOutput(uint256 minimum, uint256 actual);
    error InvalidDependency(address dependency);
    error InvalidInterval(uint32 interval);
    error InvalidMaximumSpend();
    error InvalidPairMembers(address pair, address token0, address token1);
    error InvalidRoute(address targetToken);
    error InvalidSlippage(uint16 slippageBps);
    error InvalidSwapResult();
    error InvalidTargetToken(address targetToken);
    error InvalidThreshold();
    error IncompatibleTargetToken(address targetToken);
    error InvalidController();
    error InvalidExecutionFloor();
    error InvalidFunder(address funder);
    error MissingExecutionFloor();
    error OutputAmountMismatch(uint256 reported, uint256 actual);
    error ReentrantCall();
    error ScheduleAlreadyActive();
    error ScheduleNotActive();
    error StaleExecutionFloor(uint256 expiry, uint256 currentTime);
    error ThresholdNotMet(uint256 threshold, uint256 balance);
    error UnauthorizedController(address caller);
    error UnauthorizedFunder(address caller);
    error UnauthorizedQuoteController(address caller);
    error UnexpectedCanonicalPair(address expected, address actual);
    error UnexpectedDependencyCodehash(address dependency, bytes32 expected, bytes32 actual);
    error UntrustedDependency(address provided, address expected);
    error UnexpectedRouterRoute(
        address expectedFactory, address actualFactory, address expectedWbnb, address actualWbnb
    );

    event BuybackFunded(address indexed sender, uint256 amount, uint256 vaultBalance);
    event ExecutionFloorCommitted(uint256 inputAmount, uint256 minimumOutput, uint256 expiry);
    event ScheduleActivated(uint256 nextExecutionAt);
    event UnaccountedNativeReceived(address indexed sender, uint256 amount);
    event BuybackExecuted(
        address indexed caller,
        address indexed targetToken,
        uint256 nativeSpent,
        uint256 tokenBurned,
        uint256 nextExecutionAt
    );
    event Burned(address indexed token, uint256 amount);

    uint256 public constant TOTAL_BPS = 10_000;
    uint32 public constant MIN_INTERVAL = 5 minutes;
    uint32 public constant MAX_INTERVAL = 30 days;
    uint256 public constant ROUTE_PROBE_AMOUNT = 1 ether;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IBuybackToken public immutable targetToken;
    IBuybackRouter public immutable router;
    IBuybackFactory public immutable factory;
    address public immutable wbnb;
    address public canonicalPair;
    address public immutable controller;
    address public immutable quoteController;
    address public immutable targetRegistry;
    uint256 public immutable threshold;
    uint256 public immutable maxSpend;
    uint32 public immutable interval;
    uint16 public immutable maxSlippageBps;
    bytes32 public immutable routeHash;
    bytes32 public immutable targetCodehash;
    bytes32 public immutable routerCodehash;
    bytes32 public immutable factoryCodehash;
    bytes32 public immutable wbnbCodehash;
    bytes32 public immutable pairCodehash;
    bytes32 public immutable targetRegistryCodehash;
    bytes32 public immutable fullConfigHash;

    address public funder;
    uint256 public accountedFunds;
    uint256 public nextExecutionAt;
    uint256 public floorInputAmount;
    uint256 public floorMinimumOutput;
    uint256 public floorExpiry;
    bool public scheduleActive;
    bool private entered;

    constructor(address router_, address wbnb_, Config memory config, TrustedDexConfig memory trusted) {
        if (router_.code.length == 0) revert InvalidDependency(router_);
        if (wbnb_.code.length == 0) revert InvalidDependency(wbnb_);
        if (config.targetToken.code.length == 0 || config.targetToken == wbnb_) {
            revert InvalidTargetToken(config.targetToken);
        }
        if (config.threshold == 0) revert InvalidThreshold();
        if (config.maxSpend == 0) revert InvalidMaximumSpend();
        if (config.interval != 0 && (config.interval < MIN_INTERVAL || config.interval > MAX_INTERVAL)) {
            revert InvalidInterval(config.interval);
        }
        if (config.maxSlippageBps >= TOTAL_BPS) revert InvalidSlippage(config.maxSlippageBps);
        if (config.controller == address(0) || config.quoteController == address(0)) revert InvalidController();
        if (config.fullConfigHash == bytes32(0)) revert InvalidExecutionFloor();
        if (trusted.pairCodehash == bytes32(0)) revert InvalidDependency(address(0));

        _validateTrustedDependency(router_, trusted.router, trusted.routerCodehash);
        _validateTrustedDependency(wbnb_, trusted.wbnb, trusted.wbnbCodehash);
        _validateTrustedDependency(trusted.targetRegistry, trusted.targetRegistry, trusted.targetRegistryCodehash);

        IBuybackRouter routerContract = IBuybackRouter(router_);
        address actualWbnb = routerContract.WETH();
        if (actualWbnb != wbnb_) revert UntrustedDependency(actualWbnb, wbnb_);
        address factory_ = routerContract.factory();
        if (factory_.code.length == 0) revert InvalidDependency(factory_);
        _validateTrustedDependency(factory_, trusted.factory, trusted.factoryCodehash);

        address creationPair;
        if (config.requireTargetApproval) {
            ITargetCompatibilityRegistry(trusted.targetRegistry).requireApproved(config.targetToken.codehash);
            _validateTargetInterface(config.targetToken);
        }
        if (config.requireRouteAtCreation) {
            creationPair =
                _validateRoute(IBuybackFactory(factory_), wbnb_, config.targetToken, trusted.pairCodehash, address(0));
            _validateQuote(routerContract, wbnb_, config.targetToken, ROUTE_PROBE_AMOUNT);
        }

        targetToken = IBuybackToken(config.targetToken);
        router = routerContract;
        factory = IBuybackFactory(factory_);
        wbnb = wbnb_;
        canonicalPair = creationPair;
        controller = config.controller;
        quoteController = config.quoteController;
        targetRegistry = trusted.targetRegistry;
        threshold = config.threshold;
        maxSpend = config.maxSpend;
        interval = config.interval;
        maxSlippageBps = config.maxSlippageBps;
        routeHash = keccak256(abi.encode(wbnb_, config.targetToken));
        targetCodehash = config.targetToken.codehash;
        routerCodehash = trusted.routerCodehash;
        factoryCodehash = trusted.factoryCodehash;
        wbnbCodehash = trusted.wbnbCodehash;
        pairCodehash = trusted.pairCodehash;
        targetRegistryCodehash = trusted.targetRegistryCodehash;
        fullConfigHash = config.fullConfigHash;
    }

    receive() external payable {
        emit UnaccountedNativeReceived(msg.sender, msg.value);
    }

    function setFunder(address funder_) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (funder != address(0) || funder_ == address(0)) revert InvalidFunder(funder_);
        funder = funder_;
    }

    function fundBuyback() external payable {
        if (msg.sender != funder) revert UnauthorizedFunder(msg.sender);
        if (msg.value == 0) revert InvalidMaximumSpend();
        accountedFunds += msg.value;
        emit BuybackFunded(msg.sender, msg.value, accountedFunds);
    }

    function activateSchedule() external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (interval == 0 || scheduleActive) revert ScheduleAlreadyActive();
        scheduleActive = true;
        nextExecutionAt = block.timestamp + interval;
        emit ScheduleActivated(nextExecutionAt);
    }

    function activatePair(address pair) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (canonicalPair != address(0)) revert UnexpectedCanonicalPair(canonicalPair, pair);
        canonicalPair = _validateRoute(factory, wbnb, address(targetToken), pairCodehash, pair);
    }

    function commitExecutionFloor(uint256 inputAmount, uint256 minimumOutput, uint256 expiry) external {
        if (msg.sender != quoteController) revert UnauthorizedQuoteController(msg.sender);
        // Quote validity is intentionally anchored to immutable chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (inputAmount == 0 || minimumOutput == 0 || expiry <= block.timestamp) revert InvalidExecutionFloor();
        floorInputAmount = inputAmount;
        floorMinimumOutput = minimumOutput;
        floorExpiry = expiry;
        emit ExecutionFloorCommitted(inputAmount, minimumOutput, expiry);
    }

    function executeBuyback(uint256 minOut, uint256 deadline) external returns (uint256 spent, uint256 output) {
        if (entered) revert ReentrantCall();
        // Buyback deadlines are intentionally enforced against chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);

        if (interval != 0 && !scheduleActive) revert ScheduleNotActive();
        uint256 availableFunds = accountedFunds;
        if (availableFunds < threshold) revert ThresholdNotMet(threshold, availableFunds);
        // Scheduled execution is intentionally enforced against immutable on-chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (interval != 0 && block.timestamp < nextExecutionAt) {
            revert ExecutionTooEarly(nextExecutionAt, block.timestamp);
        }

        _validateCurrentDependency(address(router), routerCodehash);
        _validateCurrentDependency(address(factory), factoryCodehash);
        _validateCurrentDependency(wbnb, wbnbCodehash);
        _validateCurrentDependency(address(targetToken), targetCodehash);
        address actualFactory = router.factory();
        address actualWbnb = router.WETH();
        if (actualFactory != address(factory) || actualWbnb != wbnb) {
            revert UnexpectedRouterRoute(address(factory), actualFactory, wbnb, actualWbnb);
        }

        spent = availableFunds < maxSpend ? availableFunds : maxSpend;
        _consumeExecutionFloor(spent);

        entered = true;
        accountedFunds = availableFunds - spent;
        if (interval != 0) {
            // Effects precede every route/router external call. A downstream revert restores this value atomically,
            // keeping the same interval slot and native funds available for a permissionless retry.
            nextExecutionAt = block.timestamp + interval;
        }

        _validateRoute(factory, wbnb, address(targetToken), pairCodehash, canonicalPair);
        uint256 effectiveMinimum = _effectiveMinimum(spent, minOut);
        output = _executeSwap(spent, effectiveMinimum, deadline);

        entered = false;
        emit BuybackExecuted(msg.sender, address(targetToken), spent, output, nextExecutionAt);
        emit Burned(address(targetToken), output);
    }

    function _effectiveMinimum(uint256 spent, uint256 minOut) private view returns (uint256) {
        uint256 quotedOutput = _validateQuote(router, wbnb, address(targetToken), spent);
        uint256 quoteFloor = quotedOutput * (TOTAL_BPS - maxSlippageBps) / TOTAL_BPS;
        uint256 independentFloor = floorMinimumOutput;
        uint256 effective = independentFloor > quoteFloor ? independentFloor : quoteFloor;
        effective = minOut > effective ? minOut : effective;
        if (effective == 0) revert InvalidExecutionFloor();
        return effective;
    }

    function _executeSwap(uint256 spent, uint256 effectiveMinimum, uint256 deadline) private returns (uint256 output) {
        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = address(targetToken);
        uint256 deadBalanceBefore = targetToken.balanceOf(DEAD_ADDRESS);
        uint256[] memory amounts =
            router.swapExactETHForTokens{value: spent}(effectiveMinimum, path, DEAD_ADDRESS, deadline);
        uint256 deadBalanceAfter = targetToken.balanceOf(DEAD_ADDRESS);

        if (amounts.length != 2) revert InvalidSwapResult();
        if (amounts[0] != spent) revert InputAmountMismatch(spent, amounts[0]);
        output = deadBalanceAfter >= deadBalanceBefore ? deadBalanceAfter - deadBalanceBefore : 0;
        if (amounts[1] != output) revert OutputAmountMismatch(amounts[1], output);
        if (output < effectiveMinimum) revert InsufficientOutput(effectiveMinimum, output);
        if (output == 0) revert InvalidSwapResult();
    }

    function unsolicitedNativeBalance() external view returns (uint256) {
        return address(this).balance - accountedFunds;
    }

    function _consumeExecutionFloor(uint256 spent) private {
        if (floorInputAmount == 0) revert MissingExecutionFloor();
        // A committed independent quote is valid only through its immutable chain-time expiry.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > floorExpiry) revert StaleExecutionFloor(floorExpiry, block.timestamp);
        if (floorInputAmount != spent || floorMinimumOutput == 0) revert InvalidExecutionFloor();
        floorInputAmount = 0;
        floorExpiry = 0;
    }

    function _validateTargetInterface(address target_) private {
        (bool balanceSuccess, bytes memory balanceResult) =
            target_.staticcall(abi.encodeCall(IBuybackToken.balanceOf, (DEAD_ADDRESS)));
        if (!balanceSuccess || balanceResult.length != 32) revert IncompatibleTargetToken(target_);
        (bool transferSuccess, bytes memory transferResult) =
            target_.call(abi.encodeCall(IBuybackToken.transfer, (DEAD_ADDRESS, 0)));
        if (!transferSuccess || transferResult.length != 32 || !abi.decode(transferResult, (bool))) {
            revert IncompatibleTargetToken(target_);
        }
    }

    function _validateRoute(
        IBuybackFactory factory_,
        address wbnb_,
        address target_,
        bytes32 expectedPairCodehash,
        address expectedPair
    ) private view returns (address pair) {
        pair = factory_.getPair(wbnb_, target_);
        if (pair == address(0)) revert InvalidRoute(target_);
        if (expectedPair != address(0) && pair != expectedPair) revert UnexpectedCanonicalPair(expectedPair, pair);
        _validateCurrentDependency(pair, expectedPairCodehash);
        address token0 = IBuybackPair(pair).token0();
        address token1 = IBuybackPair(pair).token1();
        if (!((token0 == wbnb_ && token1 == target_) || (token0 == target_ && token1 == wbnb_))) {
            revert InvalidPairMembers(pair, token0, token1);
        }
    }

    function _validateQuote(IBuybackRouter router_, address wbnb_, address target_, uint256 amount)
        private
        view
        returns (uint256 quotedOutput)
    {
        address[] memory path = new address[](2);
        path[0] = wbnb_;
        path[1] = target_;
        uint256[] memory quote = router_.getAmountsOut(amount, path);
        if (quote.length != 2 || quote[0] != amount || quote[1] == 0) revert InvalidRoute(target_);
        quotedOutput = quote[1];
    }

    function _validateTrustedDependency(address provided, address expected, bytes32 expectedCodehash) private view {
        if (provided != expected) revert UntrustedDependency(provided, expected);
        _validateCurrentDependency(provided, expectedCodehash);
    }

    function _validateCurrentDependency(address dependency, bytes32 expectedCodehash) private view {
        bytes32 actual = dependency.codehash;
        if (actual != expectedCodehash) {
            revert UnexpectedDependencyCodehash(dependency, expectedCodehash, actual);
        }
    }
}
