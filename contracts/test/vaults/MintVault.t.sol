// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchFactory} from "../../src/core/LaunchFactory.sol";
import {LaunchTypes} from "../../src/core/LaunchTypes.sol";
import {PlatformConfig} from "../../src/core/PlatformConfig.sol";
import {TemplateRegistry} from "../../src/core/TemplateRegistry.sol";
import {StandardTemplateV1} from "../../src/templates/StandardTemplateV1.sol";
import {LaunchToken} from "../../src/tokens/LaunchToken.sol";
import {ILaunchExecutor, MintVault} from "../../src/vaults/MintVault.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address sender) external;
    function warp(uint256 newTimestamp) external;
}

contract MockLiquidityToken {}

contract ConfigurableLaunchExecutor is ILaunchExecutor {
    enum Mode {
        Success,
        RevertCall,
        NoOp,
        BadMagic,
        PartialToken,
        BadNativeSpend,
        Reenter,
        NonContractLiquidity
    }

    error ExecutionRejected();

    bytes4 private constant SUCCESS_MAGIC = bytes4(keccak256("MINT_VAULT_EXECUTION_SUCCESS"));
    address public constant TOKEN_SINK = address(0x1A11CE);
    uint256 public constant LP_AMOUNT = 1_000;

    address public immutable LP_TOKEN;

    Mode public mode;
    uint256 public totalReceived;
    uint256 public lastTokenAmount;
    uint256 public lastMinOutput;
    uint256 public lastDeadline;
    bool public reentrySucceeded;

    constructor() {
        LP_TOKEN = address(new MockLiquidityToken());
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function execute(address token, uint256 tokenAmount, uint256 minOutput, uint256 deadline)
        external
        payable
        returns (ExecutionResult memory result)
    {
        if (mode == Mode.RevertCall) revert ExecutionRejected();

        totalReceived += msg.value;
        lastTokenAmount = tokenAmount;
        lastMinOutput = minOutput;
        lastDeadline = deadline;

        if (mode == Mode.Reenter) {
            MintVault.FinalizeParams memory params =
                MintVault.FinalizeParams({minOutput: 0, deadline: block.timestamp + 1 hours});
            (reentrySucceeded,) = msg.sender.call(abi.encodeCall(MintVault.finalize, (params)));
        }

        if (mode == Mode.PartialToken) {
            require(LaunchToken(token).transferFrom(msg.sender, TOKEN_SINK, tokenAmount - 1), "partial transfer failed");
        } else if (mode != Mode.NoOp) {
            require(LaunchToken(token).transferFrom(msg.sender, TOKEN_SINK, tokenAmount), "token transfer failed");
        }

        result = ExecutionResult({
            magic: mode == Mode.BadMagic ? bytes4(0xdeadbeef) : SUCCESS_MAGIC,
            liquidityToken: mode == Mode.NonContractLiquidity ? address(0x1BEEF) : LP_TOKEN,
            liquidityAmount: LP_AMOUNT,
            nativeSpent: mode == Mode.BadNativeSpend ? msg.value - 1 : msg.value,
            tokenSpent: tokenAmount
        });
    }
}

contract GasBombExecutor {
    fallback() external payable {
        while (true) {}
    }
}

contract ReturnBombExecutor {
    fallback() external payable {
        assembly {
            return(0, 0x100000)
        }
    }
}

contract ForceNative {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

contract NonPayableMinter {
    function mint(MintVault vault, uint32 shares) external payable {
        vault.mint{value: msg.value}(shares);
    }

    function refundSelf(MintVault vault) external {
        vault.refund();
    }

    function refundTo(MintVault vault, address payable recipient) external {
        vault.refundTo(recipient);
    }
}

abstract contract MintVaultTestBase {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant TOKEN_SUPPLY = 1_000 ether;
    uint256 internal constant CLAIM_TOKEN_ALLOCATION = 600 ether;
    uint256 internal constant LAUNCH_TOKEN_ALLOCATION = 400 ether;
    uint256 internal constant MINIMUM_LIQUIDITY_OUTPUT = 900;
    uint32 internal constant TOTAL_SHARES = 10;
    uint96 internal constant PRICE_PER_SHARE = 1 ether;
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    ConfigurableLaunchExecutor internal executor;
    MintVault internal vault;
    LaunchToken internal token;

    function setUp() public virtual {
        executor = new ConfigurableLaunchExecutor();
        vault = _newVault(address(executor), CLAIM_TOKEN_ALLOCATION, LAUNCH_TOKEN_ALLOCATION);
        token = vault.token();
        VM.deal(ALICE, 30 ether);
        VM.deal(BOB, 30 ether);
    }

    function _newVault(address executor_, uint256 claimAllocation, uint256 launchAllocation)
        internal
        returns (MintVault)
    {
        return new MintVault(
            CREATOR,
            executor_,
            "Standard Launch",
            "STDL",
            claimAllocation,
            launchAllocation,
            MINIMUM_LIQUIDITY_OUTPUT,
            TOTAL_SHARES,
            PRICE_PER_SHARE
        );
    }

    function _mint(MintVault target, address account, uint32 shares) internal {
        VM.prank(account);
        target.mint{value: uint256(shares) * PRICE_PER_SHARE}(shares);
    }

    function _fill() internal {
        _mint(vault, ALICE, TOTAL_SHARES);
    }

    function _params() internal view returns (MintVault.FinalizeParams memory) {
        return MintVault.FinalizeParams({minOutput: 900, deadline: block.timestamp + 1 hours});
    }

    function _finalize() internal {
        bool success = vault.finalize(_params());
        require(success, "fixture finalization failed");
    }
}

contract MintVaultLifecycleTest is MintVaultTestBase {
    event MintPurchased(address indexed buyer, uint32 shares, uint256 paid, uint32 totalSharesSold);
    event Filled(uint256 totalPaid);
    event Claimed(address indexed account, uint32 shares, uint256 tokenAmount);

    function testMultiShareMintRecordsOnePaymentAndShareBalance() public {
        VM.expectEmit(true, false, false, true, address(vault));
        emit MintPurchased(ALICE, 3, 3 ether, 3);

        _mint(vault, ALICE, 3);

        require(vault.sharesOf(ALICE) == 3, "buyer shares not recorded");
        require(vault.totalSharesSold() == 3, "sold shares mismatch");
        require(vault.totalPaid() == 3 ether, "paid principal mismatch");
        require(address(vault).balance == 3 ether, "vault principal mismatch");
        require(vault.state() == MintVault.State.Funding, "partial mint changed state");
    }

    function testExactFillTransitionsOnceAndRejectsFurtherMint() public {
        _mint(vault, ALICE, 6);
        VM.expectEmit(true, false, false, true, address(vault));
        emit MintPurchased(BOB, 4, 4 ether, TOTAL_SHARES);
        VM.expectEmit(false, false, false, true, address(vault));
        emit Filled(10 ether);
        _mint(vault, BOB, 4);

        require(vault.state() == MintVault.State.Filled, "exact fill did not fill vault");
        require(vault.totalSharesSold() == TOTAL_SHARES, "exact fill share count mismatch");

        VM.prank(ALICE);
        VM.expectRevert(
            abi.encodeWithSelector(MintVault.InvalidState.selector, MintVault.State.Filled, MintVault.State.Funding)
        );
        vault.mint{value: 1 ether}(1);
    }

    function testOverfillRevertsWithoutChangingAccounting() public {
        _mint(vault, ALICE, 9);
        VM.prank(BOB);
        VM.expectRevert(abi.encodeWithSelector(MintVault.ShareCapacityExceeded.selector, 1, 2));
        vault.mint{value: 2 ether}(2);

        require(vault.totalSharesSold() == 9, "overfill changed sold shares");
        require(vault.totalPaid() == 9 ether, "overfill changed principal");
        require(vault.sharesOf(BOB) == 0, "overfill credited buyer");
    }

    function testMintRequiresNonzeroSharesAndExactPayment() public {
        VM.prank(ALICE);
        VM.expectRevert(abi.encodeWithSelector(MintVault.ZeroShares.selector));
        vault.mint(0);

        VM.prank(ALICE);
        VM.expectRevert(abi.encodeWithSelector(MintVault.IncorrectPayment.selector, 2 ether, 2 ether - 1));
        vault.mint{value: 2 ether - 1}(2);
    }

    function testLaunchConsumesOnlyLaunchAllocationAndClaimsRemainProportional() public {
        _mint(vault, ALICE, 3);
        _mint(vault, BOB, 7);
        _finalize();

        require(token.totalSupply() == TOKEN_SUPPLY, "total supply mismatch");
        require(token.balanceOf(executor.TOKEN_SINK()) == 400 ether, "launch allocation not spent");
        require(token.balanceOf(address(vault)) == 600 ether, "claim allocation not reserved");

        VM.expectEmit(true, false, false, true, address(vault));
        emit Claimed(ALICE, 3, 180 ether);
        VM.prank(ALICE);
        require(vault.claim() == 180 ether, "alice claim mismatch");

        VM.expectEmit(true, false, false, true, address(vault));
        emit Claimed(BOB, 7, 420 ether);
        VM.prank(BOB);
        require(vault.claim() == 420 ether, "bob claim mismatch");

        require(token.balanceOf(ALICE) == 180 ether, "alice token balance mismatch");
        require(token.balanceOf(BOB) == 420 ether, "bob token balance mismatch");
        require(token.balanceOf(address(vault)) == 0, "claim inventory stranded");
        require(vault.state() == MintVault.State.Closed, "settled launch not closed");
    }

    function testFinalClaimantReceivesDeterministicClaimDust() public {
        MintVault dustyVault = _newVault(address(executor), 503, 500);
        LaunchToken dustyToken = dustyVault.token();
        _mint(dustyVault, ALICE, 3);
        _mint(dustyVault, BOB, 7);
        require(dustyVault.finalize(_params()), "dust fixture finalization failed");

        VM.prank(ALICE);
        require(dustyVault.claim() == 150, "non-final floor claim mismatch");
        VM.prank(BOB);
        require(dustyVault.claim() == 353, "final claimant did not receive dust");

        require(dustyToken.balanceOf(address(dustyVault)) == 0, "dust remained after close");
        require(dustyVault.totalTokensClaimed() == 503, "claim allocation not fully distributed");
    }

    function testReturnedClaimTokensCannotIncreaseFinalClaimEntitlement() public {
        _mint(vault, ALICE, 3);
        _mint(vault, BOB, 7);
        _finalize();

        VM.prank(ALICE);
        require(vault.claim() == 180 ether, "alice claim mismatch");
        VM.prank(ALICE);
        require(token.transfer(address(vault), 1 ether), "claim return failed");

        VM.prank(BOB);
        require(vault.claim() == 420 ether, "returned tokens increased final claim");

        require(token.balanceOf(BOB) == 420 ether, "final claimant exceeded entitlement");
        require(vault.totalTokensClaimed() == 600 ether, "claim accounting exceeded allocation");
        require(token.balanceOf(address(vault)) == 1 ether, "returned token balance was misclassified as claim dust");
    }

    function testClaimAndRefundRemainMutuallyExclusive() public {
        _fill();
        _finalize();
        VM.prank(ALICE);
        vault.claim();

        VM.prank(ALICE);
        VM.expectRevert(
            abi.encodeWithSelector(MintVault.InvalidState.selector, MintVault.State.Closed, MintVault.State.Refundable)
        );
        vault.refund();
    }
}

contract MintVaultExecutionSafetyTest is MintVaultTestBase {
    function testFinalizeAtomicallyConsumesExactTokenAndNativeAmountsOnce() public {
        _fill();
        MintVault.FinalizeParams memory params = _params();

        VM.prank(BOB);
        bool success = vault.finalize(params);

        require(success, "typed execution did not succeed");
        require(vault.state() == MintVault.State.Launched, "vault not launched");
        require(vault.finalizedSpend() == 10 ether, "native spend mismatch");
        require(vault.finalizedTokenSpend() == 400 ether, "token spend mismatch");
        require(vault.liquidityToken() == executor.LP_TOKEN(), "liquidity token mismatch");
        require(vault.liquidityAmount() == executor.LP_AMOUNT(), "liquidity amount mismatch");
        require(address(vault).balance == 0, "native principal remained");
        require(address(executor).balance == 10 ether, "executor native receipt mismatch");
        require(token.balanceOf(executor.TOKEN_SINK()) == 400 ether, "executor token receipt mismatch");
        require(token.allowance(address(vault), address(executor)) == 0, "executor allowance remained");
        require(executor.lastMinOutput() == params.minOutput, "minimum output not forwarded");
        require(executor.lastDeadline() == params.deadline, "deadline not forwarded");

        VM.expectRevert(
            abi.encodeWithSelector(MintVault.InvalidState.selector, MintVault.State.Launched, MintVault.State.Filled)
        );
        vault.finalize(params);
    }

    function testForcedNativeBalanceCannotBlockExactPrincipalFinalization() public {
        _fill();
        new ForceNative{value: 1}(payable(address(vault)));

        require(address(vault).balance == 10 ether + 1, "forced native balance missing");
        require(vault.accountedPrincipalBalance() == 10 ether, "forced value changed principal accounting");
        require(vault.unsolicitedNativeBalance() == 1, "forced value not classified as unsolicited");
        require(vault.finalize(_params()), "forced native balance blocked launch");

        require(vault.state() == MintVault.State.Launched, "vault not launched");
        require(address(executor).balance == 10 ether, "executor did not receive exact paid principal");
        require(vault.accountedPrincipalBalance() == 0, "spent principal remained accounted");
        require(vault.unsolicitedNativeBalance() == 1, "launch consumed unsolicited native dust");
        require(address(vault).balance == 1, "unsolicited native dust did not remain isolated");
    }

    function testRevertingExecutionReturnsToFilledAndCanBeRetried() public {
        _fill();
        executor.setMode(ConfigurableLaunchExecutor.Mode.RevertCall);

        require(!vault.finalize(_params()), "reverting executor reported success");
        require(vault.state() == MintVault.State.Filled, "failed execution not retryable");
        require(address(vault).balance == 10 ether, "failed execution lost principal");
        require(token.balanceOf(address(vault)) == TOKEN_SUPPLY, "failed execution lost tokens");
        // The vault intentionally records the on-chain failure time.
        // forge-lint: disable-next-line(block-timestamp)
        require(vault.lastFailureAt() == block.timestamp, "failure time not recorded");

        executor.setMode(ConfigurableLaunchExecutor.Mode.Success);
        require(vault.finalize(_params()), "valid retry did not launch");
    }

    function testPartialTokenConsumptionRollsBackTokenAndNativeAtomically() public {
        _fill();
        executor.setMode(ConfigurableLaunchExecutor.Mode.PartialToken);

        require(!vault.finalize(_params()), "partial spend reported success");

        require(vault.state() == MintVault.State.Filled, "partial spend changed lifecycle");
        require(address(vault).balance == 10 ether, "partial spend lost native principal");
        require(address(executor).balance == 0, "partial spend retained native principal");
        require(token.balanceOf(address(vault)) == TOKEN_SUPPLY, "partial token spend did not roll back");
        require(token.balanceOf(executor.TOKEN_SINK()) == 0, "partial token sink transfer did not roll back");
        require(token.allowance(address(vault), address(executor)) == 0, "failed allowance did not roll back");
        require(vault.finalizedSpend() == 0, "failed native spend recorded");
        require(vault.finalizedTokenSpend() == 0, "failed token spend recorded");
    }

    function testNoOpAndFalseTypedResultsCannotLaunch() public {
        _fill();
        executor.setMode(ConfigurableLaunchExecutor.Mode.NoOp);
        require(!vault.finalize(_params()), "no-op executor launched vault");

        executor.setMode(ConfigurableLaunchExecutor.Mode.BadMagic);
        require(!vault.finalize(_params()), "bad magic launched vault");

        executor.setMode(ConfigurableLaunchExecutor.Mode.BadNativeSpend);
        require(!vault.finalize(_params()), "false native spend launched vault");

        executor.setMode(ConfigurableLaunchExecutor.Mode.NonContractLiquidity);
        require(!vault.finalize(_params()), "non-contract liquidity result launched vault");

        executor.setMode(ConfigurableLaunchExecutor.Mode.Success);
        MintVault.FinalizeParams memory unsafeMinimum =
            MintVault.FinalizeParams({minOutput: executor.LP_AMOUNT() + 1, deadline: block.timestamp + 1 hours});
        require(!vault.finalize(unsafeMinimum), "insufficient typed output launched vault");

        require(vault.state() == MintVault.State.Filled, "invalid result changed state");
        require(address(vault).balance == 10 ether, "invalid result lost native principal");
        require(token.balanceOf(address(vault)) == TOKEN_SUPPLY, "invalid result lost token inventory");
    }

    function testExecutorMustHaveContractCode() public {
        address eoa = address(0xE0A);
        VM.expectRevert(abi.encodeWithSelector(MintVault.InvalidExecutor.selector, eoa));
        _newVault(eoa, CLAIM_TOKEN_ALLOCATION, LAUNCH_TOKEN_ALLOCATION);
    }

    function testExpiredCallerDeadlineCannotCallExecutor() public {
        _fill();
        MintVault.FinalizeParams memory expired =
            MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp - 1});
        VM.expectRevert(abi.encodeWithSelector(MintVault.DeadlineExpired.selector, expired.deadline, block.timestamp));
        vault.finalize(expired);

        require(address(executor).balance == 0, "expired call reached executor");
        require(vault.state() == MintVault.State.Filled, "expired call changed state");
    }

    function testCallerCannotWeakenImmutableMinimumOutput() public {
        _fill();
        MintVault.FinalizeParams memory weakMinimum =
            MintVault.FinalizeParams({minOutput: MINIMUM_LIQUIDITY_OUTPUT - 1, deadline: block.timestamp + 1 hours});

        VM.expectRevert(
            abi.encodeWithSelector(
                MintVault.MinimumOutputTooLow.selector, MINIMUM_LIQUIDITY_OUTPUT, MINIMUM_LIQUIDITY_OUTPUT - 1
            )
        );
        vault.finalize(weakMinimum);

        require(vault.state() == MintVault.State.Filled, "weak minimum changed state");
        require(address(executor).balance == 0, "weak minimum reached executor");
    }

    function testGasBombCannotPreventFailureBookkeepingOrFilledRefund() public {
        GasBombExecutor bomb = new GasBombExecutor();
        MintVault bombVault = _newVault(address(bomb), CLAIM_TOKEN_ALLOCATION, LAUNCH_TOKEN_ALLOCATION);
        _mint(bombVault, ALICE, TOTAL_SHARES);

        require(!bombVault.finalize(_params()), "gas bomb reported success");
        require(bombVault.state() == MintVault.State.Filled, "gas bomb trapped executing state");
        // The vault intentionally records the on-chain failure time.
        // forge-lint: disable-next-line(block-timestamp)
        require(bombVault.lastFailureAt() == block.timestamp, "gas bomb erased failure time");
        require(address(bombVault).balance == 10 ether, "gas bomb lost principal");

        VM.warp(bombVault.filledAt() + 24 hours);
        bombVault.enableRefunds();
        VM.prank(ALICE);
        bombVault.refund();
        require(bombVault.state() == MintVault.State.Closed, "gas bomb prevented refund closure");
    }

    function testReturnBombCannotPreventFailureBookkeeping() public {
        ReturnBombExecutor bomb = new ReturnBombExecutor();
        MintVault bombVault = _newVault(address(bomb), CLAIM_TOKEN_ALLOCATION, LAUNCH_TOKEN_ALLOCATION);
        _mint(bombVault, ALICE, TOTAL_SHARES);

        require(!bombVault.finalize(_params()), "return bomb reported success");
        require(bombVault.state() == MintVault.State.Filled, "return bomb trapped executing state");
        require(bombVault.lastFailureHash() != bytes32(0), "return bomb erased bounded failure hash");
        require(address(bombVault).balance == 10 ether, "return bomb lost principal");
        require(bombVault.token().balanceOf(address(bombVault)) == TOKEN_SUPPLY, "return bomb lost tokens");
    }

    function testExecutorReentrancyIsRejectedWithoutBreakingValidExecution() public {
        _fill();
        executor.setMode(ConfigurableLaunchExecutor.Mode.Reenter);

        require(vault.finalize(_params()), "reentrant executor prevented valid outer execution");
        require(!executor.reentrySucceeded(), "executor reentered finalize");
        require(vault.state() == MintVault.State.Launched, "outer execution did not launch");
    }

    function testFilledExecutionWindowClosesAtExactRefundBoundary() public {
        _fill();
        uint256 refundTime = vault.filledAt() + 24 hours;
        VM.warp(refundTime);

        MintVault.FinalizeParams memory params =
            MintVault.FinalizeParams({minOutput: 0, deadline: refundTime + 1 hours});
        VM.expectRevert(abi.encodeWithSelector(MintVault.ExecutionWindowExpired.selector, refundTime, refundTime));
        vault.finalize(params);

        vault.enableRefunds();
        require(vault.state() == MintVault.State.Refundable, "exact filled boundary not refundable");
    }
}

