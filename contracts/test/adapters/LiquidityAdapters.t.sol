// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LpLockerAdapter} from "../../src/adapters/LpLockerAdapter.sol";
import {PancakeV2Adapter} from "../../src/adapters/PancakeV2Adapter.sol";
import {ILaunchExecutor, MintVault} from "../../src/vaults/MintVault.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address sender) external;
}

contract LiquidityToken {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    uint16 public immutable transferFeeBps;

    constructor(uint16 transferFeeBps_) {
        transferFeeBps = transferFeeBps_;
    }

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
        uint256 fee = amount * transferFeeBps / 10_000;
        balanceOf[recipient] += amount - fee;
        balanceOf[address(0xdead)] += fee;
    }
}

contract LiquidityPair is LiquidityToken {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) LiquidityToken(0) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract CounterfeitLiquidityPair is LiquidityPair {
    constructor(address token0_, address token1_) LiquidityPair(token0_, token1_) {}

    function counterfeitMarker() external pure returns (bytes4) {
        return bytes4(keccak256("COUNTERFEIT_PAIR"));
    }
}

contract LiquidityWbnb is LiquidityToken {
    constructor() LiquidityToken(0) {}
}

contract LiquidityFactory {
    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "exists");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new LiquidityPair(token0, token1));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }

    function setPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract LiquidityPancakeRouter {
    address public immutable factory;
    address public immutable WETH;
    uint256 public nextLiquidity = 1_000;
    uint16 public consumptionBps = 10_000;

    constructor(address factory_, address wbnb_) {
        factory = factory_;
        WETH = wbnb_;
    }

    function setNextLiquidity(uint256 amount) external {
        nextLiquidity = amount;
    }

    function setConsumptionBps(uint16 amount) external {
        require(amount <= 10_000, "invalid consumption");
        consumptionBps = amount;
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        // forge-lint: disable-next-line(block-timestamp)
        require(deadline >= block.timestamp, "expired");
        require(amountTokenDesired >= amountTokenMin && msg.value >= amountETHMin, "minimum");
        address pair = LiquidityFactory(factory).getPair(token, WETH);
        if (pair == address(0)) pair = LiquidityFactory(factory).createPair(token, WETH);
        amountToken = amountTokenDesired * consumptionBps / 10_000;
        amountETH = msg.value * consumptionBps / 10_000;
        require(LiquidityToken(token).transferFrom(msg.sender, pair, amountToken), "token pull");
        LiquidityToken(WETH).mint(pair, amountETH);
        if (amountETH != msg.value) {
            (bool refunded,) = payable(msg.sender).call{value: msg.value - amountETH}("");
            require(refunded, "native refund");
        }
        liquidity = nextLiquidity;
        LiquidityPair(pair).mint(recipient, liquidity);
    }
}

contract PinkLockerMock {
    address public lastOwner;
    address public lastToken;
    uint256 public lastAmount;
    uint256 public lastUnlockDate;
    uint256 public constant LOCK_ID = 77;

    function lock(address owner, address token, bool isLpToken, uint256 amount, uint256 unlockDate, string calldata)
        external
        returns (uint256 lockId)
    {
        require(isLpToken, "not LP");
        require(LiquidityToken(token).transferFrom(msg.sender, address(this), amount), "lock pull");
        lastOwner = owner;
        lastToken = token;
        lastAmount = amount;
        lastUnlockDate = unlockDate;
        lockId = LOCK_ID;
    }
}

contract CooperativeFakeLocker {
    address public constant SINK = address(0x5151);

    function lock(address, address token, bool, uint256 amount, uint256, string calldata)
        external
        returns (uint256 lockId)
    {
        require(LiquidityToken(token).transferFrom(msg.sender, address(this), amount), "fake pull");
        require(LiquidityToken(token).transfer(SINK, amount), "fake redirect");
        lockId = 99;
    }
}

contract FallbackLocker {
    fallback() external payable {}
}

