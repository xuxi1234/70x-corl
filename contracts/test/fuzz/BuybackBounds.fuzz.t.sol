// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BuybackVault} from "../../src/vaults/BuybackVault.sol";
import {TargetCompatibilityRegistry} from "../../src/core/TargetCompatibilityRegistry.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes calldata revertData) external;
    function warp(uint256 newTimestamp) external;
}

contract FuzzBuybackToken {
    mapping(address account => uint256 amount) public balanceOf;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract FuzzBuybackPair {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract FuzzBuybackFactory {
    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new FuzzBuybackPair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract FuzzBuybackRouter {
    address public immutable factory;
    address public immutable WETH;

    constructor(address factory_, address wbnb_) {
        factory = factory_;
        WETH = wbnb_;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(FuzzBuybackFactory(factory).getPair(path[0], path[1]) != address(0), "pair");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }

    function swapExactETHForTokens(uint256 minimum, address[] calldata path, address recipient, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        require(msg.value >= minimum, "minimum");
        require(FuzzBuybackToken(path[1]).transfer(recipient, msg.value), "transfer");
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value;
    }
}

contract BuybackBoundsFuzzTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    FuzzBuybackToken private wbnb;
    FuzzBuybackToken private target;
    FuzzBuybackFactory private factory;
    FuzzBuybackRouter private router;
    TargetCompatibilityRegistry private registry;
    BuybackVault.TrustedDexConfig private trusted;

    function setUp() public {
        wbnb = new FuzzBuybackToken();
        target = new FuzzBuybackToken();
        factory = new FuzzBuybackFactory();
        address pair = factory.createPair(address(wbnb), address(target));
        router = new FuzzBuybackRouter(address(factory), address(wbnb));
        registry = new TargetCompatibilityRegistry(address(this));
        registry.setApprovedCodehash(address(target).codehash, true);
        VM.deal(address(this), type(uint128).max);
        target.mint(address(router), type(uint128).max);
        trusted = BuybackVault.TrustedDexConfig({
            router: address(router),
            factory: address(factory),
            wbnb: address(wbnb),
            targetRegistry: address(registry),
            routerCodehash: address(router).codehash,
            factoryCodehash: address(factory).codehash,
            wbnbCodehash: address(wbnb).codehash,
            pairCodehash: pair.codehash,
            targetRegistryCodehash: address(registry).codehash
        });
    }

    function testFuzzThresholdAndMaximumSpendAreAppliedExactly(uint96 rawThreshold, uint96 rawCap, uint96 rawExcess)
        public
    {
        uint256 threshold = uint256(rawThreshold) % 100 ether + 1;
        uint256 cap = uint256(rawCap) % 100 ether + 1;
        uint256 funding = threshold + (uint256(rawExcess) % 100 ether);
        uint256 expectedSpend = funding < cap ? funding : cap;
        BuybackVault vault = _newVault(threshold, cap, 0, 0);
        _fund(vault, funding);
        vault.commitExecutionFloor(expectedSpend, expectedSpend, block.timestamp + 1 hours);

        (uint256 spent, uint256 output) = vault.executeBuyback(0, block.timestamp + 1 hours);

        require(spent == expectedSpend && output == expectedSpend, "wrong bounded spend");
        require(address(vault).balance == funding - expectedSpend, "wrong remainder");
        require(target.balanceOf(DEAD) == expectedSpend, "wrong burn output");
    }

    function testFuzzIntervalsBelowFiveMinutesAreRejected(uint32 rawInterval) public {
        uint32 interval = uint32(uint256(rawInterval) % 299) + 1;

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InvalidInterval.selector, interval));
        _newVault(1, 1, interval, 0);
    }

    function testFuzzIntervalsAboveThirtyDaysAreRejected(uint32 rawExcess) public {
        uint32 interval = uint32(30 days + 1 + (uint256(rawExcess) % (type(uint32).max - 30 days)));

        VM.expectRevert(abi.encodeWithSelector(BuybackVault.InvalidInterval.selector, interval));
        _newVault(1, 1, interval, 0);
    }

    function testFuzzValidIntervalAdvancesFromExecutionTime(uint32 rawInterval, uint32 rawDelay) public {
        uint32 interval = uint32(5 minutes + (uint256(rawInterval) % (30 days - 5 minutes + 1)));
        BuybackVault vault = _newVault(1, 1, interval, 0);
        uint256 firstTime = vault.nextExecutionAt();
        uint256 executionTime = firstTime + (uint256(rawDelay) % 30 days);
        _fund(vault, 1);
        vault.commitExecutionFloor(1, 1, executionTime + 1);
        VM.warp(executionTime);

        vault.executeBuyback(0, executionTime + 1);

        require(vault.nextExecutionAt() == executionTime + interval, "interval drifted");
    }

    function testFuzzSlippageAtAllValidBpsStillUsesQuoteFloor(uint16 rawSlippage) public {
        uint16 slippage = uint16(uint256(rawSlippage) % 10_000);
        BuybackVault vault = _newVault(1 ether, 1 ether, 0, slippage);
        _fund(vault, 1 ether);
        vault.commitExecutionFloor(1 ether, 1 ether, block.timestamp + 1);

        (, uint256 output) = vault.executeBuyback(0, block.timestamp + 1);

        require(output == 1 ether, "valid slippage changed output");
    }

    function _newVault(uint256 threshold, uint256 cap, uint32 interval, uint16 slippage)
        private
        returns (BuybackVault)
    {
        BuybackVault.Config memory config = BuybackVault.Config({
            targetToken: address(target),
            threshold: threshold,
            maxSpend: cap,
            interval: interval,
            maxSlippageBps: slippage,
            requireRouteAtCreation: false,
            requireTargetApproval: false,
            controller: address(this),
            quoteController: address(this),
            fullConfigHash: keccak256("fuzz")
        });
        BuybackVault vault = new BuybackVault(address(router), address(wbnb), config, trusted);
        if (address(vault).code.length != 0) {
            vault.setFunder(address(this));
            if (interval != 0) vault.activateSchedule();
        }
        return vault;
    }

    function _fund(BuybackVault vault, uint256 amount) private {
        vault.fundBuyback{value: amount}();
    }
}