contract MintVaultRefundSafetyTest is MintVaultTestBase {
    event RefundsEnabled(uint256 enabledAt);
    event Refunded(address indexed account, address indexed recipient, uint32 shares, uint256 nativeAmount);

    function testFundingDeadlineRejectsMintAtExactBoundaryAndEnablesRefunds() public {
        _mint(vault, ALICE, 3);
        uint256 refundTime = vault.fundingDeadline();
        VM.warp(refundTime);

        VM.prank(BOB);
        VM.expectRevert(abi.encodeWithSelector(MintVault.FundingExpired.selector, refundTime, refundTime));
        vault.mint{value: 1 ether}(1);

        VM.expectEmit(false, false, false, true, address(vault));
        emit RefundsEnabled(refundTime);
        vault.enableRefunds();
        VM.prank(ALICE);
        vault.refund();
        require(vault.state() == MintVault.State.Closed, "funding refund did not close");
    }

    function testFilledVaultNeedsNoSuccessfulFailureRecordToRefundAfterTwentyFourHours() public {
        _mint(vault, ALICE, 4);
        _mint(vault, BOB, 6);
        VM.warp(vault.filledAt() + 24 hours);

        vault.enableRefunds();
        VM.prank(ALICE);
        vault.refund();
        VM.prank(BOB);
        vault.refund();

        require(vault.totalRefunded() == 10 ether, "filled principal not refunded");
        require(address(vault).balance == 0, "filled refund retained principal");
        require(vault.state() == MintVault.State.Closed, "filled refunds did not close");
        require(token.balanceOf(address(vault)) == TOKEN_SUPPLY, "refund path moved token inventory");
    }

    function testNonPayableMinterCanAuthorizeRefundToAnotherRecipient() public {
        NonPayableMinter minter = new NonPayableMinter();
        minter.mint{value: 2 ether}(vault, 2);
        VM.warp(vault.fundingDeadline());
        vault.enableRefunds();
        uint256 aliceBefore = ALICE.balance;

        VM.expectEmit(true, true, false, true, address(vault));
        emit Refunded(address(minter), ALICE, 2, 2 ether);
        minter.refundTo(vault, payable(ALICE));

        require(ALICE.balance == aliceBefore + 2 ether, "authorized recipient not paid");
        require(vault.sharesOf(address(minter)) == 0, "redirected refund entitlement remains");
    }

    function testRawRefundFailureKeepsContractMinterEntitlement() public {
        NonPayableMinter minter = new NonPayableMinter();
        minter.mint{value: 2 ether}(vault, 2);
        VM.warp(vault.fundingDeadline());
        vault.enableRefunds();

        VM.expectRevert(abi.encodeWithSelector(MintVault.RefundTransferFailed.selector, address(minter), 2 ether));
        minter.refundSelf(vault);

        require(vault.sharesOf(address(minter)) == 2, "failed refund erased entitlement");
        require(vault.totalRefunded() == 0, "failed refund changed accounting");
        require(address(vault).balance == 2 ether, "failed refund lost principal");
    }
}