contract CodeBearingFakeLpAdapter {
    function isLockerAllowed(address) external pure returns (bool) {
        return true;
    }

    function burnLp(address, uint256) external {}

    function lockLp(address, uint256, address, address, uint256) external pure returns (uint256 lockId) {
        return 1;
    }
}

contract LiquidityAdaptersTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant BENEFICIARY = address(0xBEEF);

    LiquidityWbnb private wbnb;
    LiquidityFactory private factory;
    LiquidityPancakeRouter private router;
    LpLockerAdapter private lpAdapter;
    LiquidityToken private launchToken;
    address private exposedToken;
    bytes32 private trustedPairCodehash;

    receive() external payable {}

    function token() external view returns (address) {
        return exposedToken;
    }

    function setUp() public {
        wbnb = new LiquidityWbnb();
        factory = new LiquidityFactory();
        router = new LiquidityPancakeRouter(address(factory), address(wbnb));
        LpLockerAdapter.LockerIdentity[] memory lockers = new LpLockerAdapter.LockerIdentity[](0);
        lpAdapter = new LpLockerAdapter(lockers);
        launchToken = new LiquidityToken(0);
        exposedToken = address(launchToken);
        trustedPairCodehash = address(new LiquidityPair(address(0x1), address(0x2))).codehash;
        VM.deal(address(this), 100 ether);
    }

    function testAddLiquidityReturnsActualPairAndBurnsExactMintedLp() public {
        PancakeV2Adapter executor = _burnExecutor();
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);

        ILaunchExecutor.ExecutionResult memory result =
            executor.execute{value: 10 ether}(address(launchToken), 400 ether, 900, block.timestamp + 1 hours);

        address pair = factory.getPair(address(launchToken), address(wbnb));
        require(result.magic == bytes4(keccak256("MINT_VAULT_EXECUTION_SUCCESS")), "success magic mismatch");
        require(result.liquidityToken == pair, "result did not return factory pair");
        require(result.liquidityAmount == 1_000, "result did not return minted LP delta");
        require(result.nativeSpent == 10 ether && result.tokenSpent == 400 ether, "spend result mismatch");
        require(LiquidityPair(pair).balanceOf(lpAdapter.DEAD_ADDRESS()) == 1_000, "LP not burned to dead");
        require(LiquidityPair(pair).balanceOf(address(executor)) == 0, "executor retained minted LP");
        require(launchToken.allowance(address(executor), address(router)) == 0, "router allowance not reset");
        require(LiquidityPair(pair).allowance(address(executor), address(lpAdapter)) == 0, "LP allowance not reset");
    }

    function testLockDispositionUsesOnlyAllowlistedImmutableLockerAndBeneficiary() public {
        PinkLockerMock locker = new PinkLockerMock();
        LpLockerAdapter.LockerIdentity[] memory lockers = new LpLockerAdapter.LockerIdentity[](1);
        lockers[0] = LpLockerAdapter.LockerIdentity({locker: address(locker), codehash: address(locker).codehash});
        lpAdapter = new LpLockerAdapter(lockers);
        uint256 unlockTime = block.timestamp + 30 days;
        PancakeV2Adapter executor = new PancakeV2Adapter(
            address(router),
            address(wbnb),
            address(lpAdapter),
            PancakeV2Adapter.LpMode.Lock,
            address(locker),
            BENEFICIARY,
            unlockTime,
            _trustedDependencies(address(lpAdapter))
        );
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);

        ILaunchExecutor.ExecutionResult memory result =
            executor.execute{value: 10 ether}(address(launchToken), 400 ether, 900, block.timestamp + 1 hours);

        require(locker.lastOwner() == BENEFICIARY, "lock beneficiary was caller-controlled");
        require(locker.lastToken() == result.liquidityToken, "wrong LP token locked");
        require(locker.lastAmount() == result.liquidityAmount, "wrong LP amount locked");
        require(locker.lastUnlockDate() == unlockTime, "unlock time changed");
        require(locker.LOCK_ID() == 77, "unexpected local ABI lock ID");
        require(LiquidityPair(result.liquidityToken).balanceOf(address(locker)) == 1_000, "locker lacks LP");
        require(
            LiquidityPair(result.liquidityToken).allowance(address(lpAdapter), address(locker)) == 0,
            "locker allowance not reset"
        );
    }

    function testLockExecutorRejectsLockerOutsideAdapterAllowlist() public {
        PinkLockerMock locker = new PinkLockerMock();

        VM.expectRevert(abi.encodeWithSelector(PancakeV2Adapter.LockerNotAllowlisted.selector, address(locker)));
        new PancakeV2Adapter(
            address(router),
            address(wbnb),
            address(lpAdapter),
            PancakeV2Adapter.LpMode.Lock,
            address(locker),
            BENEFICIARY,
            block.timestamp + 30 days,
            _trustedDependencies(address(lpAdapter))
        );
    }

    function testExecutorRejectsRouterWhoseImmutableWbnbRouteDoesNotMatch() public {
        LiquidityWbnb wrongWbnb = new LiquidityWbnb();
        address actualWbnb = router.WETH();

        VM.expectRevert(
            abi.encodeWithSelector(
                PancakeV2Adapter.InvalidRoute.selector, address(router), address(wrongWbnb), actualWbnb
            )
        );
        new PancakeV2Adapter(
            address(router),
            address(wrongWbnb),
            address(lpAdapter),
            PancakeV2Adapter.LpMode.Burn,
            address(0),
            address(0),
            0,
            _trustedDependenciesForWbnb(address(lpAdapter), address(wrongWbnb))
        );
    }

    function testSelfConsistentCounterfeitRouterFactoryPairBundleCannotReplaceTrustedChainConfig() public {
        LiquidityWbnb counterfeitWbnb = new LiquidityWbnb();
        LiquidityFactory counterfeitFactory = new LiquidityFactory();
        LiquidityPancakeRouter counterfeitRouter =
            new LiquidityPancakeRouter(address(counterfeitFactory), address(counterfeitWbnb));
        counterfeitFactory.createPair(address(launchToken), address(counterfeitWbnb));

        VM.expectRevert(
            abi.encodeWithSelector(
                PancakeV2Adapter.UntrustedDependency.selector, address(counterfeitRouter), address(router)
            )
        );
        new PancakeV2Adapter(
            address(counterfeitRouter),
            address(counterfeitWbnb),
            address(lpAdapter),
            PancakeV2Adapter.LpMode.Burn,
            address(0),
            address(0),
            0,
            _trustedDependencies(address(lpAdapter))
        );
    }

    function testCodeBearingFakeLpAdapterCannotMatchTrustedImplementationCodehash() public {
        CodeBearingFakeLpAdapter fake = new CodeBearingFakeLpAdapter();
        PancakeV2Adapter.TrustedDependencies memory trusted = _trustedDependencies(address(lpAdapter));
        trusted.lpAdapter = address(fake);

        VM.expectRevert(
            abi.encodeWithSelector(
                PancakeV2Adapter.UnexpectedDependencyCodehash.selector,
                address(fake),
                address(lpAdapter).codehash,
                address(fake).codehash
            )
        );
        new PancakeV2Adapter(
            address(router),
            address(wbnb),
            address(fake),
            PancakeV2Adapter.LpMode.Burn,
            address(0),
            address(0),
            0,
            trusted
        );
    }

    function testExecutionRejectsPinnedLpAdapterWhoseRuntimeCodehashChanges() public {
        PancakeV2Adapter executor = _burnExecutor();
        CodeBearingFakeLpAdapter replacement = new CodeBearingFakeLpAdapter();
        bytes32 expectedCodehash = address(lpAdapter).codehash;
        bytes32 replacementCodehash = address(replacement).codehash;
        VM.etch(address(lpAdapter), address(replacement).code);
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);

        VM.expectRevert(
            abi.encodeWithSelector(
                PancakeV2Adapter.UnexpectedDependencyCodehash.selector,
                address(lpAdapter),
                expectedCodehash,
                replacementCodehash
            )
        );
        executor.execute{value: 10 ether}(address(launchToken), 400 ether, 900, block.timestamp + 1 hours);

        require(launchToken.balanceOf(address(this)) == 400 ether, "changed dependency consumed launch token");
    }

    function testLockLpReturnsExactLockIdRecordAndAssetResult() public {
        PinkLockerMock locker = new PinkLockerMock();
        LpLockerAdapter.LockerIdentity[] memory lockers = new LpLockerAdapter.LockerIdentity[](1);
        lockers[0] = LpLockerAdapter.LockerIdentity({locker: address(locker), codehash: address(locker).codehash});
        LpLockerAdapter adapter = new LpLockerAdapter(lockers);
        LiquidityPair pair = new LiquidityPair(address(launchToken), address(wbnb));
        pair.mint(address(this), 1_000);
        pair.approve(address(adapter), 1_000);
        uint256 unlockTime = block.timestamp + 30 days;

        uint256 lockId = adapter.lockLp(address(pair), 1_000, address(locker), BENEFICIARY, unlockTime);

        require(lockId == 77, "adapter did not return locker result");
        require(locker.lastOwner() == BENEFICIARY, "lock record owner mismatch");
        require(locker.lastToken() == address(pair), "lock record token mismatch");
        require(locker.lastAmount() == 1_000, "lock record amount mismatch");
        require(locker.lastUnlockDate() == unlockTime, "lock record time mismatch");
        require(pair.balanceOf(address(locker)) == 1_000, "locker did not receive exact LP");
        require(pair.balanceOf(address(adapter)) == 0, "adapter retained LP");
        require(pair.allowance(address(adapter), address(locker)) == 0, "locker allowance remained");
    }

    function testCooperativeLockerThatRedirectsLpFailsAssetResultPostcondition() public {
        CooperativeFakeLocker locker = new CooperativeFakeLocker();
        LpLockerAdapter.LockerIdentity[] memory lockers = new LpLockerAdapter.LockerIdentity[](1);
        lockers[0] = LpLockerAdapter.LockerIdentity({locker: address(locker), codehash: address(locker).codehash});
        LpLockerAdapter adapter = new LpLockerAdapter(lockers);
        LiquidityPair pair = new LiquidityPair(address(launchToken), address(wbnb));
        pair.mint(address(this), 1_000);
        pair.approve(address(adapter), 1_000);

        VM.expectRevert(abi.encodeWithSelector(LpLockerAdapter.InvalidLockResult.selector, 1_000, 0, 0));
        adapter.lockLp(address(pair), 1_000, address(locker), BENEFICIARY, block.timestamp + 30 days);

        require(pair.balanceOf(address(this)) == 1_000, "malicious lock retained LP after revert");
    }

    function testFallbackLockerCannotMasqueradeUnderTrustedLockerCodehash() public {
        PinkLockerMock trustedLocker = new PinkLockerMock();
        FallbackLocker fallbackLocker = new FallbackLocker();
        bytes32 expectedCodehash = address(trustedLocker).codehash;
        bytes32 actualCodehash = address(fallbackLocker).codehash;
        LpLockerAdapter.LockerIdentity[] memory lockers = new LpLockerAdapter.LockerIdentity[](1);
        lockers[0] = LpLockerAdapter.LockerIdentity({locker: address(fallbackLocker), codehash: expectedCodehash});

        VM.expectRevert(
            abi.encodeWithSelector(
                LpLockerAdapter.UnexpectedLockerCodehash.selector,
                address(fallbackLocker),
                expectedCodehash,
                actualCodehash
            )
        );
        new LpLockerAdapter(lockers);
    }

    function testLiquidityBelowCallerMinimumRevertsAtomically() public {
        PancakeV2Adapter executor = _burnExecutor();
        router.setNextLiquidity(899);
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);

        VM.expectRevert(abi.encodeWithSelector(PancakeV2Adapter.InsufficientLiquidityOutput.selector, 900, 899));
        executor.execute{value: 10 ether}(address(launchToken), 400 ether, 900, block.timestamp + 1 hours);

        require(launchToken.balanceOf(address(this)) == 400 ether, "slippage revert consumed token");
    }

    function testPartialRouterConsumptionRevertsInsteadOfReportingFullSpend() public {
        PancakeV2Adapter executor = _burnExecutor();
        router.setConsumptionBps(9_900);
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);

        VM.expectRevert(
            abi.encodeWithSelector(
                PancakeV2Adapter.IncompleteAssetConsumption.selector, 400 ether, 396 ether, 10 ether, 9.9 ether
            )
        );
        executor.execute{value: 10 ether}(address(launchToken), 400 ether, 900, block.timestamp + 1 hours);

        require(launchToken.balanceOf(address(this)) == 400 ether, "partial router retained launch token");
        require(address(executor).balance == 0, "partial router refund remained in executor");
    }

    function testBoundedPartialConsumptionReturnsRefundsAndLocksExactLp() public {
        PinkLockerMock locker = new PinkLockerMock();
        LpLockerAdapter.LockerIdentity[] memory lockers = new LpLockerAdapter.LockerIdentity[](1);
        lockers[0] = LpLockerAdapter.LockerIdentity({locker: address(locker), codehash: address(locker).codehash});
        lpAdapter = new LpLockerAdapter(lockers);
        PancakeV2Adapter executor = new PancakeV2Adapter(
            address(router),
            address(wbnb),
            address(lpAdapter),
            PancakeV2Adapter.LpMode.Lock,
            address(locker),
            BENEFICIARY,
            block.timestamp + 30 days,
            _trustedDependencies(address(lpAdapter))
        );
        router.setConsumptionBps(7_500);
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);
        uint256 nativeBefore = address(this).balance;

        ILaunchExecutor.ExecutionResult memory result = executor.addLiquidityWithBounds{value: 10 ether}(
            address(launchToken), 400 ether, 300 ether, 7.5 ether, 900, block.timestamp + 1 hours
        );

        require(result.tokenSpent == 300 ether && result.nativeSpent == 7.5 ether, "bounded spend mismatch");
        require(result.liquidityAmount == 1_000 && locker.lastAmount() == 1_000, "bounded LP lock mismatch");
        require(launchToken.balanceOf(address(this)) == 100 ether, "token refund mismatch");
        require(address(this).balance == nativeBefore - 7.5 ether, "native refund mismatch");
        require(launchToken.allowance(address(executor), address(router)) == 0, "router allowance remained");
    }

    function testExpiredDeadlineRevertsBeforePullingAssets() public {
        PancakeV2Adapter executor = _burnExecutor();
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);
        uint256 deadline = block.timestamp - 1;

        VM.expectRevert(abi.encodeWithSelector(PancakeV2Adapter.DeadlineExpired.selector, deadline, block.timestamp));
        executor.addLiquidity{value: 10 ether}(address(launchToken), 400 ether, 900, deadline);

        require(launchToken.balanceOf(address(this)) == 400 ether, "expired call consumed token");
        require(factory.getPair(address(launchToken), address(wbnb)) == address(0), "expired call created pair");
    }

    function testFeeOnTransferLaunchTokenIsRejectedBeforeRouterApproval() public {
        PancakeV2Adapter executor = _burnExecutor();
        LiquidityToken taxedToken = new LiquidityToken(100);
        exposedToken = address(taxedToken);
        taxedToken.mint(address(this), 400 ether);
        taxedToken.approve(address(executor), 400 ether);

        VM.expectRevert(
            abi.encodeWithSelector(PancakeV2Adapter.UnsupportedFeeOnTransferToken.selector, 400 ether, 396 ether)
        );
        executor.execute{value: 10 ether}(address(taxedToken), 400 ether, 900, block.timestamp + 1 hours);

        require(taxedToken.balanceOf(address(this)) == 400 ether, "compatibility revert consumed token");
        require(taxedToken.allowance(address(executor), address(router)) == 0, "incompatible token was approved");
    }

    function testFactoryPairMustMatchCanonicalTokenWbnbRoute() public {
        PancakeV2Adapter executor = _burnExecutor();
        LiquidityPair wrongPair = new LiquidityPair(address(launchToken), address(0xBAD));
        factory.setPair(address(launchToken), address(wbnb), address(wrongPair));
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);

        VM.expectRevert(abi.encodeWithSelector(PancakeV2Adapter.InvalidCanonicalPair.selector, address(wrongPair)));
        executor.execute{value: 10 ether}(address(launchToken), 400 ether, 900, block.timestamp + 1 hours);
    }

    function testFactoryPairWithCorrectMembersButUntrustedImplementationCodehashReverts() public {
        PancakeV2Adapter executor = _burnExecutor();
        (address token0, address token1) = address(launchToken) < address(wbnb)
            ? (address(launchToken), address(wbnb))
            : (address(wbnb), address(launchToken));
        CounterfeitLiquidityPair counterfeitPair = new CounterfeitLiquidityPair(token0, token1);
        factory.setPair(address(launchToken), address(wbnb), address(counterfeitPair));
        launchToken.mint(address(this), 400 ether);
        launchToken.approve(address(executor), 400 ether);

        VM.expectRevert(
            abi.encodeWithSelector(PancakeV2Adapter.InvalidCanonicalPair.selector, address(counterfeitPair))
        );
        executor.execute{value: 10 ether}(address(launchToken), 400 ether, 900, block.timestamp + 1 hours);
    }

    function testRealExecutorPreservesMintVaultPostconditionsAndIgnoresUnsolicitedBalances() public {
        PancakeV2Adapter executor = _burnExecutor();
        MintVault vault =
            new MintVault(address(this), address(executor), "Launch", "LCH", 600 ether, 400 ether, 900, 10, 1 ether);
        exposedToken = address(vault.token());
        VM.deal(address(vault), 1);
        VM.deal(address(executor), 2);

        vault.mint{value: 10 ether}(10);
        require(
            vault.finalize(MintVault.FinalizeParams({minOutput: 900, deadline: block.timestamp + 1 hours})),
            "real executor finalization failed"
        );

        address pair = factory.getPair(address(vault.token()), address(wbnb));
        require(vault.state() == MintVault.State.Launched, "vault did not launch");
        require(vault.liquidityToken() == pair && vault.liquidityAmount() == 1_000, "actual LP result not stored");
        require(vault.finalizedSpend() == 10 ether, "vault native spend postcondition weakened");
        require(vault.finalizedTokenSpend() == 400 ether, "vault token spend postcondition weakened");
        require(address(vault).balance == 1, "executor consumed unsolicited vault native balance");
        require(address(executor).balance == 2, "execution consumed unsolicited executor native balance");
        require(vault.token().balanceOf(address(vault)) == 600 ether, "executor consumed claim inventory");
    }

    function _burnExecutor() private returns (PancakeV2Adapter) {
        return new PancakeV2Adapter(
            address(router),
            address(wbnb),
            address(lpAdapter),
            PancakeV2Adapter.LpMode.Burn,
            address(0),
            address(0),
            0,
            _trustedDependencies(address(lpAdapter))
        );
    }

    function _trustedDependencies(address trustedLpAdapter)
        private
        view
        returns (PancakeV2Adapter.TrustedDependencies memory trusted)
    {
        trusted = PancakeV2Adapter.TrustedDependencies({
            router: address(router),
            factory: address(factory),
            wbnb: address(wbnb),
            lpAdapter: trustedLpAdapter,
            routerCodehash: address(router).codehash,
            factoryCodehash: address(factory).codehash,
            wbnbCodehash: address(wbnb).codehash,
            pairCodehash: trustedPairCodehash,
            lpAdapterCodehash: trustedLpAdapter.codehash
        });
    }

    function _trustedDependenciesForWbnb(address trustedLpAdapter, address trustedWbnb)
        private
        view
        returns (PancakeV2Adapter.TrustedDependencies memory trusted)
    {
        trusted = _trustedDependencies(trustedLpAdapter);
        trusted.wbnb = trustedWbnb;
        trusted.wbnbCodehash = trustedWbnb.codehash;
    }
}
