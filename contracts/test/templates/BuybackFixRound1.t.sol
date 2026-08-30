// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TargetCompatibilityRegistry} from "../../src/core/TargetCompatibilityRegistry.sol";
import {LaunchTypes} from "../../src/core/LaunchTypes.sol";
import {BuybackTaxProcessor} from "../../src/modules/BuybackTaxProcessor.sol";
import {
    AutoBuybackTemplateV1,
    BuybackCompanionDeployer,
    BuybackLiquidityDeployer,
    BuybackMintVault,
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
import {ILaunchExecutor, MintVault} from "../../src/vaults/MintVault.sol";

interface VmFix {
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

interface IFixToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);
}

interface IRound2Processor {
    function accountedTaxTokens() external view returns (uint256);
    function commitRewardFloor(uint256 tokenAmount, uint256 minimumOutput, uint256 expiry) external;
    function holderRewardVault() external view returns (address);
    function liquidityAdapter() external view returns (address);
    function pendingLiquidityTokens() external view returns (uint256);
    function unaccountedTaxTokenBalance() external view returns (uint256);
}

interface IRound3Processor {
    function availableLiquidityTokens() external view returns (uint256);
    function commitLiquidityFloor(
        uint256 tokenDesired,
        uint256 nativeDesired,
        uint256 tokenMinimum,
        uint256 nativeMinimum,
        uint256 liquidityMinimum,
        uint256 expiry
    ) external;
    function pendingLiquidityNative() external view returns (uint256);
    function pendingLiquidityUnsplitTokens() external view returns (uint256);
    function processLiquidity(uint256 deadline)
        external
        returns (uint256 tokenSpent, uint256 nativeSpent, uint256 liquidityMinted);
    function unaccountedNativeBalance() external view returns (uint256);
}

interface IRound2MintVault {
    function holderRewardVault() external view returns (address);
}

interface IRound2HolderRewards {
    function claimRewards() external returns (uint256);
    function pendingRewards(address account) external view returns (uint256);
    function totalClaimed() external view returns (uint256);
    function totalFunded() external view returns (uint256);
    function weightOf(address account) external view returns (uint256);
    function rewardAccounting() external view returns (address);
}

contract FixToken {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    uint256 public totalSupply;
    uint16 public immutable feeBps;
    bool public immutable falseTransfer;

    constructor(uint16 feeBps_, bool falseTransfer_) {
        feeBps = feeBps_;
        falseTransfer = falseTransfer_;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        if (falseTransfer) return false;
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        if (falseTransfer) return false;
        uint256 allowed = allowance[owner][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[owner][msg.sender] = allowed - amount;
        _transfer(owner, recipient, amount);
        return true;
    }

    function _transfer(address owner, address recipient, uint256 amount) private {
        require(balanceOf[owner] >= amount, "balance");
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount * (10_000 - feeBps) / 10_000;
    }
}

contract SpoofFixToken is FixToken {
    constructor() FixToken(0, false) {}

    function spoofMarker() external pure returns (bytes32) {
        return keccak256("spoof");
    }
}

contract MalformedBalanceToken {
    fallback() external {
        bytes4 selector;
        assembly ("memory-safe") {
            selector := calldataload(0)
        }
        if (selector == bytes4(keccak256("balanceOf(address)"))) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 1)
            }
        }
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

contract FixPair {
    address public token0;
    address public token1;
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    mapping(address token => uint256 amount) public reserveOf;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function transferToken(address token, address recipient, uint256 amount) external {
        require(IFixToken(token).transfer(recipient, amount), "pair transfer");
        reserveOf[token] -= amount;
    }

    function setMembers(address token0_, address token1_) external {
        token0 = token0_;
        token1 = token1_;
    }

    function syncToken(address token) external {
        reserveOf[token] = IFixToken(token).balanceOf(address(this));
    }

    function skimableToken(address token) external view returns (uint256) {
        return IFixToken(token).balanceOf(address(this)) - reserveOf[token];
    }

    function mintLp(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
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
        require(allowed >= amount, "lp allowance");
        allowance[owner][msg.sender] = allowed - amount;
        _transfer(owner, recipient, amount);
        return true;
    }

    function _transfer(address owner, address recipient, uint256 amount) private {
        require(balanceOf[owner] >= amount, "lp balance");
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount;
    }
}