contract StandardTemplateV1Test is MintVaultTestBase {
    function testStandardTemplateDeploysPartitionedSupplyThroughFactory() public {
        address revenueRecipient = address(0x7000);
        PlatformConfig platformConfig = new PlatformConfig(address(this), revenueRecipient);
        TemplateRegistry registry = new TemplateRegistry(address(this));
        LaunchFactory factory = new LaunchFactory(address(this), registry, platformConfig);
        StandardTemplateV1 template = new StandardTemplateV1(address(factory), address(executor));
        bytes32 templateId = keccak256("standard");
        registry.register(templateId, 1, address(template), keccak256("standard-v1-schema"));

        LaunchTypes.CommonConfig memory common = LaunchTypes.CommonConfig({
            name: "Factory Launch",
            symbol: "FACT",
            supply: 2_000,
            buyTaxBps: 0,
            sellTaxBps: 0,
            receiver: CREATOR,
            rewardToken: address(0),
            rewardThreshold: 0,
            lpMode: 0,
            allocationBps: [uint16(0), uint16(0), uint16(0), uint16(0)],
            metadataHash: keccak256("factory-launch")
        });
        StandardTemplateV1.StandardConfig memory standard = StandardTemplateV1.StandardConfig({
            totalShares: 20, pricePerShare: 0.5 ether, claimTokenBps: 6_000, minimumLiquidityOutput: 900
        });
        uint256 fee = platformConfig.fee();
        VM.deal(ALICE, fee);

        VM.prank(ALICE);
        (address tokenAddress, address vaultAddress) =
            factory.deploy{value: fee}(templateId, 1, abi.encode(common), abi.encode(standard));

        MintVault deployedVault = MintVault(payable(vaultAddress));
        LaunchToken deployedToken = LaunchToken(tokenAddress);
        require(deployedVault.claimTokenAllocation() == 1_200 ether, "claim partition mismatch");
        require(deployedVault.launchTokenAllocation() == 800 ether, "launch partition mismatch");
        require(deployedToken.totalSupply() == 2_000 ether, "whole-token supply scaling mismatch");
        require(deployedToken.balanceOf(vaultAddress) == 2_000 ether, "supply not minted solely to vault");
    }

    function testStandardTemplateRejectsDirectDeployment() public {
        StandardTemplateV1 template = new StandardTemplateV1(address(0xFAc7), address(executor));
        LaunchTypes.CommonConfig memory common = LaunchTypes.CommonConfig({
            name: "Factory Launch",
            symbol: "FACT",
            supply: 2_000,
            buyTaxBps: 0,
            sellTaxBps: 0,
            receiver: CREATOR,
            rewardToken: address(0),
            rewardThreshold: 0,
            lpMode: 0,
            allocationBps: [uint16(0), uint16(0), uint16(0), uint16(0)],
            metadataHash: keccak256("factory-launch")
        });
        StandardTemplateV1.StandardConfig memory standard = StandardTemplateV1.StandardConfig({
            totalShares: 20, pricePerShare: 0.5 ether, claimTokenBps: 6_000, minimumLiquidityOutput: 900
        });

        VM.expectRevert(abi.encodeWithSelector(StandardTemplateV1.UnauthorizedFactory.selector, address(this)));
        template.deploy(CREATOR, abi.encode(common), abi.encode(standard));
    }
}

contract LaunchTokenTest is MintVaultTestBase {
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function testTokenAllowanceAuthorizesTransferFromAndDecrements() public {
        _fill();
        _finalize();
        VM.prank(ALICE);
        vault.claim();

        VM.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, BOB, 100 ether);
        VM.prank(ALICE);
        require(token.approve(BOB, 100 ether), "approval failed");

        VM.prank(BOB);
        require(token.transferFrom(ALICE, CREATOR, 40 ether), "transferFrom failed");
        require(token.balanceOf(CREATOR) == 40 ether, "recipient balance mismatch");
        require(token.allowance(ALICE, BOB) == 60 ether, "allowance not decremented");
    }
}
