// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxRouter} from "../../src/modules/TaxRouter.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address sender) external;
}

contract TaxTestToken {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[owner][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[owner][msg.sender] = allowed - amount;
        _transfer(owner, recipient, amount);
        return true;
    }

    function _transfer(address owner, address recipient, uint256 amount) private {
        require(balanceOf[owner] >= amount, "balance");
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount;
    }
}

contract TaxMockFactory {}

contract TaxMockWbnb {}

contract TaxMockPancakeRouter {
    address public immutable factory;
    address public immutable WETH;
    uint256 public swapCount;
    uint16 public quoteBps = 10_000;
    uint16 public swapBps = 10_000;
    bool public ignoreMinimumOutput;

    constructor(address factory_, address wbnb_) {
        factory = factory_;
        WETH = wbnb_;
    }

    receive() external payable {}

    function setMarket(uint16 quoteBps_, uint16 swapBps_, bool ignoreMinimumOutput_) external {
        quoteBps = quoteBps_;
        swapBps = swapBps_;
        ignoreMinimumOutput = ignoreMinimumOutput_;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(path.length == 2 && path[1] == WETH, "wrong route");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * quoteBps / 10_000;
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address recipient,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        // forge-lint: disable-next-line(block-timestamp)
        require(deadline >= block.timestamp, "expired");
        require(path.length == 2 && path[1] == WETH, "wrong route");
        uint256 amountOut = amountIn * swapBps / 10_000;
        require(ignoreMinimumOutput || amountOut >= amountOutMin, "slippage");
        ++swapCount;
        require(TaxTestToken(path[0]).transferFrom(msg.sender, address(this), amountIn), "pull");
        (bool sent,) = payable(recipient).call{value: amountOut}("");
        require(sent, "native send");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}

contract TaxReentrantReceiver {
    TaxRouter public router;
    bool public reentrySucceeded;
    bytes4 public reentryError;

    function setRouter(TaxRouter router_) external {
        router = router_;
    }

    receive() external payable {
        (bool success, bytes memory result) =
            address(router).call(abi.encodeCall(TaxRouter.processTax, (0, 0, block.timestamp + 1 hours)));
        reentrySucceeded = success;
        if (result.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(result, 0x20))
            }
            reentryError = selector;
        }
    }
}