contract FixFactory {
    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = getPair[tokenA][tokenB];
        if (pair != address(0)) return pair;
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new FixPair(token0, token1));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }

    function remapPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract FixRouter {
    address public factory;
    address public WETH;
    uint16 public quoteBps = 10_000;
    uint16 public outputBps = 10_000;
    bool public ignoreMinimum;
    address public forceRecipient;
    uint256 public forceAmount;
    uint256 public liquidityTokenReserve = 1 ether;
    uint256 public liquidityNativeReserve = 1 ether;
    uint8 public liquidityReportMode;

    constructor(address factory_, address wbnb_) {
        factory = factory_;
        WETH = wbnb_;
    }

    receive() external payable {}

    function setRoute(address factory_, address wbnb_) external {
        factory = factory_;
        WETH = wbnb_;
    }

    function setMarket(uint16 quoteBps_, uint16 outputBps_, bool ignoreMinimum_) external {
        quoteBps = quoteBps_;
        outputBps = outputBps_;
        ignoreMinimum = ignoreMinimum_;
    }

    function setForcedCredit(address recipient, uint256 amount) external {
        forceRecipient = recipient;
        forceAmount = amount;
    }

    function setLiquidityReserves(uint256 tokenReserve, uint256 nativeReserve) external {
        require(tokenReserve != 0 && nativeReserve != 0, "zero reserve");
        liquidityTokenReserve = tokenReserve;
        liquidityNativeReserve = nativeReserve;
    }

    function setLiquidityReportMode(uint8 mode) external {
        require(mode <= 3, "report mode");
        liquidityReportMode = mode;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(path.length == 2 || path.length == 3, "path");
        for (uint256 index; index + 1 < path.length; ++index) {
            require(FixFactory(factory).getPair(path[index], path[index + 1]) != address(0), "pair");
        }
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 index = 1; index < path.length; ++index) {
            amounts[index] = amounts[index - 1] * quoteBps / 10_000;
        }
    }

    function swapExactETHForTokens(uint256 minimum, address[] calldata path, address recipient, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        uint256 output = msg.value * outputBps / 10_000;
        require(ignoreMinimum || output >= minimum, "minimum");
        address pair = FixFactory(factory).getPair(path[0], path[1]);
        FixPair(pair).transferToken(path[1], recipient, output);
        if (forceAmount != 0) {
            (bool sent,) = payable(forceRecipient).call{value: forceAmount}("");
            require(sent, "forced callback");
        }
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = output;
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 minimum,
        address[] calldata path,
        address recipient,
        uint256
    ) external returns (uint256[] memory amounts) {
        uint256 output = amountIn * outputBps / 10_000;
        require(ignoreMinimum || output >= minimum, "minimum");
        address pair = FixFactory(factory).getPair(path[0], path[1]);
        require(IFixToken(path[0]).transferFrom(msg.sender, pair, amountIn), "router pull");
        FixPair(pair).syncToken(path[0]);
        (bool sent,) = payable(recipient).call{value: output}("");
        require(sent, "native output");
        if (forceAmount != 0) {
            (sent,) = payable(forceRecipient).call{value: forceAmount}("");
            require(sent, "forced callback");
        }
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = output;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 minimum,
        address[] calldata path,
        address recipient,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(path.length == 3, "reward path");
        uint256 output = amountIn * outputBps / 10_000;
        require(ignoreMinimum || output >= minimum, "minimum");
        address inputPair = FixFactory(factory).getPair(path[0], path[1]);
        require(IFixToken(path[0]).transferFrom(msg.sender, inputPair, amountIn), "router pull");
        FixPair(inputPair).syncToken(path[0]);
        address outputPair = FixFactory(factory).getPair(path[1], path[2]);
        FixPair(outputPair).transferToken(path[2], recipient, output);
        amounts = new uint256[](3);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
        amounts[2] = output;
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountNativeMin,
        address recipient,
        uint256
    ) external payable returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        address pair = FixFactory(factory).getPair(token, WETH);
        uint256 tokenOptimal = msg.value * liquidityTokenReserve / liquidityNativeReserve;
        if (tokenOptimal <= amountTokenDesired) {
            amountToken = tokenOptimal;
            amountNative = msg.value;
        } else {
            amountToken = amountTokenDesired;
            amountNative = amountTokenDesired * liquidityNativeReserve / liquidityTokenReserve;
        }
        require(amountToken >= amountTokenMin && amountNative >= amountNativeMin, "liquidity minimum");
        require(IFixToken(token).transferFrom(msg.sender, pair, amountToken), "liquidity pull");
        FixPair(pair).syncToken(token);
        FixToken(WETH).mint(pair, amountNative);
        FixPair(pair).syncToken(WETH);
        if (amountNative != msg.value) {
            (bool refunded,) = payable(msg.sender).call{value: msg.value - amountNative}("");
            require(refunded, "liquidity refund");
        }
        liquidity = amountNative;
        FixPair(pair).mintLp(recipient, liquidity);
        if (liquidityReportMode == 1) amountToken += 1;
        if (liquidityReportMode == 2) amountNative += 1;
        if (liquidityReportMode == 3) liquidity += 1;
    }
}

contract FixLaunchExecutor is ILaunchExecutor {
    FixFactory public immutable factory;
    address public immutable wbnb;

    constructor(FixFactory factory_, address wbnb_) {
        factory = factory_;
        wbnb = wbnb_;
    }

    function execute(address token, uint256 tokenAmount, uint256 minOutput, uint256)
        external
        payable
        returns (ExecutionResult memory result)
    {
        address pair = factory.createPair(token, wbnb);
        require(IFixToken(token).transferFrom(msg.sender, pair, tokenAmount), "launch transfer");
        FixPair(pair).syncToken(token);
        result = ExecutionResult({
            magic: bytes4(keccak256("MINT_VAULT_EXECUTION_SUCCESS")),
            liquidityToken: pair,
            liquidityAmount: minOutput,
            nativeSpent: msg.value,
            tokenSpent: tokenAmount
        });
    }
}

contract ForceNativeFix {
    constructor() payable {}

    function force(address payable recipient) external {
        selfdestruct(recipient);
    }
}

