// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LpLockerAdapter} from "./LpLockerAdapter.sol";
import {ILaunchExecutor} from "../vaults/MintVault.sol";

interface IPancakeToken {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);
}

interface IPancakePair is IPancakeToken {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakeRouter {
    function WETH() external view returns (address);
    function factory() external view returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IMintVaultLaunchContext {
    function token() external view returns (address);
}

contract PancakeV2Adapter is ILaunchExecutor {
    struct LiquidityBounds {
        uint256 tokenDesired;
        uint256 tokenMinimum;
        uint256 nativeDesired;
        uint256 nativeMinimum;
        uint256 liquidityMinimum;
        uint256 deadline;
    }

    struct LiquiditySnapshot {
        address pair;
        uint256 adapterTokenBalance;
        uint256 adapterNativeBalance;
        uint256 pairTokenBalance;
        uint256 pairWbnbBalance;
        uint256 adapterLpBalance;
    }

    struct TrustedDependencies {
        address router;
        address factory;
        address wbnb;
        address lpAdapter;
        bytes32 routerCodehash;
        bytes32 factoryCodehash;
        bytes32 wbnbCodehash;
        bytes32 pairCodehash;
        bytes32 lpAdapterCodehash;
    }

    enum LpMode {
        Burn,
        Lock
    }

    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error AssetConsumptionOutOfBounds(
        uint256 tokenMinimum,
        uint256 tokenDesired,
        uint256 actualToken,
        uint256 nativeMinimum,
        uint256 nativeDesired,
        uint256 actualNative
    );
    error IncompleteAssetConsumption(
        uint256 expectedToken, uint256 actualToken, uint256 expectedNative, uint256 actualNative
    );
    error InsufficientLiquidityOutput(uint256 minimum, uint256 actual);
    error InvalidCanonicalPair(address pair);
    error InvalidDependency(address dependency);
    error InvalidDispositionConfiguration();
    error InvalidLaunchContext(address caller, address providedToken, address contextToken);
    error InvalidRoute(address router, address expectedWbnb, address actualWbnb);
    error LockerNotAllowlisted(address locker);
    error ReentrantCall();
    error TokenOperationFailed(address token);
    error UnexpectedDependencyCodehash(address dependency, bytes32 expected, bytes32 actual);
    error UntrustedDependency(address provided, address expected);
    error UnsupportedFeeOnTransferToken(uint256 expected, uint256 actual);
    error UnexpectedAssetBalance(address asset, uint256 minimum, uint256 actual);
    error ZeroAssetAmount();

    event LiquidityAdded(
        address indexed vault,
        address indexed token,
        address indexed pair,
        uint256 tokenAmount,
        uint256 nativeAmount,
        uint256 liquidityAmount,
        LpMode disposition
    );

    bytes4 public constant EXECUTION_SUCCESS = bytes4(keccak256("MINT_VAULT_EXECUTION_SUCCESS"));

    IPancakeRouter public immutable router;
    IPancakeFactory public immutable factory;
    address public immutable wbnb;
    LpLockerAdapter public immutable lpAdapter;
    LpMode public immutable lpMode;
    address public immutable locker;
    address public immutable lpBeneficiary;
    uint256 public immutable unlockTime;
    bytes32 public immutable routerCodehash;
    bytes32 public immutable factoryCodehash;
    bytes32 public immutable wbnbCodehash;
    bytes32 public immutable pairCodehash;
    bytes32 public immutable lpAdapterCodehash;

    bool private entered;

    constructor(
        address router_,
        address wbnb_,
        address lpAdapter_,
        LpMode lpMode_,
        address locker_,
        address lpBeneficiary_,
        uint256 unlockTime_,
        TrustedDependencies memory trusted
    ) {
        if (router_.code.length == 0) revert InvalidDependency(router_);
        if (wbnb_.code.length == 0) revert InvalidDependency(wbnb_);
        if (lpAdapter_.code.length == 0) revert InvalidDependency(lpAdapter_);
        _validateTrustedDependency(router_, trusted.router, trusted.routerCodehash);
        _validateTrustedDependency(wbnb_, trusted.wbnb, trusted.wbnbCodehash);
        _validateTrustedDependency(lpAdapter_, trusted.lpAdapter, trusted.lpAdapterCodehash);

        IPancakeRouter routerContract = IPancakeRouter(router_);
        address actualWbnb = routerContract.WETH();
        if (actualWbnb != wbnb_) revert InvalidRoute(router_, wbnb_, actualWbnb);
        address factory_ = routerContract.factory();
        if (factory_.code.length == 0) revert InvalidDependency(factory_);
        _validateTrustedDependency(factory_, trusted.factory, trusted.factoryCodehash);

        LpLockerAdapter lockerAdapter = LpLockerAdapter(lpAdapter_);
        if (lpMode_ == LpMode.Burn) {
            if (locker_ != address(0) || lpBeneficiary_ != address(0) || unlockTime_ != 0) {
                revert InvalidDispositionConfiguration();
            }
        } else {
            // The immutable lock must still be live when this future-project adapter is created.
            // forge-lint: disable-next-line(block-timestamp)
            if (locker_.code.length == 0 || lpBeneficiary_ == address(0) || unlockTime_ <= block.timestamp) {
                revert InvalidDispositionConfiguration();
            }
            if (!lockerAdapter.isLockerAllowed(locker_)) revert LockerNotAllowlisted(locker_);
        }

        router = routerContract;
        factory = IPancakeFactory(factory_);
        wbnb = wbnb_;
        lpAdapter = lockerAdapter;
        lpMode = lpMode_;
        locker = locker_;
        lpBeneficiary = lpBeneficiary_;
        unlockTime = unlockTime_;
        routerCodehash = trusted.routerCodehash;
        factoryCodehash = trusted.factoryCodehash;
        wbnbCodehash = trusted.wbnbCodehash;
        pairCodehash = trusted.pairCodehash;
        lpAdapterCodehash = trusted.lpAdapterCodehash;
    }

    receive() external payable {
        if (msg.sender != address(router) || !entered) revert InvalidDependency(msg.sender);
    }

    function execute(address token, uint256 tokenAmount, uint256 minOutput, uint256 deadline)
        external
        payable
        returns (ExecutionResult memory result)
    {
        return _executeExact(token, tokenAmount, minOutput, deadline);
    }

    function addLiquidity(address token, uint256 tokenAmount, uint256 minOutput, uint256 deadline)
        external
        payable
        returns (ExecutionResult memory result)
    {
        return _executeExact(token, tokenAmount, minOutput, deadline);
    }

    function addLiquidityWithBounds(
        address tokenAddress,
        uint256 tokenDesired,
        uint256 tokenMinimum,
        uint256 nativeMinimum,
        uint256 liquidityMinimum,
        uint256 deadline
    ) external payable returns (ExecutionResult memory result) {
        LiquidityBounds memory bounds = LiquidityBounds({
            tokenDesired: tokenDesired,
            tokenMinimum: tokenMinimum,
            nativeDesired: msg.value,
            nativeMinimum: nativeMinimum,
            liquidityMinimum: liquidityMinimum,
            deadline: deadline
        });
        return _execute(tokenAddress, bounds, false);
    }

    function _executeExact(address tokenAddress, uint256 tokenAmount, uint256 minOutput, uint256 deadline)
        private
        returns (ExecutionResult memory result)
    {
        LiquidityBounds memory bounds = LiquidityBounds({
            tokenDesired: tokenAmount,
            tokenMinimum: tokenAmount,
            nativeDesired: msg.value,
            nativeMinimum: msg.value,
            liquidityMinimum: minOutput,
            deadline: deadline
        });
        return _execute(tokenAddress, bounds, true);
    }

    // External calls below execute only while `entered` is true; the reported post-call write is the unlock.
    // slither-disable-start reentrancy-eth
    function _execute(address tokenAddress, LiquidityBounds memory bounds, bool requireExact)
        private
        returns (ExecutionResult memory result)
    {
        if (entered) revert ReentrantCall();
        // AMM deadlines are intentionally enforced against chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (bounds.deadline < block.timestamp) revert DeadlineExpired(bounds.deadline, block.timestamp);
        if (
            bounds.tokenDesired == 0 || bounds.nativeDesired == 0 || bounds.tokenMinimum == 0
                || bounds.nativeMinimum == 0 || bounds.liquidityMinimum == 0
                || bounds.tokenMinimum > bounds.tokenDesired || bounds.nativeMinimum > bounds.nativeDesired
        ) revert ZeroAssetAmount();
        if (tokenAddress.code.length == 0 || tokenAddress == wbnb) revert InvalidDependency(tokenAddress);
        _validateCurrentDependency(address(router), routerCodehash);
        _validateCurrentDependency(address(factory), factoryCodehash);
        _validateCurrentDependency(wbnb, wbnbCodehash);
        _validateCurrentDependency(address(lpAdapter), lpAdapterCodehash);
        address actualFactory = router.factory();
        address actualWbnb = router.WETH();
        if (actualFactory != address(factory) || actualWbnb != wbnb) {
            revert InvalidRoute(address(router), wbnb, actualWbnb);
        }
        entered = true;

        address contextToken = _contextToken(msg.sender);
        if (contextToken != tokenAddress) revert InvalidLaunchContext(msg.sender, tokenAddress, contextToken);

        (address pair, uint256 tokenSpent, uint256 nativeSpent, uint256 actualLiquidity) =
            _addLiquidity(tokenAddress, bounds, requireExact);
        if (actualLiquidity < bounds.liquidityMinimum) {
            revert InsufficientLiquidityOutput(bounds.liquidityMinimum, actualLiquidity);
        }
        _disposeLiquidity(pair, actualLiquidity);

        emit LiquidityAdded(msg.sender, tokenAddress, pair, tokenSpent, nativeSpent, actualLiquidity, lpMode);
        entered = false;

        result = ExecutionResult({
            magic: EXECUTION_SUCCESS,
            liquidityToken: pair,
            liquidityAmount: actualLiquidity,
            nativeSpent: nativeSpent,
            tokenSpent: tokenSpent
        });
    }
    // slither-disable-end reentrancy-eth

    function _addLiquidity(address tokenAddress, LiquidityBounds memory bounds, bool requireExact)
        private
        returns (address pair, uint256 tokenUsed, uint256 nativeUsed, uint256 actualLiquidity)
    {
        LiquiditySnapshot memory snapshot;
        snapshot.pair = factory.getPair(tokenAddress, wbnb);
        if (snapshot.pair != address(0)) {
            _validateCanonicalPair(snapshot.pair, tokenAddress);
            snapshot.pairTokenBalance = IPancakeToken(tokenAddress).balanceOf(snapshot.pair);
            snapshot.pairWbnbBalance = IPancakeToken(wbnb).balanceOf(snapshot.pair);
            snapshot.adapterLpBalance = IPancakePair(snapshot.pair).balanceOf(address(this));
        }

        IPancakeToken token = IPancakeToken(tokenAddress);
        snapshot.adapterTokenBalance = token.balanceOf(address(this));
        snapshot.adapterNativeBalance = address(this).balance - bounds.nativeDesired;
        _safeTransferFrom(token, msg.sender, address(this), bounds.tokenDesired);
        uint256 tokenReceived = token.balanceOf(address(this)) - snapshot.adapterTokenBalance;
        if (tokenReceived != bounds.tokenDesired) {
            revert UnsupportedFeeOnTransferToken(bounds.tokenDesired, tokenReceived);
        }
        uint256 reportedLiquidity;
        (tokenUsed, nativeUsed, reportedLiquidity) = _callRouter(token, tokenAddress, bounds);
        _validateConsumption(bounds, tokenUsed, nativeUsed, requireExact);

        pair = factory.getPair(tokenAddress, wbnb);
        _validateCanonicalPair(pair, tokenAddress);
        if (snapshot.pair != address(0) && pair != snapshot.pair) revert InvalidCanonicalPair(pair);

        if (snapshot.pair != address(0)) {
            if (token.balanceOf(pair) - snapshot.pairTokenBalance != tokenUsed) revert InvalidCanonicalPair(pair);
            if (IPancakeToken(wbnb).balanceOf(pair) - snapshot.pairWbnbBalance != nativeUsed) {
                revert InvalidCanonicalPair(pair);
            }
        }

        uint256 expectedTokenBalance = snapshot.adapterTokenBalance + bounds.tokenDesired - tokenUsed;
        uint256 actualTokenBalance = token.balanceOf(address(this));
        if (actualTokenBalance < expectedTokenBalance) {
            revert UnexpectedAssetBalance(tokenAddress, expectedTokenBalance, actualTokenBalance);
        }
        uint256 expectedNativeBalance = snapshot.adapterNativeBalance + bounds.nativeDesired - nativeUsed;
        if (address(this).balance < expectedNativeBalance) {
            revert UnexpectedAssetBalance(address(0), expectedNativeBalance, address(this).balance);
        }

        actualLiquidity = IPancakePair(pair).balanceOf(address(this)) - snapshot.adapterLpBalance;
        if (actualLiquidity != reportedLiquidity) revert InvalidCanonicalPair(pair);

        uint256 tokenRefund = bounds.tokenDesired - tokenUsed;
        if (tokenRefund != 0) _safeTransfer(token, msg.sender, tokenRefund);
        uint256 nativeRefund = bounds.nativeDesired - nativeUsed;
        if (nativeRefund != 0) _sendNative(msg.sender, nativeRefund);
    }

    function _callRouter(IPancakeToken token, address tokenAddress, LiquidityBounds memory bounds)
        private
        returns (uint256 tokenUsed, uint256 nativeUsed, uint256 reportedLiquidity)
    {
        _safeApprove(token, address(router), 0);
        _safeApprove(token, address(router), bounds.tokenDesired);
        (tokenUsed, nativeUsed, reportedLiquidity) = router.addLiquidityETH{value: bounds.nativeDesired}(
            tokenAddress, bounds.tokenDesired, bounds.tokenMinimum, bounds.nativeMinimum, address(this), bounds.deadline
        );
        _safeApprove(token, address(router), 0);
    }

    function _validateConsumption(
        LiquidityBounds memory bounds,
        uint256 tokenUsed,
        uint256 nativeUsed,
        bool requireExact
    ) private pure {
        if (requireExact && (tokenUsed != bounds.tokenDesired || nativeUsed != bounds.nativeDesired)) {
            revert IncompleteAssetConsumption(bounds.tokenDesired, tokenUsed, bounds.nativeDesired, nativeUsed);
        }
        if (
            tokenUsed < bounds.tokenMinimum || tokenUsed > bounds.tokenDesired || nativeUsed < bounds.nativeMinimum
                || nativeUsed > bounds.nativeDesired
        ) {
            revert AssetConsumptionOutOfBounds(
                bounds.tokenMinimum,
                bounds.tokenDesired,
                tokenUsed,
                bounds.nativeMinimum,
                bounds.nativeDesired,
                nativeUsed
            );
        }
    }

    function _disposeLiquidity(address pair, uint256 actualLiquidity) private {
        IPancakeToken lpToken = IPancakeToken(pair);
        uint256 lpBalanceBefore = lpToken.balanceOf(address(this)) - actualLiquidity;
        _safeApprove(lpToken, address(lpAdapter), 0);
        _safeApprove(lpToken, address(lpAdapter), actualLiquidity);
        if (lpMode == LpMode.Burn) {
            lpAdapter.burnLp(pair, actualLiquidity);
        } else {
            // The immutable locker expiry is intentionally enforced against chain time again at execution.
            // forge-lint: disable-next-line(block-timestamp)
            if (unlockTime <= block.timestamp) revert DeadlineExpired(unlockTime, block.timestamp);
            lpAdapter.lockLp(pair, actualLiquidity, locker, lpBeneficiary, unlockTime);
        }
        _safeApprove(lpToken, address(lpAdapter), 0);
        if (lpToken.balanceOf(address(this)) != lpBalanceBefore) revert InvalidCanonicalPair(pair);
    }

    function _contextToken(address caller) private view returns (address contextToken) {
        (bool success, bytes memory result) = caller.staticcall(abi.encodeCall(IMintVaultLaunchContext.token, ()));
        if (!success || result.length != 32) return address(0);
        contextToken = abi.decode(result, (address));
    }

    function _validateCanonicalPair(address pair, address launchToken) private view {
        if (pair.code.length == 0) revert InvalidCanonicalPair(pair);
        if (pair.codehash != pairCodehash) revert InvalidCanonicalPair(pair);
        (address expected0, address expected1) = launchToken < wbnb ? (launchToken, wbnb) : (wbnb, launchToken);
        if (IPancakePair(pair).token0() != expected0 || IPancakePair(pair).token1() != expected1) {
            revert InvalidCanonicalPair(pair);
        }
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

    function _safeApprove(IPancakeToken asset, address spender, uint256 amount) private {
        (bool success, bytes memory result) =
            address(asset).call(abi.encodeCall(IPancakeToken.approve, (spender, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }

    function _safeTransferFrom(IPancakeToken asset, address owner, address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(asset).call(abi.encodeCall(IPancakeToken.transferFrom, (owner, recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }

    function _safeTransfer(IPancakeToken asset, address recipient, uint256 amount) private {
        (bool success, bytes memory result) =
            address(asset).call(abi.encodeCall(IPancakeToken.transfer, (recipient, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenOperationFailed(address(asset));
        }
    }

    function _sendNative(address recipient, uint256 amount) private {
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert InvalidDependency(recipient);
    }
}
