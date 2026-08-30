// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchToken} from "../../src/tokens/LaunchToken.sol";
import {ILaunchExecutor, MintVault} from "../../src/vaults/MintVault.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function prank(address sender) external;
    function warp(uint256 newTimestamp) external;
}

contract InvariantLiquidityToken {}

contract StatefulAccountingExecutor is ILaunchExecutor {
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

    bytes4 private constant SUCCESS_MAGIC = bytes4(keccak256("MINT_VAULT_EXECUTION_SUCCESS"));
    address public constant TOKEN_SINK = address(0x51A6);
    address public immutable LP_TOKEN;

    Mode public mode;
    bool public reentrySucceeded;

    constructor() {
        LP_TOKEN = address(new InvariantLiquidityToken());
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function execute(address token, uint256 tokenAmount, uint256, uint256 deadline)
        external
        payable
        returns (ExecutionResult memory result)
    {
        if (mode == Mode.RevertCall) revert("configured failure");

        if (mode == Mode.Reenter) {
            MintVault.FinalizeParams memory params = MintVault.FinalizeParams({minOutput: 0, deadline: deadline});
            (reentrySucceeded,) = msg.sender.call(abi.encodeCall(MintVault.finalize, (params)));
        }

        if (mode == Mode.PartialToken) {
            require(LaunchToken(token).transferFrom(msg.sender, TOKEN_SINK, tokenAmount - 1), "partial transfer failed");
        } else if (mode != Mode.NoOp) {
            require(LaunchToken(token).transferFrom(msg.sender, TOKEN_SINK, tokenAmount), "token transfer failed");
        }

        result = ExecutionResult({
            magic: mode == Mode.BadMagic ? bytes4(0) : SUCCESS_MAGIC,
            liquidityToken: mode == Mode.NonContractLiquidity ? address(0x1BEEF) : LP_TOKEN,
            liquidityAmount: 1,
            nativeSpent: mode == Mode.BadNativeSpend ? msg.value - 1 : msg.value,
            tokenSpent: tokenAmount
        });
    }
}

contract MintAccountingHandler {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant ACTOR_INITIAL_BALANCE = 100 ether;
    address public constant REFUND_RECIPIENT = address(0x5E771E);

    MintVault public immutable vault;
    StatefulAccountingExecutor public immutable executor;
    LaunchToken public immutable token;

    uint256 public paidBNB;
    uint256 public refundedBNB;
    uint256 public forcedBNB;
    uint256 public returnedClaimTokens;
    uint256 public executionAttempts;
    uint256 public failedExecutions;

    constructor(MintVault vault_, StatefulAccountingExecutor executor_) {
        vault = vault_;
        executor = executor_;
        token = vault_.token();
        for (uint8 index; index < 4; ++index) {
            VM.deal(actor(index), ACTOR_INITIAL_BALANCE);
        }
    }

    function setExecutorMode(uint8 modeSeed) external {
        executor.setMode(StatefulAccountingExecutor.Mode(modeSeed % 8));
    }

    function mint(uint8 actorSeed, uint32 rawShares) external {
        // The handler must respect the same exact funding boundary as the vault.
        // forge-lint: disable-next-line(block-timestamp)
        if (vault.state() != MintVault.State.Funding || block.timestamp >= vault.fundingDeadline()) return;
        uint32 remaining = vault.totalShares() - vault.totalSharesSold();
        if (remaining == 0) return;

        uint32 shares = uint32((uint256(rawShares) % remaining) + 1);
        address buyer = actor(actorSeed);
        uint256 payment = uint256(shares) * vault.pricePerShare();
        if (buyer.balance < payment) return;

        VM.prank(buyer);
        vault.mint{value: payment}(shares);
        paidBNB += payment;
    }

    function finalize(uint256 minOutput) external {
        // The handler keeps execution attempts inside the immutable execution window.
        // forge-lint: disable-next-line(block-timestamp)
        if (vault.state() != MintVault.State.Filled || block.timestamp >= vault.filledAt() + 24 hours) return;

        ++executionAttempts;
        bool success = vault.finalize(
            MintVault.FinalizeParams({minOutput: (minOutput % 2) + 1, deadline: block.timestamp + 1 hours})
        );
        if (!success) ++failedExecutions;
    }

    function forceNative(uint96 rawAmount) external {
        _forceNative(rawAmount);
    }

    function forceNativeAndFinalize(uint96 rawAmount) external {
        // The combined action proves that unsolicited native value cannot disable a valid launch.
        // forge-lint: disable-next-line(block-timestamp)
        if (vault.state() != MintVault.State.Filled || block.timestamp >= vault.filledAt() + 24 hours) return;

        _forceNative(rawAmount);
        executor.setMode(StatefulAccountingExecutor.Mode.Success);
        ++executionAttempts;
        bool success = vault.finalize(MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp + 1 hours}));
        require(success, "forced native balance blocked valid launch");
    }

    function failExecutionAndOpenFilledRefund(uint8 failureSeed) external {
        // The handler deliberately drives the pre-deadline funding path.
        // forge-lint: disable-next-line(block-timestamp)
        if (vault.state() == MintVault.State.Funding && block.timestamp < vault.fundingDeadline()) {
            uint32 remaining = vault.totalShares() - vault.totalSharesSold();
            address buyer = actor(0);
            uint256 payment = uint256(remaining) * vault.pricePerShare();
            if (remaining == 0 || buyer.balance < payment) return;
            VM.prank(buyer);
            vault.mint{value: payment}(remaining);
            paidBNB += payment;
        }
        // The hostile attempt must occur before the filled refund boundary.
        // forge-lint: disable-next-line(block-timestamp)
        if (vault.state() != MintVault.State.Filled || block.timestamp >= vault.filledAt() + 24 hours) return;

        executor.setMode(StatefulAccountingExecutor.Mode((failureSeed % 5) + 1));
        ++executionAttempts;
        bool success = vault.finalize(MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp + 1 hours}));
        if (success) return;

        ++failedExecutions;
        VM.warp(vault.filledAt() + 24 hours);
        vault.enableRefunds();
    }

    function advanceToRefund() external {
        if (vault.state() == MintVault.State.Funding) {
            VM.warp(vault.fundingDeadline());
            vault.enableRefunds();
        } else if (vault.state() == MintVault.State.Filled) {
            VM.warp(vault.filledAt() + 24 hours);
            vault.enableRefunds();
        }
    }

    function refund(uint8 actorSeed) external {
        if (vault.state() != MintVault.State.Refundable) return;
        address buyer = actor(actorSeed);
        uint32 shares = vault.sharesOf(buyer);
        if (shares == 0) return;

        uint256 expectedRefund = uint256(shares) * vault.pricePerShare();
        VM.prank(buyer);
        vault.refund();
        refundedBNB += expectedRefund;
    }

    function refundTo(uint8 actorSeed) external {
        if (vault.state() != MintVault.State.Refundable) return;
        address buyer = actor(actorSeed);
        uint32 shares = vault.sharesOf(buyer);
        if (shares == 0) return;

        uint256 expectedRefund = uint256(shares) * vault.pricePerShare();
        VM.prank(buyer);
        vault.refundTo(payable(REFUND_RECIPIENT));
        refundedBNB += expectedRefund;
    }

    function claim(uint8 actorSeed) external {
        if (vault.state() != MintVault.State.Launched) return;
        address buyer = actor(actorSeed);
        if (vault.sharesOf(buyer) == 0) return;
        VM.prank(buyer);
        vault.claim();
    }

    function returnClaimTokens(uint8 actorSeed, uint256 rawAmount) external {
        address claimant = actor(actorSeed);
        uint256 balance = token.balanceOf(claimant);
        if (balance == 0) return;

        uint256 amount = (rawAmount % balance) + 1;
        VM.prank(claimant);
        require(token.transfer(address(vault), amount), "claim token return failed");
        returnedClaimTokens += amount;
    }

    function actor(uint8 actorSeed) public pure returns (address) {
        return address(uint160(0x1000 + (actorSeed % 4)));
    }

    function _forceNative(uint96 rawAmount) private {
        uint256 amount = (uint256(rawAmount) % 1 ether) + 1;
        VM.deal(address(vault), address(vault).balance + amount);
        forcedBNB += amount;
    }
}

