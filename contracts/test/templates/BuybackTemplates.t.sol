// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../../src/core/LaunchTypes.sol";
import {TargetCompatibilityRegistry} from "../../src/core/TargetCompatibilityRegistry.sol";
import {
    AutoBuybackTemplateV1,
    BuybackCompanionDeployer,
    BuybackLiquidityDeployer,
    BuybackProjectDeployer,
    BuybackRewardDeployer,
    BuybackTaxProcessorDeployer,
    BuybackTemplateBaseV1,
    TrustedCompanionDeployers
} from "../../src/templates/AutoBuybackTemplateV1.sol";
import {LpLockerAdapter} from "../../src/adapters/LpLockerAdapter.sol";
import {PancakeV2Adapter} from "../../src/adapters/PancakeV2Adapter.sol";
import {ExternalBurnTemplateV1} from "../../src/templates/ExternalBurnTemplateV1.sol";
import {TimedBuybackTemplateV1} from "../../src/templates/TimedBuybackTemplateV1.sol";
import {LaunchToken} from "../../src/tokens/LaunchToken.sol";
import {BuybackVault} from "../../src/vaults/BuybackVault.sol";
import {ILaunchExecutor} from "../../src/vaults/MintVault.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function deal(address account, uint256 newBalance) external;
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function expectRevert() external;
    function expectRevert(bytes calldata revertData) external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function prank(address sender) external;
    function recordLogs() external;
    function warp(uint256 newTimestamp) external;
}

contract BuybackTestToken {
    mapping(address account => uint256 amount) public balanceOf;
    uint16 public immutable transferFeeBps;

    constructor(uint16 transferFeeBps_) {
        transferFeeBps = transferFeeBps_;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        uint256 delivered = amount * (10_000 - transferFeeBps) / 10_000;
        balanceOf[recipient] += delivered;
        return true;
    }
}

