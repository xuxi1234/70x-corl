// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITaxToken {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);
}

interface ITaxPancakeRouter {
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
}

contract TaxRouter {
    struct TaxConfig {
        address marketingReceiver;
        address liquidityRecipient;
        address rewardsRecipient;
        uint16 marketingBps;
        uint16 liquidityBps;
        uint16 rewardsBps;
        uint16 burnBps;
        uint16 maxSlippageBps;
        address controller;
    }

    struct TrustedDexConfig {
        address router;
        address factory;
        address wbnb;
        bytes32 routerCodehash;
        bytes32 factoryCodehash;
        bytes32 wbnbCodehash;
    }

    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error DirectNativeTransferUnsupported(address sender);
    error InvalidAllocationTotal(uint256 total);
    error InvalidDependency(address dependency);
    error InvalidController();
    error InvalidReceiver(address receiver);
    error InvalidRoute(address router, address expectedWbnb, address actualWbnb);
    error InvalidSlippage(uint16 slippageBps);
    error InsufficientMarketingOutput(uint256 minimum, uint256 actual);
    error MarketingTransferFailed(address receiver, uint256 amount);
    error ReentrantCall();
    error TaxDisabled();
    error TokenAmountMismatch(uint256 expected, uint256 actual);
    error TokenOperationFailed(address token);
    error UnauthorizedController(address caller);
    error UnexpectedDependencyCodehash(address dependency, bytes32 expected, bytes32 actual);
    error UntrustedDependency(address provided, address expected);
    error ZeroMarketingOutput();

    event TaxProcessed(
        address indexed payer,
        uint256 amount,
        uint256 marketingTokens,
        uint256 liquidityTokens,
        uint256 rewardTokens,
        uint256 burnTokens,
        uint256 marketingNative
    );

    uint256 public constant TOTAL_BPS = 10_000;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    ITaxToken public immutable token;
    ITaxPancakeRouter public immutable router;
    address public immutable factory;
    address public immutable wbnb;
    address public immutable controller;
    bytes32 public immutable routerCodehash;
    bytes32 public immutable factoryCodehash;
    bytes32 public immutable wbnbCodehash;
    address public immutable marketingReceiver;
    address public immutable liquidityRecipient;
    address public immutable rewardsRecipient;
    uint16 public immutable marketingBps;
    uint16 public immutable liquidityBps;
    uint16 public immutable rewardsBps;
    uint16 public immutable burnBps;
    uint16 public immutable maxSlippageBps;
    bool public immutable taxEnabled;

    bool private entered;

    constructor(
        address token_,
        address router_,
        address wbnb_,
        TaxConfig memory config,
        TrustedDexConfig memory trusted
    ) {
        if (token_.code.length == 0) revert InvalidDependency(token_);
        if (router_.code.length == 0) revert InvalidDependency(router_);
        if (wbnb_.code.length == 0) revert InvalidDependency(wbnb_);
        if (config.marketingReceiver == address(0)) revert InvalidReceiver(config.marketingReceiver);
        if (config.liquidityRecipient == address(0)) revert InvalidReceiver(config.liquidityRecipient);
        if (config.rewardsRecipient == address(0)) revert InvalidReceiver(config.rewardsRecipient);
        if (config.maxSlippageBps >= TOTAL_BPS) revert InvalidSlippage(config.maxSlippageBps);
        if (config.controller == address(0)) revert InvalidController();

        _validateTrustedDependency(router_, trusted.router, trusted.routerCodehash);
        _validateTrustedDependency(wbnb_, trusted.wbnb, trusted.wbnbCodehash);

        ITaxPancakeRouter routerContract = ITaxPancakeRouter(router_);
        address actualWbnb = routerContract.WETH();
        if (actualWbnb != wbnb_) revert InvalidRoute(router_, wbnb_, actualWbnb);
        address factory_ = routerContract.factory();
        if (factory_.code.length == 0) revert InvalidDependency(factory_);
        _validateTrustedDependency(factory_, trusted.factory, trusted.factoryCodehash);

        uint256 allocationTotal =
            uint256(config.marketingBps) + config.liquidityBps + config.rewardsBps + config.burnBps;
        if (allocationTotal != 0 && allocationTotal != TOTAL_BPS) {
            revert InvalidAllocationTotal(allocationTotal);
        }

        token = ITaxToken(token_);
        router = routerContract;
        factory = factory_;
        wbnb = wbnb_;
        controller = config.controller;
        routerCodehash = trusted.routerCodehash;
        factoryCodehash = trusted.factoryCodehash;
        wbnbCodehash = trusted.wbnbCodehash;
        marketingReceiver = config.marketingReceiver;
        liquidityRecipient = config.liquidityRecipient;
        rewardsRecipient = config.rewardsRecipient;
        marketingBps = config.marketingBps;
        liquidityBps = config.liquidityBps;
        rewardsBps = config.rewardsBps;
        burnBps = config.burnBps;
        maxSlippageBps = config.maxSlippageBps;
        taxEnabled = allocationTotal == TOTAL_BPS;
    }

    receive() external payable {
        if (msg.sender != address(router)) revert DirectNativeTransferUnsupported(msg.sender);
    }

    function processTax(uint256 amount, uint256 minimumMarketingOut, uint256 deadline)
        external
        returns (uint256 marketing, uint256 liquidity, uint256 rewards, uint256 burn, uint256 nativeMarketing)
    {
        if (entered) {
            revert ReentrantCall();
        }
        if (msg.sender != controller) revert UnauthorizedController(msg.sender);
        // Tax execution deadlines are intentionally enforced against chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);
        _validateCurrentDependency(address(router), routerCodehash);
        _validateCurrentDependency(factory, factoryCodehash);
        _validateCurrentDependency(wbnb, wbnbCodehash);
        entered = true;

        if (amount == 0) {
            emit TaxProcessed(msg.sender, 0, 0, 0, 0, 0, 0);
            entered = false;
            return (0, 0, 0, 0, 0);
        }
        if (!taxEnabled) revert TaxDisabled();

        uint256 balanceBefore = token.balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TokenAmountMismatch(amount, received);

        marketing = amount * marketingBps / TOTAL_BPS;
        rewards = amount * rewardsBps / TOTAL_BPS;
        burn = amount * burnBps / TOTAL_BPS;
        // Liquidity receives all integer-division dust so every tax unit is assigned exactly once.
        liquidity = amount - marketing - rewards - burn;

        if (rewards != 0) _safeTransfer(token, rewardsRecipient, rewards);
        if (burn != 0) _safeTransfer(token, DEAD_ADDRESS, burn);
        if (liquidity != 0) _safeTransfer(token, liquidityRecipient, liquidity);
        if (marketing != 0) nativeMarketing = _settleMarketing(marketing, minimumMarketingOut, deadline);

        emit TaxProcessed(msg.sender, amount, marketing, liquidity, rewards, burn, nativeMarketing);
        entered = false;
    }

    function _settleMarketing(uint256 amount, uint256 independentMinimumOutput, uint256 deadline)
        private
        returns (uint256 nativeAmount)
    {
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = wbnb;

        uint256[] memory quote = router.getAmountsOut(amount, path);
        if (quote.length != 2 || quote[1] == 0) revert ZeroMarketingOutput();
        uint256 quotedMinimumOutput = quote[1] * (TOTAL_BPS - maxSlippageBps) / TOTAL_BPS;
        uint256 minimumOutput =
            independentMinimumOutput > quotedMinimumOutput ? independentMinimumOutput : quotedMinimumOutput;

        _safeApprove(token, address(router), 0);
        _safeApprove(token, address(router), amount);
        uint256 nativeBefore = address(this).balance;
        router.swapExactTokensForETH(amount, minimumOutput, path, address(this), deadline);
        _safeApprove(token, address(router), 0);

        nativeAmount = address(this).balance - nativeBefore;
        if (nativeAmount < minimumOutput) revert InsufficientMarketingOutput(minimumOutput, nativeAmount);
        if (nativeAmount == 0) revert ZeroMarketingOutput();
        (bool sent,) = payable(marketingReceiver).call{value: nativeAmount}("");
        if (!sent) revert MarketingTransferFailed(marketingReceiver, nativeAmount);
    }

    function _validateTrustedDependency(address provided, address expected, bytes32 expectedCodehash) private view {
        if (provided != expected) revert UntrustedDependency(provided, expected);
        _validateCurrentDependency(provided, expectedCodehash);
    }

    function _validateCurrentDependency(address dependency, bytes32 expectedCodehash) private view {
        bytes32 actualCodehash = dependency.codehash;
        if (actualCodehash != expectedCodehash) {
            revert UnexpectedDependencyCodehash(dependency, expectedCodehash, actualCodehash);
        }
    }

    function _safeApprove(ITaxToken asset, address spender, uint256 amount) private {
        (bool success, bytes memory result) = address(asset).call(abi.encodeCall(ITaxToken.approve, (spender, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }

    function _safeTransfer(ITaxToken asset, address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(asset).call(abi.encodeCall(ITaxToken.transfer, (recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }

    function _safeTransferFrom(ITaxToken asset, address owner, address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(asset).call(abi.encodeCall(ITaxToken.transferFrom, (owner, recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }
}