contract MintAccountingInvariantTest {
    uint256 private constant CLAIM_TOKEN_ALLOCATION = 503;
    uint256 private constant LAUNCH_TOKEN_ALLOCATION = 500;
    uint256 private constant TOKEN_SUPPLY = CLAIM_TOKEN_ALLOCATION + LAUNCH_TOKEN_ALLOCATION;
    uint32 private constant TOTAL_SHARES = 37;
    uint96 private constant PRICE_PER_SHARE = 0.125 ether;

    StatefulAccountingExecutor private executor;
    MintVault private vault;
    MintAccountingHandler private handler;
    LaunchToken private token;

    function setUp() public {
        executor = new StatefulAccountingExecutor();
        vault = new MintVault(
            address(this),
            address(executor),
            "Invariant Launch",
            "INV",
            CLAIM_TOKEN_ALLOCATION,
            LAUNCH_TOKEN_ALLOCATION,
            1,
            TOTAL_SHARES,
            PRICE_PER_SHARE
        );
        token = vault.token();
        handler = new MintAccountingHandler(vault, executor);
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_paidPrincipalIsConservedThroughSuccessAndFailure() public view {
        require(vault.totalPaid() == handler.paidBNB(), "contract and ghost paid accounting diverged");
        require(vault.totalRefunded() == handler.refundedBNB(), "contract and ghost refund accounting diverged");
        require(
            vault.accountedPrincipalBalance() + vault.finalizedSpend() + vault.totalRefunded() == handler.paidBNB(),
            "principal + finalized spend + refunded BNB != paid BNB"
        );
        require(
            address(vault).balance == vault.accountedPrincipalBalance() + handler.forcedBNB(),
            "raw vault balance did not separate principal from forced BNB"
        );
        require(vault.unsolicitedNativeBalance() == handler.forcedBNB(), "unsolicited native accounting diverged");
        require(address(executor).balance == vault.finalizedSpend(), "actual executor BNB and spend diverged");
    }

    function invariant_actualNativeBalancesRemainClosed() public view {
        uint256 actualBalanceTotal =
            address(vault).balance + address(executor).balance + handler.REFUND_RECIPIENT().balance;
        for (uint8 index; index < 4; ++index) {
            actualBalanceTotal += handler.actor(index).balance;
        }
        require(
            actualBalanceTotal == 4 * handler.ACTOR_INITIAL_BALANCE() + handler.forcedBNB(), "actual BNB left system"
        );
    }

    function invariant_actualTokenBalancesPreserveSupplyAndPartitions() public view {
        uint256 claimantBalances;
        for (uint8 index; index < 4; ++index) {
            claimantBalances += token.balanceOf(handler.actor(index));
        }
        uint256 launchBalance = token.balanceOf(executor.TOKEN_SINK());
        uint256 actualSupply = token.balanceOf(address(vault)) + claimantBalances + launchBalance;

        require(actualSupply == TOKEN_SUPPLY, "actual token balances do not sum to supply");
        require(
            claimantBalances + handler.returnedClaimTokens() == vault.totalTokensClaimed(),
            "actual claims, returns, and claim accounting diverged"
        );
        require(vault.totalTokensClaimed() <= CLAIM_TOKEN_ALLOCATION, "claim accounting exceeded allocation");
        if (vault.state() == MintVault.State.Launched || vault.finalizedSpend() != 0) {
            require(launchBalance == LAUNCH_TOKEN_ALLOCATION, "launch partition not consumed exactly");
            require(
                token.balanceOf(address(vault)) + claimantBalances == CLAIM_TOKEN_ALLOCATION, "claim partition changed"
            );
        } else {
            require(launchBalance == 0, "failed/refund path leaked launch tokens");
        }
        require(!executor.reentrySucceeded(), "executor reentered vault lifecycle");
    }

    function invariant_closedStateSettlesAllAccountedAssets() public view {
        if (vault.state() != MintVault.State.Closed) return;
        require(vault.accountedPrincipalBalance() == 0, "closed vault retained user principal");
        require(address(vault).balance == handler.forcedBNB(), "closed vault moved unsolicited BNB");

        if (vault.totalClaimedShares() == TOTAL_SHARES) {
            require(vault.totalTokensClaimed() == CLAIM_TOKEN_ALLOCATION, "closed claims left allocation unpaid");
            require(
                token.balanceOf(address(vault)) == handler.returnedClaimTokens(),
                "closed claims misclassified returned tokens"
            );
        } else {
            require(vault.totalRefundedShares() == vault.totalSharesSold(), "closed refunds left shares unsettled");
            require(token.balanceOf(address(vault)) == TOKEN_SUPPLY, "refund closure moved token inventory");
        }
    }
}
