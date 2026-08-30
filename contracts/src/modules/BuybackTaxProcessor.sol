// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BuybackVault} from "../vaults/BuybackVault.sol";
import {PancakeV2Adapter} from "../adapters/PancakeV2Adapter.sol";
import {ILaunchExecutor} from "../vaults/MintVault.sol";
import {HolderDeadRewardVault} from "../vaults/HolderDeadRewardVault.sol";

interface IBuybackTaxToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBuybackTaxRouter {
    function WETH() external view returns (address);
    function factory() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address recipient,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address recipient,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IBuybackTaxFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IBuybackTaxPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract BuybackTaxProcessor {
    struct Config {
        address receiver;
        address rewardAsset;
        uint256 rewardThreshold;
        uint16[4] allocationBps;
        uint16 maxSlippageBps;
        address controller;
        address quoteController;
        bytes32 fullConfigHash;
        address holderRewardVault;
        address liquidityAdapter;
    }

    struct TrustedDexConfig {
        address router;
        address factory;
        address wbnb;
        bytes32 routerCodehash;
        bytes32 factoryCodehash;
        bytes32 wbnbCodehash;
        bytes32 pairCodehash;
    }

    struct ProcessResult {
        uint256 nativeOutput;
        uint256 marketingTokens;
        uint256 liquidityTokens;
        uint256 rewardsTokens;
        uint256 buybackTokens;
        uint256 marketingNative;
        uint256 buybackNative;
    }

    struct LiquidityFloor {
        uint256 tokenDesired;
        uint256 nativeDesired;
        uint256 tokenMinimum;
        uint256 nativeMinimum;
        uint256 liquidityMinimum;
    }

    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error IncompleteTokenConsumption(uint256 remaining);
    error InsufficientNativeOutput(uint256 minimum, uint256 actual);
    error InvalidAllocationTotal(uint256 total);
    error InvalidController();
    error InvalidDependency(address dependency);
    error InvalidPair(address pair);
    error InvalidProcessingFloor();
    error InvalidReceiver();
    error InvalidSlippage(uint16 slippageBps);
    error MissingProcessingFloor();
    error MissingRewardFloor();
    error NativeTransferFailed(address recipient, uint256 amount);
    error ReentrantCall();
    error StaleProcessingFloor(uint256 expiry, uint256 currentTime);
    error StaleRewardFloor(uint256 expiry, uint256 currentTime);
    error TokenOperationFailed(address token);
    error UnauthorizedController(address caller);
    error UnauthorizedNativeSender(address caller);
    error UnauthorizedQuoteController(address caller);
    error UnexpectedDependencyCodehash(address dependency, bytes32 expected, bytes32 actual);
    error UnexpectedRouterRoute(
        address expectedFactory, address actualFactory, address expectedWbnb, address actualWbnb
    );
    error UnexpectedCanonicalPair(address expected, address actual);
    error UntrustedDependency(address provided, address expected);
    error ZeroNativeOutput();
    error ZeroTaxBalance();
    error InvalidLiquidityResult();
    error MissingLiquidityFloor();
    error StaleLiquidityFloor(uint256 expiry, uint256 currentTime);

    event PairActivated(address indexed pair);
    event TaxRecorded(uint256 amount, uint256 accountedTaxTokens);
    event ProcessingFloorCommitted(uint256 tokenAmount, uint256 minimumNativeOutput, uint256 expiry);
    event RewardFloorCommitted(uint256 tokenAmount, uint256 minimumOutput, uint256 expiry);
    event HolderRewardsSettled(uint256 tokenAmount, uint256 rewardAmount);
    event LiquidityFloorCommitted(
        uint256 tokenDesired,
        uint256 nativeDesired,
        uint256 tokenMinimum,
        uint256 nativeMinimum,
        uint256 liquidityMinimum,
        uint256 expiry
    );
    event TaxLiquidityAdded(uint256 tokenAmount, uint256 nativeAmount, uint256 liquidityAmount);
    event TaxProcessed(
        address indexed caller,
        uint256 totalTokens,
        uint256 marketingTokens,
        uint256 liquidityTokens,
        uint256 rewardsTokens,
        uint256 buybackTokens,
        uint256 marketingNative,
        uint256 buybackNative
    );

    uint256 public constant TOTAL_BPS = 10_000;
    uint256 public constant LIQUIDITY_BATCH_UNIT = 2 ether;

    IBuybackTaxToken public immutable token;
    IBuybackTaxRouter public immutable router;
    IBuybackTaxFactory public immutable factory;
    address public immutable wbnb;
    BuybackVault public immutable buybackVault;
    HolderDeadRewardVault public immutable holderRewardVault;
    PancakeV2Adapter public immutable liquidityAdapter;
    address public immutable receiver;
    address public immutable rewardAsset;
    uint256 public immutable rewardThreshold;
    address public immutable controller;
    address public immutable quoteController;
    uint16 public immutable marketingBps;
    uint16 public immutable liquidityBps;
    uint16 public immutable rewardsBps;
    uint16 public immutable buybackBps;
    uint16 public immutable maxSlippageBps;
    bytes32 public immutable fullConfigHash;
    bytes32 public immutable routerCodehash;
    bytes32 public immutable factoryCodehash;
    bytes32 public immutable wbnbCodehash;
    bytes32 public immutable pairCodehash;
    bytes32 public immutable holderRewardVaultCodehash;
    bytes32 public immutable liquidityAdapterCodehash;
    address public immutable rewardPair;

    address public liquidityPair;
    uint256 public floorTokenAmount;
    uint256 public floorMinimumNativeOutput;
    uint256 public floorExpiry;
    uint256 public accountedTaxTokens;
    uint256 public rewardFloorTokenAmount;
    uint256 public rewardFloorMinimumOutput;
    uint256 public rewardFloorExpiry;
    uint256 public pendingRewardAssets;
    uint256 public pendingLiquidityTokens;
    uint256 public availableLiquidityTokens;
    uint256 public pendingLiquidityUnsplitTokens;
    uint256 public pendingLiquidityNative;
    uint256 public liquidityFloorTokenDesired;
    uint256 public liquidityFloorNativeDesired;
    uint256 public liquidityFloorTokenMinimum;
    uint256 public liquidityFloorNativeMinimum;
    uint256 public liquidityFloorMinimumOutput;
    uint256 public liquidityFloorExpiry;
    bool private entered;

    constructor(
        address token_,
        address router_,
        address wbnb_,
        BuybackVault buybackVault_,
        Config memory config,
        TrustedDexConfig memory trusted
    ) {
        if (token_.code.length == 0) revert InvalidDependency(token_);
        if (router_.code.length == 0) revert InvalidDependency(router_);
        if (wbnb_.code.length == 0) revert InvalidDependency(wbnb_);
        if (address(buybackVault_).code.length == 0) revert InvalidDependency(address(buybackVault_));
        if (config.holderRewardVault.code.length == 0) revert InvalidDependency(config.holderRewardVault);
        if (config.liquidityAdapter.code.length == 0) revert InvalidDependency(config.liquidityAdapter);
        if (config.receiver == address(0)) revert InvalidReceiver();
        if (config.controller == address(0) || config.quoteController == address(0)) revert InvalidController();
        if (config.maxSlippageBps >= TOTAL_BPS) revert InvalidSlippage(config.maxSlippageBps);
        uint256 allocationTotal;
        for (uint256 index; index < config.allocationBps.length; ++index) {
            allocationTotal += config.allocationBps[index];
        }
        if (allocationTotal != 0 && allocationTotal != TOTAL_BPS) revert InvalidAllocationTotal(allocationTotal);

        _validateTrustedDependency(router_, trusted.router, trusted.routerCodehash);
        _validateTrustedDependency(wbnb_, trusted.wbnb, trusted.wbnbCodehash);
        IBuybackTaxRouter routerContract = IBuybackTaxRouter(router_);
        address actualFactory = routerContract.factory();
        address actualWbnb = routerContract.WETH();
        if (actualFactory != trusted.factory || actualWbnb != wbnb_) {
            revert UnexpectedRouterRoute(trusted.factory, actualFactory, wbnb_, actualWbnb);
        }
        _validateTrustedDependency(actualFactory, trusted.factory, trusted.factoryCodehash);

        token = IBuybackTaxToken(token_);
        router = routerContract;
        factory = IBuybackTaxFactory(actualFactory);
        wbnb = wbnb_;
        buybackVault = buybackVault_;
        receiver = config.receiver;
        rewardAsset = config.rewardAsset;
        rewardThreshold = config.rewardThreshold;
        controller = config.controller;
        quoteController = config.quoteController;
        marketingBps = config.allocationBps[0];
        liquidityBps = config.allocationBps[1];
        rewardsBps = config.allocationBps[2];
        buybackBps = config.allocationBps[3];
        maxSlippageBps = config.maxSlippageBps;
        fullConfigHash = config.fullConfigHash;
        routerCodehash = trusted.routerCodehash;
        factoryCodehash = trusted.factoryCodehash;
        wbnbCodehash = trusted.wbnbCodehash;
        pairCodehash = trusted.pairCodehash;
        holderRewardVault = HolderDeadRewardVault(config.holderRewardVault);
        liquidityAdapter = PancakeV2Adapter(payable(config.liquidityAdapter));
        holderRewardVaultCodehash = config.holderRewardVault.codehash;
        liquidityAdapterCodehash = config.liquidityAdapter.codehash;

        address configuredRewardPair;
        if (rewardsBps != 0) {
            if (config.rewardThreshold == 0) revert InvalidProcessingFloor();
            if (config.rewardAsset == token_) {
                configuredRewardPair = address(0);
            } else {
                if (config.rewardAsset.code.length == 0) revert InvalidDependency(config.rewardAsset);
                configuredRewardPair = IBuybackTaxFactory(actualFactory).getPair(wbnb_, config.rewardAsset);
                _validatePair(configuredRewardPair, wbnb_, config.rewardAsset);
            }
        }
        rewardPair = configuredRewardPair;
    }

    receive() external payable {
        if ((msg.sender != address(router) && msg.sender != address(liquidityAdapter)) || !entered) {
            revert UnauthorizedNativeSender(msg.sender);
        }
    }

    function activatePair(address pair) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (liquidityPair != address(0)) revert InvalidPair(pair);
        _validateRuntimeRoute();
        address canonical = factory.getPair(address(token), wbnb);
        if (pair != canonical || pair == address(0)) revert InvalidPair(pair);
        _validateCurrentDependency(pair, pairCodehash);
        address token0 = IBuybackTaxPair(pair).token0();
        address token1 = IBuybackTaxPair(pair).token1();
        if (!((token0 == address(token) && token1 == wbnb) || (token1 == address(token) && token0 == wbnb))) {
            revert InvalidPair(pair);
        }
        liquidityPair = pair;
        emit PairActivated(pair);
    }