contract BuybackPair {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract BuybackFactory {
    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new BuybackPair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract BuybackRouter {
    address public immutable factory;
    address public immutable WETH;
    uint16 public quoteBps = 10_000;
    uint16 public outputBps = 10_000;
    uint16 public reportedInputBps = 10_000;
    uint256 public reportedOutputAdjustment;
    bool public ignoreMinimumOutput;
    bool public revertSwap;
    address public reentryTarget;
    bool public reentrySucceeded;
    bytes4 public reentryError;
    uint256 public observedNextExecutionAt;
    address public lastRecipient;
    uint256 public lastInput;

    constructor(address factory_, address wbnb_) {
        factory = factory_;
        WETH = wbnb_;
    }

    function setMarket(uint16 quoteBps_, uint16 outputBps_, bool ignoreMinimumOutput_) external {
        quoteBps = quoteBps_;
        outputBps = outputBps_;
        ignoreMinimumOutput = ignoreMinimumOutput_;
    }

    function setReportedInputBps(uint16 bps) external {
        reportedInputBps = bps;
    }

    function setReportedOutputAdjustment(uint256 adjustment) external {
        reportedOutputAdjustment = adjustment;
    }

    function setRevertSwap(bool value) external {
        revertSwap = value;
    }

    function setReentryTarget(address target) external {
        reentryTarget = target;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(path.length == 2 && path[0] == WETH, "route");
        require(BuybackFactory(factory).getPair(path[0], path[1]) != address(0), "missing pair");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * quoteBps / 10_000;
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address recipient, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        require(!revertSwap, "swap failed");
        // Test router intentionally models the production AMM deadline check.
        // forge-lint: disable-next-line(block-timestamp)
        require(deadline >= block.timestamp, "expired");
        require(path.length == 2 && path[0] == WETH, "route");
        uint256 deliveredRequest = msg.value * outputBps / 10_000;
        require(ignoreMinimumOutput || deliveredRequest >= amountOutMin, "slippage");

        if (reentryTarget != address(0)) {
            observedNextExecutionAt = BuybackVault(payable(reentryTarget)).nextExecutionAt();
            (bool success, bytes memory result) =
                reentryTarget.call(abi.encodeCall(BuybackVault.executeBuyback, (uint256(0), block.timestamp + 1 hours)));
            reentrySucceeded = success;
            if (result.length >= 4) {
                bytes4 selector;
                assembly ("memory-safe") {
                    selector := mload(add(result, 0x20))
                }
                reentryError = selector;
            }
        }

        lastRecipient = recipient;
        lastInput = msg.value;
        require(BuybackTestToken(path[1]).transfer(recipient, deliveredRequest), "transfer");

        uint256 reportedOutput = deliveredRequest + reportedOutputAdjustment;
        amounts = new uint256[](2);
        amounts[0] = msg.value * reportedInputBps / 10_000;
        amounts[1] = reportedOutput;
    }
}

contract BuybackLaunchExecutor is ILaunchExecutor {
    function execute(address, uint256, uint256, uint256) external payable returns (ExecutionResult memory) {
        revert("not exercised");
    }
}

contract BuybackVaultBehaviorTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant ATTACKER = address(0xBAD);

    BuybackTestToken private wbnb;
    BuybackTestToken private target;
    BuybackFactory private pancakeFactory;
    BuybackRouter private router;
    TargetCompatibilityRegistry private registry;
    bytes32 private pairCodehash;

    function setUp() public {
        wbnb = new BuybackTestToken(0);
        target = new BuybackTestToken(0);
        pancakeFactory = new BuybackFactory();
        address pair = pancakeFactory.createPair(address(wbnb), address(target));
        pairCodehash = pair.codehash;
        router = new BuybackRouter(address(pancakeFactory), address(wbnb));
        registry = new TargetCompatibilityRegistry(address(this));
        registry.setApprovedCodehash(address(target).codehash, true);
        target.mint(address(router), 1_000_000 ether);
        VM.deal(address(this), 1_000_000 ether);
    }

    function testThresholdBlocksExecutionUntilVaultBalanceQualifies() public {
        BuybackVault vault = _newVault(target, 2 ether, 5 ether, 0, 500, false);
        _fund(vault, 2 ether - 1);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.ThresholdNotMet.selector, 2 ether, 2 ether - 1));
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testPerCallCapLeavesExcessPrincipalInVaultAndPaysNoBounty() public {
        BuybackVault vault = _newVault(target, 1 ether, 2 ether, 0, 500, false);
        _fund(vault, 5 ether);

        VM.prank(ATTACKER);
        (uint256 spent, uint256 output) = vault.executeBuyback(0, block.timestamp + 1 hours);

        require(spent == 2 ether && output == 2 ether, "cap ignored");
        require(address(vault).balance == 3 ether, "excess principal spent");
        require(ATTACKER.balance == 0, "caller bounty paid");
    }

    function testOutputAlwaysGoesDirectlyToCanonicalDeadAddress() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 0, 500, false);
        _fund(vault, 1 ether);
        bytes memory attemptedRedirect = bytes.concat(
            abi.encodeCall(BuybackVault.executeBuyback, (uint256(1 ether), block.timestamp + 1 hours)),
            abi.encode(ATTACKER)
        );

        VM.prank(ATTACKER);
        (bool success,) = address(vault).call(attemptedRedirect);

        require(success, "trailing caller data changed ABI behavior");
        require(router.lastRecipient() == DEAD, "caller redirected recipient");
        require(target.balanceOf(DEAD) == 1 ether, "dead did not receive output");
        require(target.balanceOf(ATTACKER) == 0 && ATTACKER.balance == 0, "caller received principal or output");
    }

    function testTargetAndRouteAreImmutableAcrossExecutions() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 0, 500, true);
        bytes32 expectedRouteHash = keccak256(abi.encode(address(wbnb), address(target)));

        require(address(vault.targetToken()) == address(target), "target changed");
        require(vault.routeHash() == expectedRouteHash, "route changed");
        require(vault.canonicalPair() == pancakeFactory.getPair(address(wbnb), address(target)), "pair not pinned");
    }

    function testExternalTargetWithoutTrustedCanonicalRouteIsRejected() public {
        BuybackTestToken unrouted = new BuybackTestToken(0);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InvalidRoute.selector, address(unrouted)));
        _newVault(unrouted, 1 ether, 1 ether, 0, 500, true);
    }

    function testExternalTargetWithZeroTrustedRouteQuoteIsRejected() public {
        router.setMarket(0, 10_000, false);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InvalidRoute.selector, address(target)));
        _newVault(target, 1 ether, 1 ether, 0, 500, true);
    }

    function testExpiredDeadlineRevertsBeforeRouteCallOrPrincipalSpend() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 0, 500, false);
        _fund(vault, 1 ether);
        VM.warp(100);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.DeadlineExpired.selector, 99, 100));
        vault.executeBuyback(0, 99);
        require(address(vault).balance == 1 ether, "expired call spent funds");
        require(router.lastInput() == 0, "expired call reached router");
    }

    function testScheduledExecutionRejectsEarlyCallAtBoundaryMinusOne() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 5 minutes, 500, false);
        _fund(vault, 1 ether);
        uint256 availableAt = vault.nextExecutionAt();
        VM.warp(availableAt - 1);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.ExecutionTooEarly.selector, availableAt, availableAt - 1));
        vault.executeBuyback(0, availableAt + 1 hours);
    }

    function testScheduledStateAdvancesBeforeRouterReentry() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 5 minutes, 500, false);
        _fund(vault, 1 ether);
        uint256 availableAt = vault.nextExecutionAt();
        VM.warp(availableAt);
        router.setReentryTarget(address(vault));

        vault.executeBuyback(0, block.timestamp + 1 hours);

        require(!router.reentrySucceeded(), "router reentered");
        require(router.reentryError() == BuybackVault.ReentrantCall.selector, "wrong reentry rejection");
        require(router.observedNextExecutionAt() == availableAt + 5 minutes, "schedule changed after router call");
        require(vault.nextExecutionAt() == availableAt + 5 minutes, "schedule not advanced");
    }

    function testScheduledFailedSwapRollsBackScheduleAndPreservesFundsForRetry() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 5 minutes, 500, false);
        _fund(vault, 1 ether);
        uint256 availableAt = vault.nextExecutionAt();
        VM.warp(availableAt);
        router.setRevertSwap(true);

        VM.expectRevert();
        vault.executeBuyback(0, block.timestamp + 1 hours);

        require(vault.nextExecutionAt() == availableAt, "failed call consumed interval");
        require(address(vault).balance == 1 ether, "failed call lost funds");
    }

    function testQuoteDerivedSlippageFloorCannotBeWeakenedByCaller() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 0, 1_000, false);
        _fund(vault, 1 ether);
        router.setMarket(10_000, 8_000, true);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InsufficientOutput.selector, 0.9 ether, 0.8 ether));
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testCallerCanTightenButNotWeakenMinimumOutput() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 0, 1_000, false);
        _fund(vault, 1 ether);
        router.setMarket(10_000, 9_500, true);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InsufficientOutput.selector, 0.96 ether, 0.95 ether));
        vault.executeBuyback(0.96 ether, block.timestamp + 1 hours);
    }

    function testFeeOnTransferOutputMismatchRevertsWithoutSpendingFunds() public {
        BuybackTestToken taxedTarget = new BuybackTestToken(1_000);
        pancakeFactory.createPair(address(wbnb), address(taxedTarget));
        taxedTarget.mint(address(router), 100 ether);
        BuybackVault vault = _newVault(taxedTarget, 1 ether, 1 ether, 0, 500, false);
        _fund(vault, 1 ether);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.OutputAmountMismatch.selector, 1 ether, 0.9 ether));
        vault.executeBuyback(0, block.timestamp + 1 hours);
        require(address(vault).balance == 1 ether, "mismatch spent funds");
    }

    function testRouterReportedInputMismatchIsRejected() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 0, 500, false);
        _fund(vault, 1 ether);
        router.setReportedInputBps(9_999);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InputAmountMismatch.selector, 1 ether, 0.9999 ether));
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testRouterReportedOutputMismatchIsRejected() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 0, 500, false);
        _fund(vault, 1 ether);
        router.setReportedOutputAdjustment(1);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.OutputAmountMismatch.selector, 1 ether + 1, 1 ether));
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testChangedTrustedRouterCodehashBlocksExecution() public {
        BuybackVault vault = _newVault(target, 1 ether, 1 ether, 0, 500, false);
        _fund(vault, 1 ether);
        bytes32 expected = address(router).codehash;
        VM.etch(address(router), hex"00");
        bytes32 actual = address(router).codehash;

        VM.expectRevert(
            abi.encodeWithSelector(
                BuybackVault.UnexpectedDependencyCodehash.selector, address(router), expected, actual
            )
        );
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function _newVault(
        BuybackTestToken target_,
        uint256 threshold,
        uint256 maxSpend,
        uint32 interval,
        uint16 maxSlippageBps,
        bool requireRouteAtCreation
    ) private returns (BuybackVault vault) {
        BuybackVault.Config memory config = BuybackVault.Config({
            targetToken: address(target_),
            threshold: threshold,
            maxSpend: maxSpend,
            interval: interval,
            maxSlippageBps: maxSlippageBps,
            requireRouteAtCreation: requireRouteAtCreation,
            requireTargetApproval: requireRouteAtCreation,
            controller: address(this),
            quoteController: address(this),
            fullConfigHash: keccak256("behavior")
        });
        vault = new BuybackVault(address(router), address(wbnb), config, _trusted());
        if (address(vault).code.length != 0) {
            vault.setFunder(address(this));
            if (interval != 0) vault.activateSchedule();
        }
    }

    function _trusted() private view returns (BuybackVault.TrustedDexConfig memory trusted) {
        trusted = BuybackVault.TrustedDexConfig({
            router: address(router),
            factory: address(pancakeFactory),
            wbnb: address(wbnb),
            targetRegistry: address(registry),
            routerCodehash: address(router).codehash,
            factoryCodehash: address(pancakeFactory).codehash,
            wbnbCodehash: address(wbnb).codehash,
            pairCodehash: pairCodehash,
            targetRegistryCodehash: address(registry).codehash
        });
    }

    function _fund(BuybackVault vault, uint256 amount) private {
        vault.fundBuyback{value: amount}();
        uint256 input = vault.accountedFunds() < vault.maxSpend() ? vault.accountedFunds() : vault.maxSpend();
        uint256 minimum = input * (10_000 - vault.maxSlippageBps()) / 10_000;
        if (minimum == 0) minimum = 1;
        vault.commitExecutionFloor(input, minimum, block.timestamp + 1 hours);
    }
}

contract BuybackTemplateDeploymentTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant COMPANION_EVENT_SIG =
        keccak256("BuybackCompanionDeployed(bytes32,uint32,address,address,address,bytes32)");
    address private constant CREATOR = address(0xC0FFEE);

    BuybackTestToken private wbnb;
    BuybackTestToken private externalTarget;
    BuybackFactory private pancakeFactory;
    BuybackRouter private router;
    BuybackLaunchExecutor private executor;
    TargetCompatibilityRegistry private registry;
    BuybackVault.TrustedDexConfig private trusted;
    TrustedCompanionDeployers private trustedDeployers;

    function setUp() public {
        wbnb = new BuybackTestToken(0);
        externalTarget = new BuybackTestToken(0);
        pancakeFactory = new BuybackFactory();
        address pair = pancakeFactory.createPair(address(wbnb), address(externalTarget));
        router = new BuybackRouter(address(pancakeFactory), address(wbnb));
        executor = new BuybackLaunchExecutor();
        BuybackCompanionDeployer vaultDeployer = new BuybackCompanionDeployer();
        BuybackRewardDeployer rewardDeployer = new BuybackRewardDeployer();
        LpLockerAdapter.LockerIdentity[] memory lockers = new LpLockerAdapter.LockerIdentity[](0);
        LpLockerAdapter lpAdapter = new LpLockerAdapter(lockers);
        PancakeV2Adapter.TrustedDependencies memory liquidityTrusted = PancakeV2Adapter.TrustedDependencies({
            router: address(router),
            factory: address(pancakeFactory),
            wbnb: address(wbnb),
            lpAdapter: address(lpAdapter),
            routerCodehash: address(router).codehash,
            factoryCodehash: address(pancakeFactory).codehash,
            wbnbCodehash: address(wbnb).codehash,
            pairCodehash: pair.codehash,
            lpAdapterCodehash: address(lpAdapter).codehash
        });
        BuybackLiquidityDeployer liquidityDeployer = new BuybackLiquidityDeployer(
            address(router), address(wbnb), address(lpAdapter), address(0), liquidityTrusted
        );
        BuybackTaxProcessorDeployer taxProcessorDeployer =
            new BuybackTaxProcessorDeployer(rewardDeployer, liquidityDeployer);
        BuybackProjectDeployer projectDeployer = new BuybackProjectDeployer();
        registry = new TargetCompatibilityRegistry(address(this));
        registry.setApprovedCodehash(address(externalTarget).codehash, true);
        trusted = BuybackVault.TrustedDexConfig({
            router: address(router),
            factory: address(pancakeFactory),
            wbnb: address(wbnb),
            targetRegistry: address(registry),
            routerCodehash: address(router).codehash,
            factoryCodehash: address(pancakeFactory).codehash,
            wbnbCodehash: address(wbnb).codehash,
            pairCodehash: pair.codehash,
            targetRegistryCodehash: address(registry).codehash
        });
        trustedDeployers = TrustedCompanionDeployers({
            buybackVaultDeployer: address(vaultDeployer),
            taxProcessorDeployer: address(taxProcessorDeployer),
            projectDeployer: address(projectDeployer),
            buybackVaultDeployerCodehash: address(vaultDeployer).codehash,
            taxProcessorDeployerCodehash: address(taxProcessorDeployer).codehash,
            projectDeployerCodehash: address(projectDeployer).codehash
        });
    }

    function testAutoTemplatePreservesMintCustodyAndExposesProjectTargetCompanion() public {
        AutoBuybackTemplateV1 template = new AutoBuybackTemplateV1(
            address(this), address(executor), address(router), address(wbnb), address(this), trustedDeployers, trusted
        );
        AutoBuybackTemplateV1.AutoBuybackConfig memory buyback =
            AutoBuybackTemplateV1.AutoBuybackConfig({threshold: 1 ether, maxSpend: 2 ether, maxSlippageBps: 500});

        (address token, address mintVault) =
            template.deploy(CREATOR, abi.encode(_common()), abi.encode(_standard(), buyback));
        address companion = template.buybackVaultOf(mintVault);

        require(companion.code.length != 0, "companion missing");
        require(address(BuybackVault(payable(companion)).targetToken()) == token, "project target not immutable");
        require(LaunchToken(token).balanceOf(mintVault) == 1_000_000 ether, "mint custody escaped");
    }

    function testTimedTemplateSetsIntervalAndEmitsDiscoverableSpecializedConfigHash() public {
        TimedBuybackTemplateV1 template = new TimedBuybackTemplateV1(
            address(this), address(executor), address(router), address(wbnb), address(this), trustedDeployers, trusted
        );
        TimedBuybackTemplateV1.TimedBuybackConfig memory buyback = TimedBuybackTemplateV1.TimedBuybackConfig({
            threshold: 1 ether, maxSpend: 2 ether, interval: 1 days, maxSlippageBps: 500
        });
        LaunchTypes.CommonConfig memory common = _common();
        AutoBuybackTemplateV1.StandardConfig memory standard = _standard();
        bytes32 expectedHash = keccak256(abi.encode(common, standard, buyback));
        VM.recordLogs();

        (address token, address mintVault) = template.deploy(CREATOR, abi.encode(common), abi.encode(standard, buyback));
        address companion = template.buybackVaultOf(mintVault);
        Vm.Log memory companionLog = _companionLog(VM.getRecordedLogs(), address(template));
        (address loggedVault, address loggedCompanion, bytes32 loggedHash) =
            abi.decode(companionLog.data, (address, address, bytes32));

        require(companionLog.topics[0] == COMPANION_EVENT_SIG, "wrong event");
        require(companionLog.topics[1] == template.TEMPLATE_ID(), "wrong template ID");
        require(address(uint160(uint256(companionLog.topics[3]))) == token, "wrong indexed token");
        require(loggedVault == mintVault && loggedCompanion == companion, "undiscoverable addresses");
        require(loggedHash == expectedHash, "specialized config hash mismatch");
        require(BuybackVault(payable(companion)).interval() == 1 days, "interval missing");
    }

    function testExternalTemplatePinsExternalTargetAndRequiresTrustedRoute() public {
        ExternalBurnTemplateV1 template = new ExternalBurnTemplateV1(
            address(this), address(executor), address(router), address(wbnb), address(this), trustedDeployers, trusted
        );
        ExternalBurnTemplateV1.ExternalBurnConfig memory buyback = ExternalBurnTemplateV1.ExternalBurnConfig({
            targetToken: address(externalTarget), threshold: 1 ether, maxSpend: 2 ether, maxSlippageBps: 500
        });

        (address projectToken, address mintVault) =
            template.deploy(CREATOR, abi.encode(_common()), abi.encode(_standard(), buyback));
        BuybackVault companion = BuybackVault(payable(template.buybackVaultOf(mintVault)));

        require(address(companion.targetToken()) == address(externalTarget), "external target changed");
        require(address(companion.targetToken()) != projectToken, "project token substituted");
        require(
            companion.canonicalPair() == pancakeFactory.getPair(address(wbnb), address(externalTarget)),
            "route not pinned"
        );
    }

    function testExternalTemplateRejectsWbnbTarget() public {
        ExternalBurnTemplateV1 template = new ExternalBurnTemplateV1(
            address(this), address(executor), address(router), address(wbnb), address(this), trustedDeployers, trusted
        );
        ExternalBurnTemplateV1.ExternalBurnConfig memory buyback = ExternalBurnTemplateV1.ExternalBurnConfig({
            targetToken: address(wbnb), threshold: 1 ether, maxSpend: 2 ether, maxSlippageBps: 500
        });

        VM.expectRevert(abi.encodeWithSelector(ExternalBurnTemplateV1.InvalidExternalTarget.selector, address(wbnb)));
        template.deploy(CREATOR, abi.encode(_common()), abi.encode(_standard(), buyback));
    }

    function testTemplatesExposeImmutableVersionedIds() public {
        AutoBuybackTemplateV1 autoTemplate = new AutoBuybackTemplateV1(
            address(this), address(executor), address(router), address(wbnb), address(this), trustedDeployers, trusted
        );
        TimedBuybackTemplateV1 timedTemplate = new TimedBuybackTemplateV1(
            address(this), address(executor), address(router), address(wbnb), address(this), trustedDeployers, trusted
        );
        ExternalBurnTemplateV1 externalTemplate = new ExternalBurnTemplateV1(
            address(this), address(executor), address(router), address(wbnb), address(this), trustedDeployers, trusted
        );

        require(autoTemplate.TEMPLATE_ID() == "AUTO_BUYBACK", "auto ID");
        require(timedTemplate.TEMPLATE_ID() == "TIMED_BUYBACK", "timed ID");
        require(externalTemplate.TEMPLATE_ID() == "EXTERNAL_BURN", "external ID");
        require(
            autoTemplate.VERSION() == 1 && timedTemplate.VERSION() == 1 && externalTemplate.VERSION() == 1, "version"
        );
    }

    function testUnauthorizedCallerIsRejectedBeforeMalformedConfigDecoding() public {
        address requiredFactory = address(0xFACADE);
        AutoBuybackTemplateV1 template = new AutoBuybackTemplateV1(
            requiredFactory, address(executor), address(router), address(wbnb), address(this), trustedDeployers, trusted
        );

        VM.expectRevert(abi.encodeWithSelector(BuybackTemplateBaseV1.UnauthorizedFactory.selector, address(this)));
        template.deploy(CREATOR, hex"", hex"");
    }

    function _companionLog(Vm.Log[] memory logs, address emitter) private pure returns (Vm.Log memory found) {
        for (uint256 index; index < logs.length; ++index) {
            if (logs[index].emitter == emitter && logs[index].topics[0] == COMPANION_EVENT_SIG) return logs[index];
        }
        revert("companion event missing");
    }

    function _standard() private pure returns (AutoBuybackTemplateV1.StandardConfig memory config) {
        config = AutoBuybackTemplateV1.StandardConfig({
            totalShares: 100, pricePerShare: 0.01 ether, claimTokenBps: 8_000, minimumLiquidityOutput: 1
        });
    }

    function _common() private view returns (LaunchTypes.CommonConfig memory config) {
        config.name = "Buyback Launch";
        config.symbol = "BUY";
        config.supply = 1_000_000;
        config.receiver = CREATOR;
        config.rewardToken = address(externalTarget);
        config.metadataHash = keccak256("buyback-launch");
    }
}