contract TaxRouterTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MARKETING_RECEIVER = address(0x7001);
    address private constant LIQUIDITY_RECIPIENT = address(0x7002);
    address private constant REWARDS_RECIPIENT = address(0x7003);

    TaxTestToken private token;
    TaxMockPancakeRouter private pancake;

    function setUp() public {
        token = new TaxTestToken();
        pancake = new TaxMockPancakeRouter(address(new TaxMockFactory()), address(new TaxMockWbnb()));
        VM.deal(address(pancake), 1 ether);
    }

    function testAllocationConservesEveryTaxUnitAndAssignsRemainderToLiquidity() public {
        TaxRouter router = _newRouter(1_000, 4_000, 3_000, 2_000);
        token.mint(address(this), 10_003);
        token.approve(address(router), 10_003);

        (uint256 marketing, uint256 liquidity, uint256 rewards, uint256 burn, uint256 nativeMarketing) =
            router.processTax(10_003, 900, block.timestamp + 1 hours);

        require(marketing == 1_000, "marketing allocation mismatch");
        require(liquidity == 4_003, "rounding remainder did not reach liquidity");
        require(rewards == 3_000, "rewards allocation mismatch");
        require(burn == 2_000, "burn allocation mismatch");
        require(marketing + liquidity + rewards + burn == 10_003, "tax allocation not conserved");
        require(nativeMarketing == 1_000, "marketing native output mismatch");
        require(token.balanceOf(LIQUIDITY_RECIPIENT) == 4_003, "liquidity tokens misrouted");
        require(token.balanceOf(REWARDS_RECIPIENT) == 3_000, "reward tokens misrouted");
        require(token.balanceOf(router.DEAD_ADDRESS()) == 2_000, "burn tokens not dead-addressed");
    }

    function testMarketingAllocationSettlesOnlyFreshSwapOutputAsBnb() public {
        TaxRouter router = _newRouter(10_000, 0, 0, 0);
        token.mint(address(this), 1_000);
        token.approve(address(router), 1_000);
        VM.deal(address(router), 77);
        uint256 receiverBefore = MARKETING_RECEIVER.balance;

        (,,,, uint256 nativeMarketing) = router.processTax(1_000, 900, block.timestamp + 1 hours);

        require(nativeMarketing == 1_000, "fresh BNB output mismatch");
        require(MARKETING_RECEIVER.balance == receiverBefore + 1_000, "marketing receiver not settled in BNB");
        require(address(router).balance == 77, "unsolicited BNB was swept as marketing");
        require(token.allowance(address(router), address(pancake)) == 0, "router allowance not reset");
    }

    function testZeroTaxConfigurationAllowsZeroProcessingWithoutExternalCalls() public {
        TaxRouter router = _newRouter(0, 0, 0, 0);

        (uint256 marketing, uint256 liquidity, uint256 rewards, uint256 burn, uint256 nativeMarketing) =
            router.processTax(0, 0, block.timestamp + 1 hours);

        require(marketing + liquidity + rewards + burn + nativeMarketing == 0, "zero tax created allocation");
        require(pancake.swapCount() == 0, "zero tax called Pancake");

        VM.expectRevert(abi.encodeWithSelector(TaxRouter.TaxDisabled.selector));
        router.processTax(1, 0, block.timestamp + 1 hours);
    }

    function testOnlyImmutableControllerCanProcessTax() public {
        TaxRouter router = _newRouter(10_000, 0, 0, 0);
        address outsider = address(0xBAD);

        VM.prank(outsider);
        VM.expectRevert(abi.encodeWithSelector(TaxRouter.UnauthorizedController.selector, outsider));
        router.processTax(0, 0, block.timestamp + 1 hours);
    }

    function testStaleMarketingDeadlineRevertsBeforeTakingTaxTokens() public {
        TaxRouter router = _newRouter(10_000, 0, 0, 0);
        token.mint(address(this), 1_000);
        token.approve(address(router), 1_000);
        uint256 deadline = block.timestamp - 1;

        VM.expectRevert(abi.encodeWithSelector(TaxRouter.DeadlineExpired.selector, deadline, block.timestamp));
        router.processTax(1_000, 900, deadline);

        require(token.balanceOf(address(this)) == 1_000, "stale processing took tax tokens");
        require(pancake.swapCount() == 0, "stale processing called Pancake");
    }

    function testIndependentMinimumOutRejectsAdverseExecutionDespiteManipulatedLowQuote() public {
        TaxRouter router = _newRouter(10_000, 0, 0, 0);
        pancake.setMarket(1_000, 5_000, true);
        token.mint(address(this), 1_000);
        token.approve(address(router), 1_000);

        VM.expectRevert(abi.encodeWithSelector(TaxRouter.InsufficientMarketingOutput.selector, 900, 500));
        router.processTax(1_000, 900, block.timestamp + 1 hours);

        require(token.balanceOf(address(this)) == 1_000, "adverse execution took tax tokens");
        require(MARKETING_RECEIVER.balance == 0, "adverse execution paid marketing receiver");
    }

    function testMarketingReceiverCannotReenterTaxProcessing() public {
        TaxReentrantReceiver receiver = new TaxReentrantReceiver();
        TaxRouter router = _newRouterWithReceiver(10_000, 0, 0, 0, address(receiver));
        receiver.setRouter(router);
        token.mint(address(this), 1_000);
        token.approve(address(router), 1_000);

        router.processTax(1_000, 900, block.timestamp + 1 hours);

        require(!receiver.reentrySucceeded(), "marketing receiver reentered processing");
        require(receiver.reentryError() == TaxRouter.ReentrantCall.selector, "wrong reentry rejection");
        require(address(receiver).balance == 1_000, "outer marketing settlement failed");
    }

    function testSelfConsistentCounterfeitDexBundleCannotReplaceTrustedChainConfig() public {
        TaxMockFactory counterfeitFactory = new TaxMockFactory();
        TaxMockWbnb counterfeitWbnb = new TaxMockWbnb();
        TaxMockPancakeRouter counterfeitRouter =
            new TaxMockPancakeRouter(address(counterfeitFactory), address(counterfeitWbnb));
        TaxRouter.TrustedDexConfig memory trusted = _trustedDexConfig();

        VM.expectRevert(
            abi.encodeWithSelector(TaxRouter.UntrustedDependency.selector, address(counterfeitRouter), address(pancake))
        );
        new TaxRouter(
            address(token),
            address(counterfeitRouter),
            address(counterfeitWbnb),
            _taxConfig(10_000, 0, 0, 0, MARKETING_RECEIVER),
            trusted
        );
    }

    function testProcessingRejectsTrustedRouterWhoseRuntimeCodehashChanges() public {
        TaxRouter router = _newRouter(0, 0, 0, 0);
        TaxMockPancakeRouter replacement =
            new TaxMockPancakeRouter(address(new TaxMockFactory()), address(new TaxMockWbnb()));
        bytes32 expectedCodehash = address(pancake).codehash;
        bytes32 replacementCodehash = address(replacement).codehash;
        VM.etch(address(pancake), address(replacement).code);

        VM.expectRevert(
            abi.encodeWithSelector(
                TaxRouter.UnexpectedDependencyCodehash.selector, address(pancake), expectedCodehash, replacementCodehash
            )
        );
        router.processTax(0, 0, block.timestamp + 1 hours);
    }

    function testActiveTaxConfigurationMustAllocateExactlyOneHundredPercent() public {
        address wbnbAddress = pancake.WETH();
        TaxRouter.TrustedDexConfig memory trusted = _trustedDexConfig();
        VM.expectRevert(abi.encodeWithSelector(TaxRouter.InvalidAllocationTotal.selector, uint256(9_999)));
        new TaxRouter(
            address(token),
            address(pancake),
            wbnbAddress,
            _taxConfig(1_000, 3_999, 3_000, 2_000, MARKETING_RECEIVER),
            trusted
        );
    }

    function _newRouter(uint16 marketing, uint16 liquidity, uint16 rewards, uint16 burn) private returns (TaxRouter) {
        return _newRouterWithReceiver(marketing, liquidity, rewards, burn, MARKETING_RECEIVER);
    }

    function _newRouterWithReceiver(
        uint16 marketing,
        uint16 liquidity,
        uint16 rewards,
        uint16 burn,
        address marketingReceiver
    ) private returns (TaxRouter) {
        return new TaxRouter(
            address(token),
            address(pancake),
            pancake.WETH(),
            _taxConfig(marketing, liquidity, rewards, burn, marketingReceiver),
            _trustedDexConfig()
        );
    }

    function _taxConfig(uint16 marketing, uint16 liquidity, uint16 rewards, uint16 burn, address marketingReceiver)
        private
        view
        returns (TaxRouter.TaxConfig memory config)
    {
        config = TaxRouter.TaxConfig({
            marketingReceiver: marketingReceiver,
            liquidityRecipient: LIQUIDITY_RECIPIENT,
            rewardsRecipient: REWARDS_RECIPIENT,
            marketingBps: marketing,
            liquidityBps: liquidity,
            rewardsBps: rewards,
            burnBps: burn,
            maxSlippageBps: 500,
            controller: address(this)
        });
    }

    function _trustedDexConfig() private view returns (TaxRouter.TrustedDexConfig memory trusted) {
        address factory = pancake.factory();
        address wbnbAddress = pancake.WETH();
        trusted = TaxRouter.TrustedDexConfig({
            router: address(pancake),
            factory: factory,
            wbnb: wbnbAddress,
            routerCodehash: address(pancake).codehash,
            factoryCodehash: factory.codehash,
            wbnbCodehash: wbnbAddress.codehash
        });
    }
}