    function recordTax(uint256 amount) external {
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        if (amount == 0 || token.balanceOf(address(this)) < _heldProjectTokens() + amount) {
            revert InvalidProcessingFloor();
        }
        accountedTaxTokens += amount;
        emit TaxRecorded(amount, accountedTaxTokens);
    }

    function unaccountedTaxTokenBalance() external view returns (uint256) {
        return token.balanceOf(address(this)) - _heldProjectTokens();
    }

    function unaccountedNativeBalance() external view returns (uint256) {
        return address(this).balance - pendingLiquidityNative;
    }

    function commitProcessingFloor(uint256 tokenAmount, uint256 minimumNativeOutput, uint256 expiry) external {
        if (msg.sender != quoteController) revert UnauthorizedQuoteController(msg.sender);
        // Quote validity is intentionally anchored to immutable chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (tokenAmount == 0 || expiry <= block.timestamp) {
            revert InvalidProcessingFloor();
        }
        floorTokenAmount = tokenAmount;
        floorMinimumNativeOutput = minimumNativeOutput;
        floorExpiry = expiry;
        emit ProcessingFloorCommitted(tokenAmount, minimumNativeOutput, expiry);
    }

    function commitRewardFloor(uint256 tokenAmount, uint256 minimumOutput, uint256 expiry) external {
        if (msg.sender != quoteController) revert UnauthorizedQuoteController(msg.sender);
        // Quote validity is intentionally anchored to immutable chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (tokenAmount == 0 || minimumOutput == 0 || expiry <= block.timestamp) revert InvalidProcessingFloor();
        rewardFloorTokenAmount = tokenAmount;
        rewardFloorMinimumOutput = minimumOutput;
        rewardFloorExpiry = expiry;
        emit RewardFloorCommitted(tokenAmount, minimumOutput, expiry);
    }

    function commitLiquidityFloor(
        uint256 tokenDesired,
        uint256 nativeDesired,
        uint256 tokenMinimum,
        uint256 nativeMinimum,
        uint256 liquidityMinimum,
        uint256 expiry
    ) external {
        if (msg.sender != quoteController) revert UnauthorizedQuoteController(msg.sender);
        if (
            tokenDesired == 0 || nativeDesired == 0 || tokenMinimum == 0 || nativeMinimum == 0 || liquidityMinimum == 0
                || tokenMinimum > tokenDesired || nativeMinimum > nativeDesired
                || tokenDesired > availableLiquidityTokens || nativeDesired > pendingLiquidityNative
        ) revert InvalidProcessingFloor();
        // Quote validity is intentionally anchored to immutable chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (expiry <= block.timestamp) revert InvalidProcessingFloor();
        liquidityFloorTokenDesired = tokenDesired;
        liquidityFloorNativeDesired = nativeDesired;
        liquidityFloorTokenMinimum = tokenMinimum;
        liquidityFloorNativeMinimum = nativeMinimum;
        liquidityFloorMinimumOutput = liquidityMinimum;
        liquidityFloorExpiry = expiry;
        emit LiquidityFloorCommitted(tokenDesired, nativeDesired, tokenMinimum, nativeMinimum, liquidityMinimum, expiry);
    }

    // All allocation calls execute only while `entered` is true; the reported post-call writes are cleanup/unlock.
    // slither-disable-start reentrancy-eth
    function processTax(uint256 callerMinimumNativeOutput, uint256 deadline)
        external
        returns (uint256 totalTokens, uint256 nativeOutput)
    {
        if (entered) revert ReentrantCall();
        // Tax execution deadlines are intentionally enforced against chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);
        if (liquidityPair == address(0)) revert InvalidPair(address(0));
        _validateRuntimeRoute();
        _validateCanonicalPair();
        entered = true;

        totalTokens = _consumeFloor();
        if (totalTokens == 0) revert ZeroTaxBalance();
        uint256 unaccountedBefore = token.balanceOf(address(this)) - _heldProjectTokens();
        accountedTaxTokens -= totalTokens;
        ProcessResult memory result = _processAllocations(totalTokens, callerMinimumNativeOutput, deadline);
        nativeOutput = result.nativeOutput;

        uint256 remaining = token.balanceOf(address(this));
        uint256 heldAfter = _heldProjectTokens();
        if (remaining < heldAfter || remaining - heldAfter != unaccountedBefore) {
            revert IncompleteTokenConsumption(remaining);
        }
        floorMinimumNativeOutput = 0;
        entered = false;
        emit TaxProcessed(
            msg.sender,
            totalTokens,
            result.marketingTokens,
            result.liquidityTokens,
            result.rewardsTokens,
            result.buybackTokens,
            result.marketingNative,
            result.buybackNative
        );
    }

    function processLiquidity(uint256 deadline)
        external
        returns (uint256 tokenSpent, uint256 nativeSpent, uint256 liquidityMinted)
    {
        if (entered) revert ReentrantCall();
        // Liquidity execution deadlines are intentionally enforced against chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);
        if (liquidityPair == address(0)) revert InvalidPair(address(0));
        _validateRuntimeRoute();
        _validateCanonicalPair();
        _validateCurrentDependency(address(liquidityAdapter), liquidityAdapterCodehash);
        entered = true;

        LiquidityFloor memory floor = _consumeLiquidityFloor();
        uint256 unaccountedTokenBefore = token.balanceOf(address(this)) - _heldProjectTokens();
        uint256 unaccountedNativeBefore = address(this).balance - pendingLiquidityNative;
        pendingLiquidityTokens -= floor.tokenDesired;
        availableLiquidityTokens -= floor.tokenDesired;
        pendingLiquidityNative -= floor.nativeDesired;

        ILaunchExecutor.ExecutionResult memory result = _callLiquidityAdapter(floor, deadline);
        tokenSpent = result.tokenSpent;
        nativeSpent = result.nativeSpent;
        liquidityMinted = result.liquidityAmount;
        _accountLiquidityResult(floor, result, unaccountedTokenBefore, unaccountedNativeBefore);

        entered = false;
        emit TaxLiquidityAdded(tokenSpent, nativeSpent, liquidityMinted);
    }
    // slither-disable-end reentrancy-eth

    function _callLiquidityAdapter(LiquidityFloor memory floor, uint256 deadline)
        private
        returns (ILaunchExecutor.ExecutionResult memory result)
    {
        _safeApprove(address(liquidityAdapter), 0);
        _safeApprove(address(liquidityAdapter), floor.tokenDesired);
        result = liquidityAdapter.addLiquidityWithBounds{value: floor.nativeDesired}(
            address(token),
            floor.tokenDesired,
            floor.tokenMinimum,
            floor.nativeMinimum,
            floor.liquidityMinimum,
            deadline
        );
        _safeApprove(address(liquidityAdapter), 0);
    }

    function _accountLiquidityResult(
        LiquidityFloor memory floor,
        ILaunchExecutor.ExecutionResult memory result,
        uint256 unaccountedTokenBefore,
        uint256 unaccountedNativeBefore
    ) private {
        if (
            result.magic != liquidityAdapter.EXECUTION_SUCCESS() || result.liquidityToken != liquidityPair
                || result.tokenSpent < floor.tokenMinimum || result.tokenSpent > floor.tokenDesired
                || result.nativeSpent < floor.nativeMinimum || result.nativeSpent > floor.nativeDesired
                || result.liquidityAmount < floor.liquidityMinimum
        ) revert InvalidLiquidityResult();

        uint256 tokenRefund = floor.tokenDesired - result.tokenSpent;
        uint256 nativeRefund = floor.nativeDesired - result.nativeSpent;
        pendingLiquidityTokens += tokenRefund;
        availableLiquidityTokens += tokenRefund;
        pendingLiquidityNative += nativeRefund;
        uint256 heldAfter = _heldProjectTokens();
        uint256 tokenBalanceAfter = token.balanceOf(address(this));
        if (tokenBalanceAfter < heldAfter || tokenBalanceAfter - heldAfter < unaccountedTokenBefore) {
            revert InvalidLiquidityResult();
        }
        uint256 nativeBalanceAfter = address(this).balance;
        if (
            nativeBalanceAfter < pendingLiquidityNative
                || nativeBalanceAfter - pendingLiquidityNative < unaccountedNativeBefore
        ) revert InvalidLiquidityResult();
    }

    function _processAllocations(uint256 totalTokens, uint256 callerMinimumNativeOutput, uint256 deadline)
        private
        returns (ProcessResult memory result)
    {
        result.marketingTokens = totalTokens * marketingBps / TOTAL_BPS;
        result.rewardsTokens = totalTokens * rewardsBps / TOTAL_BPS;
        result.buybackTokens = totalTokens * buybackBps / TOTAL_BPS;
        result.liquidityTokens = totalTokens - result.marketingTokens - result.rewardsTokens - result.buybackTokens;

        pendingLiquidityTokens += result.liquidityTokens;
        pendingLiquidityUnsplitTokens += result.liquidityTokens;
        uint256 pairableLiquidityTokens = pendingLiquidityUnsplitTokens / LIQUIDITY_BATCH_UNIT * LIQUIDITY_BATCH_UNIT;
        uint256 liquidityTokenSide = pairableLiquidityTokens / 2;
        pendingLiquidityUnsplitTokens -= pairableLiquidityTokens;
        pendingLiquidityTokens -= liquidityTokenSide;
        availableLiquidityTokens += liquidityTokenSide;

        uint256 swapTokens = result.marketingTokens + result.buybackTokens + liquidityTokenSide;
        uint256 liquidityNative;
        if (swapTokens != 0) {
            result.nativeOutput = _swapForNative(swapTokens, callerMinimumNativeOutput, deadline);
            result.buybackNative = result.nativeOutput * result.buybackTokens / swapTokens;
            liquidityNative = result.nativeOutput * liquidityTokenSide / swapTokens;
            result.marketingNative = result.nativeOutput - result.buybackNative - liquidityNative;
            pendingLiquidityNative += liquidityNative;
            if (result.buybackNative != 0) buybackVault.fundBuyback{value: result.buybackNative}();
            if (result.marketingNative != 0) _sendNative(receiver, result.marketingNative);
        }

        if (result.rewardsTokens != 0) {
            uint256 rewardOutput =
                rewardAsset == address(token) ? result.rewardsTokens : _swapForReward(result.rewardsTokens, deadline);
            pendingRewardAssets += rewardOutput;
        }
        _settleRewards(result.rewardsTokens);
    }

    function _swapForReward(uint256 amount, uint256 deadline) private returns (uint256 rewardOutput) {
        uint256 minimum = _rewardSwapMinimum(amount);
        rewardOutput = _callRewardSwap(amount, minimum, deadline);
        if (rewardOutput < minimum) revert InsufficientNativeOutput(minimum, rewardOutput);
        if (rewardOutput == 0) revert ZeroNativeOutput();
    }

    function _rewardSwapMinimum(uint256 amount) private returns (uint256 minimum) {
        _validateRewardPair();
        (uint256 committedMinimum, uint256 expiry) = _consumeRewardFloor(amount);
        // A committed independent quote is valid only through its immutable chain-time expiry.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > expiry) revert StaleRewardFloor(expiry, block.timestamp);
        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = wbnb;
        path[2] = rewardAsset;
        uint256[] memory quote = router.getAmountsOut(amount, path);
        if (quote.length != 3 || quote[0] != amount || quote[2] == 0) revert ZeroNativeOutput();
        uint256 spotFloor = quote[2] * (TOTAL_BPS - maxSlippageBps) / TOTAL_BPS;
        minimum = committedMinimum > spotFloor ? committedMinimum : spotFloor;
        if (minimum == 0) revert InvalidProcessingFloor();
    }

    function _callRewardSwap(uint256 amount, uint256 minimum, uint256 deadline) private returns (uint256 rewardOutput) {
        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = wbnb;
        path[2] = rewardAsset;
        IBuybackTaxToken rewardToken = IBuybackTaxToken(rewardAsset);
        uint256 rewardBalanceBefore = rewardToken.balanceOf(address(this));
        _safeApprove(address(router), 0);
        _safeApprove(address(router), amount);
        uint256[] memory amounts = router.swapExactTokensForTokens(amount, minimum, path, address(this), deadline);
        _safeApprove(address(router), 0);
        rewardOutput = rewardToken.balanceOf(address(this)) - rewardBalanceBefore;
        if (amounts.length != 3 || amounts[0] != amount || amounts[2] != rewardOutput) revert ZeroNativeOutput();
    }

    function _settleRewards(uint256 rewardTokens) private {
        if (pendingRewardAssets == 0 || pendingRewardAssets < rewardThreshold || holderRewardVault.totalWeight() == 0) {
            return;
        }
        _validateCurrentDependency(address(holderRewardVault), holderRewardVaultCodehash);
        uint256 amount = pendingRewardAssets;
        pendingRewardAssets = 0;
        IBuybackTaxToken rewardToken = IBuybackTaxToken(rewardAsset);
        _safeAssetApprove(rewardToken, address(holderRewardVault), 0);
        _safeAssetApprove(rewardToken, address(holderRewardVault), amount);
        holderRewardVault.fundRewards(amount);
        _safeAssetApprove(rewardToken, address(holderRewardVault), 0);
        emit HolderRewardsSettled(rewardTokens, amount);
    }

    function _swapForNative(uint256 amount, uint256 callerMinimum, uint256 deadline)
        private
        returns (uint256 nativeOutput)
    {
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = wbnb;
        uint256[] memory quote = router.getAmountsOut(amount, path);
        if (quote.length != 2 || quote[0] != amount || quote[1] == 0) revert ZeroNativeOutput();
        uint256 spotFloor = quote[1] * (TOTAL_BPS - maxSlippageBps) / TOTAL_BPS;
        uint256 minimum = floorMinimumNativeOutput > spotFloor ? floorMinimumNativeOutput : spotFloor;
        minimum = callerMinimum > minimum ? callerMinimum : minimum;
        if (minimum == 0) revert InvalidProcessingFloor();

        _safeApprove(address(router), 0);
        _safeApprove(address(router), amount);
        uint256 beforeBalance = address(this).balance;
        uint256[] memory amounts = router.swapExactTokensForETH(amount, minimum, path, address(this), deadline);
        _safeApprove(address(router), 0);
        uint256 received = address(this).balance - beforeBalance;
        if (amounts.length != 2 || amounts[0] != amount || amounts[1] > received) revert ZeroNativeOutput();
        nativeOutput = amounts[1];
        if (nativeOutput < minimum) revert InsufficientNativeOutput(minimum, nativeOutput);
        if (nativeOutput == 0) revert ZeroNativeOutput();
    }

    function _consumeFloor() private returns (uint256 amount) {
        if (floorTokenAmount == 0) revert MissingProcessingFloor();
        // A committed independent quote is valid only through its immutable chain-time expiry.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > floorExpiry) revert StaleProcessingFloor(floorExpiry, block.timestamp);
        amount = floorTokenAmount;
        if (amount > accountedTaxTokens) revert InvalidProcessingFloor();
        floorTokenAmount = 0;
        floorExpiry = 0;
    }

    function _consumeRewardFloor(uint256 amount) private returns (uint256 minimum, uint256 expiry) {
        if (rewardFloorTokenAmount == 0) revert MissingRewardFloor();
        if (rewardFloorTokenAmount != amount) revert InvalidProcessingFloor();
        minimum = rewardFloorMinimumOutput;
        expiry = rewardFloorExpiry;
        rewardFloorTokenAmount = 0;
        rewardFloorMinimumOutput = 0;
        rewardFloorExpiry = 0;
    }

    function _consumeLiquidityFloor() private returns (LiquidityFloor memory floor) {
        floor.tokenDesired = liquidityFloorTokenDesired;
        if (floor.tokenDesired == 0) revert MissingLiquidityFloor();
        // A committed independent quote is valid only through its immutable chain-time expiry.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > liquidityFloorExpiry) {
            revert StaleLiquidityFloor(liquidityFloorExpiry, block.timestamp);
        }
        floor.nativeDesired = liquidityFloorNativeDesired;
        floor.tokenMinimum = liquidityFloorTokenMinimum;
        floor.nativeMinimum = liquidityFloorNativeMinimum;
        floor.liquidityMinimum = liquidityFloorMinimumOutput;
        if (floor.tokenDesired > availableLiquidityTokens || floor.nativeDesired > pendingLiquidityNative) {
            revert InvalidProcessingFloor();
        }
        liquidityFloorTokenDesired = 0;
        liquidityFloorNativeDesired = 0;
        liquidityFloorTokenMinimum = 0;
        liquidityFloorNativeMinimum = 0;
        liquidityFloorMinimumOutput = 0;
        liquidityFloorExpiry = 0;
    }

    function _validateCanonicalPair() private view {
        address expectedPair = liquidityPair;
        address actualPair = factory.getPair(address(token), wbnb);
        if (actualPair != expectedPair) revert UnexpectedCanonicalPair(expectedPair, actualPair);
        _validateCurrentDependency(expectedPair, pairCodehash);
        address token0 = IBuybackTaxPair(expectedPair).token0();
        address token1 = IBuybackTaxPair(expectedPair).token1();
        if (!((token0 == address(token) && token1 == wbnb) || (token1 == address(token) && token0 == wbnb))) {
            revert InvalidPair(expectedPair);
        }
    }

    function _validateRewardPair() private view {
        address actualPair = factory.getPair(wbnb, rewardAsset);
        if (actualPair != rewardPair) revert UnexpectedCanonicalPair(rewardPair, actualPair);
        _validatePair(actualPair, wbnb, rewardAsset);
    }

    function _validatePair(address pair, address assetA, address assetB) private view {
        if (pair == address(0)) revert InvalidPair(pair);
        _validateCurrentDependency(pair, pairCodehash);
        address token0 = IBuybackTaxPair(pair).token0();
        address token1 = IBuybackTaxPair(pair).token1();
        if (!((token0 == assetA && token1 == assetB) || (token1 == assetA && token0 == assetB))) {
            revert InvalidPair(pair);
        }
    }

    function _validateRuntimeRoute() private view {
        _validateCurrentDependency(address(router), routerCodehash);
        _validateCurrentDependency(address(factory), factoryCodehash);
        _validateCurrentDependency(wbnb, wbnbCodehash);
        address actualFactory = router.factory();
        address actualWbnb = router.WETH();
        if (actualFactory != address(factory) || actualWbnb != wbnb) {
            revert UnexpectedRouterRoute(address(factory), actualFactory, wbnb, actualWbnb);
        }
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

    function _safeApprove(address spender, uint256 amount) private {
        _safeAssetApprove(token, spender, amount);
    }

    function _safeAssetApprove(IBuybackTaxToken asset, address spender, uint256 amount) private {
        (bool success, bytes memory result) =
            address(asset).call(abi.encodeCall(IBuybackTaxToken.approve, (spender, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }

    function _heldProjectTokens() private view returns (uint256 held) {
        held = accountedTaxTokens + pendingLiquidityTokens;
        if (rewardAsset == address(token)) held += pendingRewardAssets;
    }

    function _sendNative(address recipient, uint256 amount) private {
        // Recipients are immutable constructor configuration, not caller-supplied destinations.
        // slither-disable-next-line arbitrary-send-eth
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert NativeTransferFailed(recipient, amount);
    }
}