contract BuybackFixRound1Test {
    VmFix private constant VM = VmFix(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BOB = address(0xB0B);
    bytes32 private constant COMPANION_EVENT_SIG =
        keccak256("BuybackCompanionDeployed(bytes32,uint32,address,address,address,bytes32)");

    FixToken private wbnb;
    FixToken private target;
    FixFactory private pancakeFactory;
    FixRouter private router;
    FixLaunchExecutor private executor;
    TargetCompatibilityRegistry private registry;
    bytes32 private pairCodehash;
    TrustedCompanionDeployers private trustedDeployers;

    function setUp() public {
        VM.warp(100);
        wbnb = new FixToken(0, false);
        target = new FixToken(0, false);
        pancakeFactory = new FixFactory();
        address pair = pancakeFactory.createPair(address(wbnb), address(target));
        pairCodehash = pair.codehash;
        target.mint(pair, 1_000_000 ether);
        FixPair(pair).syncToken(address(target));
        router = new FixRouter(address(pancakeFactory), address(wbnb));
        executor = new FixLaunchExecutor(pancakeFactory, address(wbnb));
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
            pairCodehash: pairCodehash,
            lpAdapterCodehash: address(lpAdapter).codehash
        });
        BuybackLiquidityDeployer liquidityDeployer = new BuybackLiquidityDeployer(
            address(router), address(wbnb), address(lpAdapter), address(0), liquidityTrusted
        );
        BuybackTaxProcessorDeployer taxProcessorDeployer =
            new BuybackTaxProcessorDeployer(rewardDeployer, liquidityDeployer);
        BuybackProjectDeployer projectDeployer = new BuybackProjectDeployer();
        registry = new TargetCompatibilityRegistry(address(this));
        registry.setApprovedCodehash(address(target).codehash, true);
        VM.deal(address(router), 1_000_000 ether);
        VM.deal(address(this), 1_000_000 ether);
        trustedDeployers = TrustedCompanionDeployers({
            buybackVaultDeployer: address(vaultDeployer),
            taxProcessorDeployer: address(taxProcessorDeployer),
            projectDeployer: address(projectDeployer),
            buybackVaultDeployerCodehash: address(vaultDeployer).codehash,
            taxProcessorDeployerCodehash: address(taxProcessorDeployer).codehash,
            projectDeployerCodehash: address(projectDeployer).codehash
        });
    }

    function testMissingAndStaleIndependentFloorBlockPermissionlessExecution() public {
        BuybackVault vault = _newDirectVault(target, 1 ether, 1 ether, 0, false);
        _fund(vault, 1 ether);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.MissingExecutionFloor.selector));
        vault.executeBuyback(0, block.timestamp + 1 hours);

        vault.commitExecutionFloor(1 ether, 1 ether, block.timestamp + 10);
        VM.warp(block.timestamp + 11);
        VM.expectRevert(abi.encodeWithSelector(BuybackVault.StaleExecutionFloor.selector, 110, 111));
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testManipulatedSpotQuoteCannotWeakenIndependentFloor() public {
        BuybackVault vault = _newDirectVault(target, 1 ether, 1 ether, 0, false);
        _fund(vault, 1 ether);
        vault.commitExecutionFloor(1 ether, 0.9 ether, block.timestamp + 1 hours);
        router.setMarket(1_000, 8_000, true);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InsufficientOutput.selector, 0.9 ether, 0.8 ether));
        vault.executeBuyback(0, block.timestamp + 1 hours);
        require(vault.accountedFunds() == 1 ether, "failed price check spent funds");
    }

    function testForcedNativeAndRouterCallbackCreditAreNeverAccountedOrSpent() public {
        BuybackVault vault = _newDirectVault(target, 1 ether, 2 ether, 0, false);
        _fund(vault, 2 ether);
        ForceNativeFix force = new ForceNativeFix{value: 5 ether}();
        force.force(payable(address(vault)));
        router.setForcedCredit(address(vault), 1 ether);
        vault.commitExecutionFloor(2 ether, 2 ether, block.timestamp + 1 hours);

        (uint256 spent,) = vault.executeBuyback(0, block.timestamp + 1 hours);

        require(spent == 2 ether, "forced native became spendable");
        require(vault.accountedFunds() == 0, "accounted funds not consumed");
        require(address(vault).balance == 6 ether, "forced/callback native accounting changed");
        require(vault.unsolicitedNativeBalance() == 6 ether, "forced native became accounted");
    }

    function testRuntimeRouterFactoryMutationIsRejectedAgainstPinnedRoute() public {
        BuybackVault vault = _newDirectVault(target, 1 ether, 1 ether, 0, false);
        _fund(vault, 1 ether);
        vault.commitExecutionFloor(1 ether, 1 ether, block.timestamp + 1 hours);
        FixFactory replacement = new FixFactory();
        router.setRoute(address(replacement), address(wbnb));

        VM.expectRevert(
            abi.encodeWithSelector(
                BuybackVault.UnexpectedRouterRoute.selector,
                address(pancakeFactory),
                address(replacement),
                address(wbnb),
                address(wbnb)
            )
        );
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testRuntimeRouterWbnbMutationIsRejectedAgainstPinnedRoute() public {
        BuybackVault vault = _newDirectVault(target, 1 ether, 1 ether, 0, false);
        _fund(vault, 1 ether);
        vault.commitExecutionFloor(1 ether, 1 ether, block.timestamp + 1 hours);
        FixToken replacement = new FixToken(0, false);
        router.setRoute(address(pancakeFactory), address(replacement));

        VM.expectRevert(
            abi.encodeWithSelector(
                BuybackVault.UnexpectedRouterRoute.selector,
                address(pancakeFactory),
                address(pancakeFactory),
                address(wbnb),
                address(replacement)
            )
        );
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testTaxProcessorRejectsRuntimeRouterRouteMutation() public {
        AutoBuybackTemplateV1 template = _autoTemplate();
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        AutoBuybackTemplateV1.AutoBuybackConfig memory buyback =
            AutoBuybackTemplateV1.AutoBuybackConfig({threshold: 1 ether, maxSpend: 1 ether, maxSlippageBps: 500});
        (address tokenAddress, address mintVaultAddress) =
            template.deploy(CREATOR, abi.encode(common), abi.encode(_standard(), buyback));
        BuybackMintVault mintVault = BuybackMintVault(payable(mintVaultAddress));
        VM.deal(CREATOR, 2 ether);
        VM.prank(CREATOR);
        mintVault.mint{value: 1 ether}(100);
        mintVault.finalize(MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp + 1 hours}));
        VM.prank(CREATOR);
        mintVault.claim();
        address pair = mintVault.liquidityToken();
        VM.prank(CREATOR);
        require(LaunchToken(tokenAddress).transfer(pair, 100 ether), "sell transfer failed");

        BuybackTaxProcessor processor = mintVault.taxProcessor();
        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        FixFactory replacementFactory = new FixFactory();
        router.setRoute(address(replacementFactory), address(wbnb));
        VM.expectRevert(
            abi.encodeWithSelector(
                BuybackTaxProcessor.UnexpectedRouterRoute.selector,
                address(pancakeFactory),
                address(replacementFactory),
                address(wbnb),
                address(wbnb)
            )
        );
        processor.processTax(0, block.timestamp + 1 hours);

        FixToken replacementWbnb = new FixToken(0, false);
        router.setRoute(address(pancakeFactory), address(replacementWbnb));
        VM.expectRevert(
            abi.encodeWithSelector(
                BuybackTaxProcessor.UnexpectedRouterRoute.selector,
                address(pancakeFactory),
                address(pancakeFactory),
                address(wbnb),
                address(replacementWbnb)
            )
        );
        processor.processTax(0, block.timestamp + 1 hours);
        require(LaunchToken(tokenAddress).balanceOf(address(processor)) == 10 ether, "mutation spent tax funds");
    }

    function testZeroIndependentMinimumIsRejectedEvenWhenSpotRoundsToZero() public {
        BuybackVault vault = _newDirectVault(target, 1, 1, 0, false);

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InvalidExecutionFloor.selector));
        vault.commitExecutionFloor(1, 0, block.timestamp + 1 hours);
    }

    function testExternalCreationRejectsUnapprovedAndFeeOnTransferCodehashes() public {
        FixToken unapproved = new SpoofFixToken();
        pancakeFactory.createPair(address(wbnb), address(unapproved));
        ExternalBurnTemplateV1 template = _externalTemplate();
        ExternalBurnTemplateV1.ExternalBurnConfig memory config = ExternalBurnTemplateV1.ExternalBurnConfig({
            targetToken: address(unapproved), threshold: 1 ether, maxSpend: 1 ether, maxSlippageBps: 500
        });

        VM.expectRevert(
            abi.encodeWithSelector(
                TargetCompatibilityRegistry.UnapprovedTargetCodehash.selector, address(unapproved).codehash
            )
        );
        template.deploy(CREATOR, abi.encode(_common(0, 0)), abi.encode(_standard(), config));

        FixToken feeToken = new FixToken(1_000, false);
        pancakeFactory.createPair(address(wbnb), address(feeToken));
        VM.expectRevert(
            abi.encodeWithSelector(
                TargetCompatibilityRegistry.UnapprovedTargetCodehash.selector, address(feeToken).codehash
            )
        );
        config.targetToken = address(feeToken);
        template.deploy(CREATOR, abi.encode(_common(0, 0)), abi.encode(_standard(), config));
    }

    function testApprovedProfileStillRejectsFalseTransferAndMalformedBalanceOf() public {
        ExternalBurnTemplateV1 template = _externalTemplate();
        FixToken falseToken = new FixToken(0, true);
        pancakeFactory.createPair(address(wbnb), address(falseToken));
        registry.setApprovedCodehash(address(falseToken).codehash, true);
        ExternalBurnTemplateV1.ExternalBurnConfig memory config = ExternalBurnTemplateV1.ExternalBurnConfig({
            targetToken: address(falseToken), threshold: 1 ether, maxSpend: 1 ether, maxSlippageBps: 500
        });

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.IncompatibleTargetToken.selector, address(falseToken)));
        template.deploy(CREATOR, abi.encode(_common(0, 0)), abi.encode(_standard(), config));

        MalformedBalanceToken malformed = new MalformedBalanceToken();
        pancakeFactory.createPair(address(wbnb), address(malformed));
        registry.setApprovedCodehash(address(malformed).codehash, true);
        config.targetToken = address(malformed);
        VM.expectRevert(abi.encodeWithSelector(BuybackVault.IncompatibleTargetToken.selector, address(malformed)));
        template.deploy(CREATOR, abi.encode(_common(0, 0)), abi.encode(_standard(), config));
    }

    function testTaxedLaunchFundsAccountedBuybackThenBurnsDirectlyToDead() public {
        AutoBuybackTemplateV1 template = _autoTemplate();
        LaunchTypes.CommonConfig memory common = _common(1_000, 1_000);
        common.allocationBps = [uint16(0), uint16(0), uint16(0), uint16(10_000)];
        AutoBuybackTemplateV1.AutoBuybackConfig memory buyback =
            AutoBuybackTemplateV1.AutoBuybackConfig({threshold: 10 ether, maxSpend: 5 ether, maxSlippageBps: 500});
        bytes32 expectedFullHash = keccak256(abi.encode(common, _standard(), buyback));
        VM.recordLogs();

        (address tokenAddress, address mintVaultAddress) =
            template.deploy(CREATOR, abi.encode(common), abi.encode(_standard(), buyback));
        BuybackMintVault mintVault = BuybackMintVault(payable(mintVaultAddress));
        BuybackVault vault = mintVault.buybackVault();
        BuybackTaxProcessor processor = mintVault.taxProcessor();
        VM.deal(CREATOR, 2 ether);
        VM.expectRevert(abi.encodeWithSelector(BuybackVault.UnauthorizedFunder.selector, CREATOR));
        VM.prank(CREATOR);
        vault.fundBuyback{value: 1 wei}();
        VM.prank(CREATOR);
        mintVault.mint{value: 1 ether}(100);
        mintVault.finalize(MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp + 1 hours}));
        VM.prank(CREATOR);
        mintVault.claim();

        address pair = mintVault.liquidityToken();
        FixPair(pair).transferToken(tokenAddress, BOB, 100 ether);
        require(LaunchToken(tokenAddress).balanceOf(BOB) == 90 ether, "buy tax missing");
        VM.prank(CREATOR);
        require(LaunchToken(tokenAddress).transfer(pair, 100 ether), "sell transfer failed");
        require(LaunchToken(tokenAddress).balanceOf(address(processor)) == 20 ether, "sell tax missing");

        processor.commitProcessingFloor(20 ether, 20 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        require(vault.accountedFunds() == 20 ether, "tax did not account buyback funding");
        vault.commitExecutionFloor(5 ether, 5 ether, block.timestamp + 1 hours);
        vault.executeBuyback(0, block.timestamp + 1 hours);

        require(LaunchToken(tokenAddress).balanceOf(DEAD) == 5 ether, "buyback output not burned");
        require(vault.accountedFunds() == 15 ether, "cap/accounting mismatch");
        require(mintVault.fullConfigHash() == expectedFullHash, "mint full hash mismatch");
        require(vault.fullConfigHash() == expectedFullHash, "buyback full hash mismatch");
        require(LaunchToken(tokenAddress).projectConfigHash() == expectedFullHash, "token full hash mismatch");
        require(template.fullConfigHashOf(mintVaultAddress) == expectedFullHash, "template full hash mismatch");
        VmFix.Log memory companionLog = _companionLog(VM.getRecordedLogs(), address(template));
        (,, bytes32 loggedFullHash) = abi.decode(companionLog.data, (address, address, bytes32));
        require(loggedFullHash == expectedFullHash, "event full hash mismatch");
    }

    function testTaxProcessorPreservesAllFourCommonAllocationCategories() public {
        AutoBuybackTemplateV1 template = _autoTemplate();
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(2_500), uint16(2_500), uint16(2_500), uint16(2_500)];
        AutoBuybackTemplateV1.AutoBuybackConfig memory buyback =
            AutoBuybackTemplateV1.AutoBuybackConfig({threshold: 1 ether, maxSpend: 1 ether, maxSlippageBps: 500});
        (address tokenAddress, address mintVaultAddress) =
            template.deploy(CREATOR, abi.encode(common), abi.encode(_standard(), buyback));
        BuybackMintVault mintVault = BuybackMintVault(payable(mintVaultAddress));
        VM.deal(CREATOR, 2 ether);
        VM.prank(CREATOR);
        mintVault.mint{value: 1 ether}(100);
        mintVault.finalize(MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp + 1 hours}));
        VM.prank(CREATOR);
        mintVault.claim();
        BuybackTaxProcessor processor = mintVault.taxProcessor();
        BuybackVault vault = mintVault.buybackVault();
        uint256 receiverNativeBefore = CREATOR.balance;
        address pair = mintVault.liquidityToken();
        VM.prank(CREATOR);
        require(LaunchToken(tokenAddress).transfer(pair, 100 ether), "sell transfer failed");
        require(LaunchToken(tokenAddress).balanceOf(address(processor)) == 10 ether, "tax not collected");

        processor.commitProcessingFloor(10 ether, 6 ether, block.timestamp + 1 hours);
        IRound2Processor(address(processor)).commitRewardFloor(2.5 ether, 2.5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor(address(processor))
            .commitLiquidityFloor(1 ether, 1 ether, 1 ether, 1 ether, 1 ether, block.timestamp + 1 hours);
        IRound3Processor(address(processor)).processLiquidity(block.timestamp + 1 hours);

        require(LaunchToken(tokenAddress).balanceOf(CREATOR) == 799_900 ether, "project rewards leaked");
        require(CREATOR.balance == receiverNativeBefore + 2.5 ether, "marketing share not delivered");
        require(vault.accountedFunds() == 2.5 ether, "buyback share not funded");
        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 0.5 ether, "liquidity remainder");
        require(
            IRound2HolderRewards(address(mintVault.holderRewardVault())).totalFunded() == 2.5 ether, "rewards unfunded"
        );
        require(processor.liquidityBps() == 2_500 && processor.rewardsBps() == 2_500, "allocation map changed");
        require(processor.rewardAsset() == common.rewardToken, "reward asset config discarded");
        require(processor.rewardThreshold() == common.rewardThreshold, "reward threshold config discarded");
    }

    function testFactoryPairRemapCannotReplacePinnedProjectRouteForProcessorOrVault() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        (
            address tokenAddress,
            BuybackMintVault mintVault,
            BuybackTaxProcessor processor,
            BuybackVault vault,
            address pair
        ) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        _sellAndSync(tokenAddress, pair, 100 ether);

        FixPair replacement = new FixPair(tokenAddress, address(wbnb));
        pancakeFactory.remapPair(tokenAddress, address(wbnb), address(replacement));
        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        VM.expectRevert(
            abi.encodeWithSelector(BuybackVault.UnexpectedCanonicalPair.selector, pair, address(replacement))
        );
        processor.processTax(0, block.timestamp + 1 hours);

        vault.commitExecutionFloor(5 ether, 5 ether, block.timestamp + 1 hours);
        VM.expectRevert(
            abi.encodeWithSelector(BuybackVault.UnexpectedCanonicalPair.selector, pair, address(replacement))
        );
        vault.executeBuyback(0, block.timestamp + 1 hours);
        require(mintVault.liquidityToken() == pair, "launch pair changed");
    }

    function testStoredPairCodehashReplacementBlocksProcessorAndVault() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        (address tokenAddress,, BuybackTaxProcessor processor, BuybackVault vault, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        _sellAndSync(tokenAddress, pair, 100 ether);

        bytes32 expectedCodehash = pair.codehash;
        VM.etch(pair, hex"00");
        bytes32 actualCodehash = pair.codehash;
        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        VM.expectRevert(
            abi.encodeWithSelector(
                BuybackTaxProcessor.UnexpectedDependencyCodehash.selector, pair, expectedCodehash, actualCodehash
            )
        );
        processor.processTax(0, block.timestamp + 1 hours);

        vault.commitExecutionFloor(5 ether, 5 ether, block.timestamp + 1 hours);
        VM.expectRevert(
            abi.encodeWithSelector(
                BuybackVault.UnexpectedDependencyCodehash.selector, pair, expectedCodehash, actualCodehash
            )
        );
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testStoredPairMemberMutationBlocksProcessorAndVault() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        (address tokenAddress,, BuybackTaxProcessor processor, BuybackVault vault, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        _sellAndSync(tokenAddress, pair, 100 ether);

        FixPair(pair).setMembers(tokenAddress, address(target));
        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        VM.expectRevert(abi.encodeWithSelector(BuybackTaxProcessor.InvalidPair.selector, pair));
        processor.processTax(0, block.timestamp + 1 hours);

        vault.commitExecutionFloor(5 ether, 5 ether, block.timestamp + 1 hours);
        VM.expectRevert(
            abi.encodeWithSelector(BuybackVault.InvalidPairMembers.selector, pair, tokenAddress, address(target))
        );
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testPreLaunchTaxFundingAndBuybackExecutionRemainImpossible() public {
        AutoBuybackTemplateV1 template = _autoTemplate();
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        AutoBuybackTemplateV1.AutoBuybackConfig memory buyback =
            AutoBuybackTemplateV1.AutoBuybackConfig({threshold: 1 ether, maxSpend: 1 ether, maxSlippageBps: 500});
        (address tokenAddress, address mintVaultAddress) =
            template.deploy(CREATOR, abi.encode(common), abi.encode(_standard(), buyback));
        BuybackMintVault mintVault = BuybackMintVault(payable(mintVaultAddress));
        BuybackTaxProcessor processor = mintVault.taxProcessor();
        BuybackVault vault = mintVault.buybackVault();

        VM.expectRevert(abi.encodeWithSelector(BuybackTaxProcessor.InvalidPair.selector, address(0)));
        processor.processTax(0, block.timestamp + 1 hours);
        VM.deal(CREATOR, 1 ether);
        VM.expectRevert(abi.encodeWithSelector(BuybackVault.UnauthorizedFunder.selector, CREATOR));
        VM.prank(CREATOR);
        vault.fundBuyback{value: 1 ether}();
        (bool sent,) = payable(address(vault)).call{value: 1 ether}("");
        require(sent, "raw native transfer failed");
        require(vault.accountedFunds() == 0, "pre-launch native became funded");
        require(LaunchToken(tokenAddress).liquidityPair() == address(0), "tax activated before launch");
        require(IRound2Processor(address(processor)).accountedTaxTokens() == 0, "pre-launch taxes accounted");
    }

    function testForcedProjectTokenDustCannotInvalidateOrInflateCommittedTaxBatch() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        (address tokenAddress,, BuybackTaxProcessor processor, BuybackVault vault, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        VM.prank(CREATOR);
        require(LaunchToken(tokenAddress).transfer(address(processor), 1 wei), "dust transfer failed");

        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);

        require(vault.accountedFunds() == 10 ether, "dust inflated buyback funding");
        require(IRound2Processor(address(processor)).accountedTaxTokens() == 0, "tax batch not consumed");
        require(IRound2Processor(address(processor)).unaccountedTaxTokenBalance() == 1, "dust became accounted");
    }

    function testForcedNativeDuringTaxSwapIsIsolatedFromBuybackFunding() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        (address tokenAddress,, BuybackTaxProcessor processor, BuybackVault vault, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        router.setForcedCredit(address(processor), 1 ether);

        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);

        require(vault.accountedFunds() == 10 ether, "forced native inflated buyback funding");
        require(address(processor).balance == 1 ether, "forced native became spendable");
    }

    function testRewardAllocationFundsExcludedHolderAccountingAndConservesClaims() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(0), uint16(10_000), uint16(0)];
        (
            address tokenAddress,
            BuybackMintVault mintVault,
            BuybackTaxProcessor processor,
            BuybackVault vault,
            address pair
        ) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);

        processor.commitProcessingFloor(10 ether, 0, block.timestamp + 1 hours);
        IRound2Processor(address(processor)).commitRewardFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);

        address holderVaultAddress = IRound2Processor(address(processor)).holderRewardVault();
        IRound2HolderRewards holderVault = IRound2HolderRewards(holderVaultAddress);
        require(
            holderVaultAddress == IRound2MintVault(address(mintVault)).holderRewardVault(), "holder companion mismatch"
        );
        require(holderVault.totalFunded() == 10 ether, "reward asset not funded");
        require(holderVault.weightOf(pair) == 0, "pair received holder weight");
        require(holderVault.weightOf(address(processor)) == 0, "processor received holder weight");
        require(holderVault.weightOf(address(vault)) == 0, "buyback vault received holder weight");
        uint256 beforeClaim = target.balanceOf(CREATOR);
        VM.prank(CREATOR);
        uint256 claimed = holderVault.claimRewards();
        require(claimed == 10 ether - 1, "holder reward amount mismatch");
        require(target.balanceOf(CREATOR) == beforeClaim + claimed, "holder reward delivery mismatch");
        require(
            holderVault.totalClaimed() == claimed
                && holderVault.totalFunded() == claimed + target.balanceOf(holderVault.rewardAccounting()),
            "reward conservation"
        );
        require(LaunchToken(tokenAddress).balanceOf(CREATOR) == 799_900 ether, "project rewards leaked to receiver");
    }

    function testRewardThresholdRetainsThenSettlesExactCumulativeAssets() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(0), uint16(10_000), uint16(0)];
        common.rewardThreshold = 15 ether;
        (address tokenAddress,, BuybackTaxProcessor processor,, address pair) = _launchTaxed(common);
        IRound2HolderRewards holderVault = IRound2HolderRewards(address(processor.holderRewardVault()));

        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 0, block.timestamp + 1 hours);
        IRound2Processor(address(processor)).commitRewardFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        require(processor.pendingRewardAssets() == 10 ether, "sub-threshold reward not retained");
        require(holderVault.totalFunded() == 0, "sub-threshold reward distributed");

        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 0, block.timestamp + 1 hours);
        IRound2Processor(address(processor)).commitRewardFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        require(processor.pendingRewardAssets() == 0, "threshold reward not settled");
        require(holderVault.totalFunded() == 20 ether, "cumulative reward funding mismatch");
        require(target.balanceOf(address(processor)) == 0, "reward asset stranded at processor");
    }

    function testFullLiquidityAllocationMintsAndBurnsLpWithoutSkimmableTaxTokens() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(10_000), uint16(0), uint16(0)];
        (address tokenAddress,, BuybackTaxProcessor processor,, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);

        processor.commitProcessingFloor(10 ether, 5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor(address(processor))
            .commitLiquidityFloor(5 ether, 5 ether, 5 ether, 5 ether, 5 ether, block.timestamp + 1 hours);
        IRound3Processor(address(processor)).processLiquidity(block.timestamp + 1 hours);

        require(FixPair(pair).balanceOf(DEAD) == 5 ether, "liquidity LP not burned");
        require(FixPair(pair).skimableToken(tokenAddress) == 0, "liquidity tax became skimmable");
        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 0, "liquidity not paired");
    }

    function testPartialLiquidityAllocationRetainsOnlyUnpairableRemainder() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(2_500), uint16(0), uint16(7_500)];
        (address tokenAddress,, BuybackTaxProcessor processor, BuybackVault vault, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 200 ether);

        processor.commitProcessingFloor(20 ether, 17 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor(address(processor))
            .commitLiquidityFloor(2 ether, 2 ether, 2 ether, 2 ether, 2 ether, block.timestamp + 1 hours);
        IRound3Processor(address(processor)).processLiquidity(block.timestamp + 1 hours);

        require(vault.accountedFunds() == 15 ether, "partial buyback allocation mismatch");
        require(FixPair(pair).balanceOf(DEAD) == 2 ether, "partial liquidity LP not burned");
        require(FixPair(pair).skimableToken(tokenAddress) == 0, "partial liquidity became skimmable");
        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 1 ether, "remainder not retained");
        require(LaunchToken(tokenAddress).balanceOf(address(processor)) == 1 ether, "remainder conservation mismatch");
        require(IRound2Processor(address(processor)).accountedTaxTokens() == 0, "liquidity recursively taxed");
        require(IRound2Processor(address(processor)).unaccountedTaxTokenBalance() == 0, "remainder became dust");
    }

    function testOptimizingRouterRetainsTokenSideLeftoverAndBurnsExactLp() public {
        router.setLiquidityReserves(1 ether, 2 ether);
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(10_000), uint16(0), uint16(0)];
        (address tokenAddress,, BuybackTaxProcessor processor,, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);

        processor.commitProcessingFloor(10 ether, 5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor bounded = IRound3Processor(address(processor));
        require(bounded.availableLiquidityTokens() == 5 ether, "token side not staged");
        require(bounded.pendingLiquidityNative() == 5 ether, "native side not staged");

        bounded.commitLiquidityFloor(5 ether, 5 ether, 2.4 ether, 4.9 ether, 4.9 ether, block.timestamp + 1 hours);
        (uint256 tokenSpent, uint256 nativeSpent, uint256 liquidityMinted) =
            bounded.processLiquidity(block.timestamp + 1 hours);

        require(tokenSpent == 2.5 ether && nativeSpent == 5 ether, "optimized consumption mismatch");
        require(liquidityMinted == 5 ether && FixPair(pair).balanceOf(DEAD) == 5 ether, "exact LP not burned");
        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 2.5 ether, "token refund lost");
        require(bounded.availableLiquidityTokens() == 2.5 ether, "token refund unavailable");
        require(bounded.pendingLiquidityNative() == 0, "native accounting mismatch");
        require(FixPair(pair).skimableToken(tokenAddress) == 0, "optimized liquidity became skimmable");
        require(
            LaunchToken(tokenAddress).allowance(address(processor), address(processor.liquidityAdapter())) == 0,
            "processor allowance remained"
        );
        require(
            LaunchToken(tokenAddress).allowance(address(processor.liquidityAdapter()), address(router)) == 0,
            "router allowance remained"
        );
    }

    function testOptimizingRouterRetainsNativeRefundAndUsesItInLaterProcessing() public {
        router.setLiquidityReserves(2 ether, 1 ether);
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(10_000), uint16(0), uint16(0)];
        (address tokenAddress,, BuybackTaxProcessor processor,, address pair) = _launchTaxed(common);
        IRound3Processor bounded = IRound3Processor(address(processor));
        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        bounded.commitLiquidityFloor(5 ether, 5 ether, 4.9 ether, 2.4 ether, 2.4 ether, block.timestamp + 1 hours);
        bounded.processLiquidity(block.timestamp + 1 hours);
        require(bounded.pendingLiquidityNative() == 2.5 ether, "native refund not retained");
        require(address(processor).balance == 2.5 ether, "native refund not returned");

        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        require(bounded.pendingLiquidityNative() == 7.5 ether, "later native accounting mismatch");
        router.setLiquidityReserves(1 ether, 2 ether);
        bounded.commitLiquidityFloor(5 ether, 7.5 ether, 3.7 ether, 7.4 ether, 7.4 ether, block.timestamp + 1 hours);
        bounded.processLiquidity(block.timestamp + 1 hours);

        require(bounded.pendingLiquidityNative() == 0, "retained native not reused");
        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 1.25 ether, "later token refund lost");
        require(FixPair(pair).balanceOf(DEAD) == 10 ether, "cumulative LP burn mismatch");
    }

    function testPartialLiquidityStagesOnlyPairableTokensAndKeepsUnsplitRemainder() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(2_500), uint16(0), uint16(7_500)];
        (address tokenAddress,, BuybackTaxProcessor processor, BuybackVault vault, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 200 ether);
        processor.commitProcessingFloor(20 ether, 17 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor bounded = IRound3Processor(address(processor));

        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 3 ether, "partial token accounting");
        require(bounded.availableLiquidityTokens() == 2 ether, "unpairable token exposed");
        require(bounded.pendingLiquidityUnsplitTokens() == 1 ether, "unsplit remainder missing");
        require(bounded.pendingLiquidityNative() == 2 ether, "partial native accounting");
        bounded.commitLiquidityFloor(2 ether, 2 ether, 2 ether, 2 ether, 2 ether, block.timestamp + 1 hours);
        bounded.processLiquidity(block.timestamp + 1 hours);

        require(vault.accountedFunds() == 15 ether, "partial buyback allocation mismatch");
        require(FixPair(pair).balanceOf(DEAD) == 2 ether, "partial LP not burned");
        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 1 ether, "remainder not retained");
        require(bounded.availableLiquidityTokens() == 0, "unpairable remainder became usable");
    }

    function testLiquidityIndependentMinimaFailurePreservesFloorAndAccountedAssets() public {
        router.setLiquidityReserves(2 ether, 1 ether);
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(10_000), uint16(0), uint16(0)];
        (address tokenAddress,, BuybackTaxProcessor processor,, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor bounded = IRound3Processor(address(processor));

        VM.expectRevert();
        bounded.processLiquidity(block.timestamp + 1 hours);
        bounded.commitLiquidityFloor(5 ether, 5 ether, 5 ether, 3 ether, 2 ether, block.timestamp + 1 hours);
        VM.expectRevert();
        bounded.processLiquidity(block.timestamp + 1 hours);

        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 5 ether, "failed minimum spent tokens");
        require(bounded.pendingLiquidityNative() == 5 ether, "failed minimum spent native");
        require(FixPair(pair).balanceOf(DEAD) == 0, "failed minimum disposed LP");
        require(
            LaunchToken(tokenAddress).allowance(address(processor), address(processor.liquidityAdapter())) == 0,
            "failed allowance remained"
        );
    }

    function testStaleLiquidityFloorPreservesAccountedSidesForFreshRetry() public {
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(10_000), uint16(0), uint16(0)];
        (address tokenAddress,, BuybackTaxProcessor processor,, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor bounded = IRound3Processor(address(processor));
        uint256 expiry = block.timestamp + 1;
        bounded.commitLiquidityFloor(5 ether, 5 ether, 5 ether, 5 ether, 5 ether, expiry);
        VM.warp(expiry + 1);

        VM.expectRevert(
            abi.encodeWithSelector(BuybackTaxProcessor.StaleLiquidityFloor.selector, expiry, block.timestamp)
        );
        bounded.processLiquidity(block.timestamp + 1 hours);

        require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 5 ether, "stale floor spent tokens");
        require(bounded.pendingLiquidityNative() == 5 ether, "stale floor spent native");
        require(FixPair(pair).balanceOf(DEAD) == 0, "stale floor disposed LP");
    }

    function testLiquidityMisreportedConsumptionAndLpCannotCorruptAccounting() public {
        router.setLiquidityReserves(2 ether, 1 ether);
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(10_000), uint16(0), uint16(0)];
        (address tokenAddress,, BuybackTaxProcessor processor,, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor bounded = IRound3Processor(address(processor));
        bounded.commitLiquidityFloor(5 ether, 5 ether, 4.9 ether, 2.4 ether, 2.4 ether, block.timestamp + 1 hours);

        for (uint8 mode = 1; mode <= 3; ++mode) {
            router.setLiquidityReportMode(mode);
            VM.expectRevert();
            bounded.processLiquidity(block.timestamp + 1 hours);
            require(IRound2Processor(address(processor)).pendingLiquidityTokens() == 5 ether, "misreport spent tokens");
            require(bounded.pendingLiquidityNative() == 5 ether, "misreport spent native");
            require(FixPair(pair).balanceOf(DEAD) == 0, "misreport disposed LP");
        }
        router.setLiquidityReportMode(0);
        bounded.processLiquidity(block.timestamp + 1 hours);
        require(FixPair(pair).balanceOf(DEAD) == 2.5 ether, "valid retry did not burn LP");
    }

    function testLiquidityForcedTokenAndNativeDustStayUnaccountedAcrossRefunds() public {
        router.setLiquidityReserves(2 ether, 1 ether);
        LaunchTypes.CommonConfig memory common = _common(0, 1_000);
        common.allocationBps = [uint16(0), uint16(10_000), uint16(0), uint16(0)];
        (address tokenAddress,, BuybackTaxProcessor processor,, address pair) = _launchTaxed(common);
        _sellAndSync(tokenAddress, pair, 100 ether);
        processor.commitProcessingFloor(10 ether, 5 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        IRound3Processor bounded = IRound3Processor(address(processor));
        address adapter = address(processor.liquidityAdapter());
        VM.prank(CREATOR);
        require(LaunchToken(tokenAddress).transfer(address(processor), 1), "processor dust transfer");
        VM.prank(CREATOR);
        require(LaunchToken(tokenAddress).transfer(adapter, 2), "adapter dust transfer");
        new ForceNativeFix{value: 3 ether}().force(payable(address(processor)));
        new ForceNativeFix{value: 4 ether}().force(payable(adapter));

        bounded.commitLiquidityFloor(5 ether, 5 ether, 4.9 ether, 2.4 ether, 2.4 ether, block.timestamp + 1 hours);
        bounded.processLiquidity(block.timestamp + 1 hours);

        require(IRound2Processor(address(processor)).unaccountedTaxTokenBalance() == 1, "token dust accounted");
        require(bounded.unaccountedNativeBalance() == 3 ether, "native dust accounted");
        require(LaunchToken(tokenAddress).balanceOf(adapter) == 2, "adapter token dust moved");
        require(adapter.balance == 4 ether, "adapter native dust moved");
        require(bounded.pendingLiquidityNative() == 2.5 ether, "native refund misclassified");
        require(FixPair(pair).balanceOf(DEAD) == 2.5 ether, "exact LP burn mismatch");
    }

    function testTimedScheduleActivatesAtLaunchNotDeployment() public {
        TimedBuybackTemplateV1 template = _timedTemplate();
        TimedBuybackTemplateV1.TimedBuybackConfig memory buyback = TimedBuybackTemplateV1.TimedBuybackConfig({
            threshold: 1 ether, maxSpend: 1 ether, interval: 1 days, maxSlippageBps: 500
        });
        (, address mintVaultAddress) =
            template.deploy(CREATOR, abi.encode(_common(0, 1_000)), abi.encode(_standard(), buyback));
        BuybackMintVault mintVault = BuybackMintVault(payable(mintVaultAddress));
        BuybackVault vault = mintVault.buybackVault();
        BuybackTaxProcessor processor = mintVault.taxProcessor();

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.ScheduleNotActive.selector));
        vault.executeBuyback(0, block.timestamp + 1 hours);

        VM.warp(block.timestamp + 12 hours);
        VM.deal(CREATOR, 2 ether);
        VM.prank(CREATOR);
        mintVault.mint{value: 1 ether}(100);
        uint256 launchedAt = block.timestamp;
        mintVault.finalize(MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp + 1 hours}));
        VM.prank(CREATOR);
        mintVault.claim();
        _sellAndSync(address(mintVault.token()), mintVault.liquidityToken(), 100 ether);
        processor.commitProcessingFloor(10 ether, 10 ether, block.timestamp + 1 hours);
        processor.processTax(0, block.timestamp + 1 hours);
        vault.commitExecutionFloor(1 ether, 1 ether, block.timestamp + 30 days);
        require(vault.nextExecutionAt() == launchedAt + 1 days, "timer started before launch");
        VM.warp(launchedAt + 1 days - 1);
        VM.expectRevert(
            abi.encodeWithSelector(
                BuybackVault.ExecutionTooEarly.selector, launchedAt + 1 days, launchedAt + 1 days - 1
            )
        );
        vault.executeBuyback(0, block.timestamp + 1 hours);
        VM.warp(launchedAt + 1 days);
        vault.executeBuyback(0, block.timestamp + 1 hours);
    }

    function testBuybackTemplateRejectsNonCanonicalCommonAndSpecializedEncoding() public {
        AutoBuybackTemplateV1 template = _autoTemplate();
        AutoBuybackTemplateV1.AutoBuybackConfig memory buyback =
            AutoBuybackTemplateV1.AutoBuybackConfig({threshold: 1 ether, maxSpend: 1 ether, maxSlippageBps: 500});
        bytes memory nonCanonicalCommon = bytes.concat(abi.encode(_common(0, 0)), hex"00");
        VM.expectRevert(abi.encodeWithSelector(BuybackTemplateBaseV1.InvalidCommonConfigEncoding.selector));
        template.deploy(CREATOR, nonCanonicalCommon, abi.encode(_standard(), buyback));

        bytes memory nonCanonicalTemplate = bytes.concat(abi.encode(_standard(), buyback), hex"00");
        VM.expectRevert(abi.encodeWithSelector(AutoBuybackTemplateV1.InvalidTemplateConfigEncoding.selector));
        template.deploy(CREATOR, abi.encode(_common(0, 0)), nonCanonicalTemplate);
    }

    function _newDirectVault(FixToken target_, uint256 threshold, uint256 cap, uint32 interval, bool approved)
        private
        returns (BuybackVault vault)
    {
        BuybackVault.Config memory config = BuybackVault.Config({
            targetToken: address(target_),
            threshold: threshold,
            maxSpend: cap,
            interval: interval,
            maxSlippageBps: 500,
            requireRouteAtCreation: approved,
            requireTargetApproval: approved,
            controller: address(this),
            quoteController: address(this),
            fullConfigHash: keccak256("direct")
        });
        vault = new BuybackVault(address(router), address(wbnb), config, _trusted());
        vault.setFunder(address(this));
        if (interval != 0) vault.activateSchedule();
    }

    function _fund(BuybackVault vault, uint256 amount) private {
        vault.fundBuyback{value: amount}();
    }

    function _launchTaxed(LaunchTypes.CommonConfig memory common)
        private
        returns (
            address tokenAddress,
            BuybackMintVault mintVault,
            BuybackTaxProcessor processor,
            BuybackVault vault,
            address pair
        )
    {
        AutoBuybackTemplateV1 template = _autoTemplate();
        AutoBuybackTemplateV1.AutoBuybackConfig memory buyback =
            AutoBuybackTemplateV1.AutoBuybackConfig({threshold: 1 ether, maxSpend: 5 ether, maxSlippageBps: 500});
        address mintVaultAddress;
        (tokenAddress, mintVaultAddress) =
            template.deploy(CREATOR, abi.encode(common), abi.encode(_standard(), buyback));
        mintVault = BuybackMintVault(payable(mintVaultAddress));
        processor = mintVault.taxProcessor();
        vault = mintVault.buybackVault();
        VM.deal(CREATOR, 2 ether);
        VM.prank(CREATOR);
        mintVault.mint{value: 1 ether}(100);
        mintVault.finalize(MintVault.FinalizeParams({minOutput: 1, deadline: block.timestamp + 1 hours}));
        VM.prank(CREATOR);
        mintVault.claim();
        pair = mintVault.liquidityToken();
    }

    function _sellAndSync(address tokenAddress, address pair, uint256 amount) private {
        VM.prank(CREATOR);
        require(LaunchToken(tokenAddress).transfer(pair, amount), "sell transfer failed");
        FixPair(pair).syncToken(tokenAddress);
    }

    function _autoTemplate() private returns (AutoBuybackTemplateV1) {
        return new AutoBuybackTemplateV1(
            address(this),
            address(executor),
            address(router),
            address(wbnb),
            address(this),
            trustedDeployers,
            _trusted()
        );
    }

    function _timedTemplate() private returns (TimedBuybackTemplateV1) {
        return new TimedBuybackTemplateV1(
            address(this),
            address(executor),
            address(router),
            address(wbnb),
            address(this),
            trustedDeployers,
            _trusted()
        );
    }

    function _externalTemplate() private returns (ExternalBurnTemplateV1) {
        return new ExternalBurnTemplateV1(
            address(this),
            address(executor),
            address(router),
            address(wbnb),
            address(this),
            trustedDeployers,
            _trusted()
        );
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

    function _standard() private pure returns (AutoBuybackTemplateV1.StandardConfig memory config) {
        config = AutoBuybackTemplateV1.StandardConfig({
            totalShares: 100, pricePerShare: 0.01 ether, claimTokenBps: 8_000, minimumLiquidityOutput: 1
        });
    }

    function _common(uint16 buyTax, uint16 sellTax) private view returns (LaunchTypes.CommonConfig memory config) {
        config.name = "Taxed Buyback";
        config.symbol = "TBB";
        config.supply = 1_000_000;
        config.buyTaxBps = buyTax;
        config.sellTaxBps = sellTax;
        config.receiver = CREATOR;
        config.rewardToken = address(target);
        config.rewardThreshold = 1 ether;
        config.lpMode = 0;
        if (buyTax != 0 || sellTax != 0) {
            config.allocationBps = [uint16(0), uint16(0), uint16(0), uint16(10_000)];
        }
        config.metadataHash = keccak256("taxed-buyback");
    }

    function _companionLog(VmFix.Log[] memory logs, address emitter) private pure returns (VmFix.Log memory found) {
        for (uint256 index; index < logs.length; ++index) {
            if (logs[index].emitter == emitter && logs[index].topics[0] == COMPANION_EVENT_SIG) return logs[index];
        }
        revert("companion event missing");
    }
}
